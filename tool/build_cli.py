#!/usr/bin/env python3
"""Compile the shared CLI sources without resolving Flutter or bundling an SDK."""
import argparse
import hashlib
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os_name = {'Darwin': 'darwin', 'Linux': 'linux', 'Windows': 'win32'}[platform.system()]
arch = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'x64', 'AMD64': 'x64'}[platform.machine()]
name = f'bugcapsule-{os_name}-{arch}' + ('.exe' if os_name == 'win32' else '')
output = (args.output or root / 'dist' / 'cli' / name).resolve()
output.parent.mkdir(parents=True, exist_ok=True)
source = root / 'packages' / 'bug_capsule'
with tempfile.TemporaryDirectory(prefix='bugcapsule-cli-') as tmp:
    stage = Path(tmp)
    (stage / 'pubspec.yaml').write_text('name: bugcapsule_standalone\nenvironment:\n  sdk: ^3.9.0\ndependencies:\n  args: 2.7.0\n  pointycastle: 4.0.0\n')
    for folder in ['cli', 'core']:
        shutil.copytree(source / 'lib' / 'src' / folder, stage / 'lib' / 'src' / folder)
    shutil.copy2(source / 'lib' / 'src' / 'version.dart', stage / 'lib' / 'src' / 'version.dart')
    (stage / 'bin').mkdir()
    (stage / 'bin' / 'bugcapsule.dart').write_text((source / 'bin' / 'bugcapsule.dart').read_text().replace('package:bug_capsule/', 'package:bugcapsule_standalone/'))
    subprocess.run(['dart', 'pub', 'get'], cwd=stage, check=True)
    subprocess.run(['dart', 'analyze', '--fatal-infos'], cwd=stage, check=True)
    subprocess.run(['dart', 'compile', 'exe', 'bin/bugcapsule.dart', '-o', str(output)], cwd=stage, check=True)
subprocess.run([str(output), '--version'], check=True)
output.with_name(output.name + '.sha256').write_text(hashlib.sha256(output.read_bytes()).hexdigest() + '  ' + output.name + '\n')
print(output)
