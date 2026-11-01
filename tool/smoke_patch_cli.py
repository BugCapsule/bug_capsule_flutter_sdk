#!/usr/bin/env python3
"""Exercise a released CLI compiler outside the repo, with an isolated mock base API."""
import argparse
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('binary', type=Path)
a = p.parse_args()
binary = a.binary.resolve()
fixtures = Path(__file__).resolve().parent / 'fixtures/patch_cli'
base = {'applicationId': 'dev.bugcapsule.cli.smoke', 'platform': 'flutter_ios',
        'baseBuildId': 'smoke-base',
        'capabilityHash': 'sha256:4b37753ff79051b8fa1290db23addc5863f29c16b3c3d9390af5eb613b639b43',
        'hostAbiHash': 'sha256:33a77f2c4534c7071209021484e73f54a3264786e6b09323d3ae89026aa2dfbc',
        'inventory': {'modules': [{'id': 'pricing.coupon',
            'input': 'rec(couponPercent:int,lines:list(rec(qty:int,sku:str,unitPrice:dec(2))))',
            'output': 'rec(discount:dec(2),label:str,subtotal:dec(2),total:dec(2))'}], 'surfaces': []}}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/v1/patches/bases/smoke-base':
            self.send_error(404)
            return
        body = json.dumps(base).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass

with tempfile.TemporaryDirectory(prefix='bugcapsule-cli-consumer-') as tmp:
    root = Path(tmp)
    repo = root / 'application'
    repo.mkdir()
    (repo / 'modules').mkdir()
    def git(*args):
        return subprocess.check_output(['git', '-c', 'user.name=CLI smoke',
            '-c', 'user.email=cli-smoke@example.invalid', '-c', 'commit.gpgsign=false',
            '-C', str(repo), *args], stderr=subprocess.DEVNULL).decode().strip()
    git('init')
    shutil.copy2(fixtures / 'base.bpl', repo / 'modules/coupon.bpl')
    git('add', '.')
    git('commit', '-m', 'base fixture')
    before = git('rev-parse', 'HEAD')
    shutil.copy2(fixtures / 'fix.bpl', repo / 'modules/coupon.bpl')
    git('add', '.')
    git('commit', '-m', 'fix fixture')
    key = root / 'fixture-key.pem'
    subprocess.run(['node', '-e',
        "const {generateKeyPairSync}=require('node:crypto');"
        "require('node:fs').writeFileSync(process.argv[1],"
        "generateKeyPairSync('ec',{namedCurve:'prime256v1'}).privateKey.export({type:'pkcs8',format:'pem'}),{mode:0o600})",
        str(key)], check=True)
    env = {k:v for k,v in os.environ.items() if not k.startswith('BUGCAPSULE_')}
    env.update({'BUGCAPSULE_TOKEN': 'bcp_synthetic_cli_smoke',
                'BUGCAPSULE_PATCH_PROJECT_ID': '11111111-2222-4333-8444-555555555555'})
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env['BUGCAPSULE_URL'] = f'http://127.0.0.1:{server.server_port}'
    def cli(*args):
        result = subprocess.run([str(binary), 'patch', *args, '--json'], cwd=repo,
                                env=env, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(f'CLI {args[0]} failed: {result.stdout} {result.stderr}')
        return json.loads(result.stdout)['result']
    try:
        doctor = cli('doctor')
        if not doctor['engine'].startswith('bundled@'):
            raise RuntimeError('Default compiler did not come from the executable')
        artifact = root / 'fix.bcpatch'
        cli('build', '--base', 'smoke-base', '--source', 'modules', '--repo', '.',
            '--base-rev', before, '--profile', 'development', '--patch-id', 'smoke-fix',
            '--key', str(key), '--key-id', 'smoke-key', '--out', str(artifact))
        result = cli('inspect', str(artifact))
        if not artifact.is_file() or artifact.stat().st_size == 0:
            raise RuntimeError('Compiler did not produce an artifact')
        if 'smoke-fix' not in json.dumps(result):
            raise RuntimeError('Inspected artifact identity differs')
        print('PASS: default embedded compiler built and inspected a signed patch outside the SDK/engine checkout.')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
