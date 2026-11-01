#!/usr/bin/env python3
"""Stage a hosted Flutter patch package with verified, prebuilt native payloads."""
import argparse, hashlib, json, pathlib, shutil, subprocess, tarfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--candidate', type=pathlib.Path, required=True, help='Reviewed flutter-patch-sdk candidate root')
p.add_argument('--output', type=pathlib.Path, required=True)
p.add_argument('--core-version', required=True)
a = p.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
source = root / 'packages/bug_capsule_patch'
meta = json.loads((a.candidate / 'PATCH-CANDIDATE.json').read_text())
sha = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()
# Verify every native file against the immutable candidate manifest, including extras.
prefixes = ['packages/bug_capsule_patch/android/src/main/jniLibs/', 'packages/bug_capsule_patch/ios/Frameworks/']
expected = {k: v for k,v in meta['files'].items() if any(k.startswith(prefix) for prefix in prefixes)}
actual = {str(f.relative_to(a.candidate)): sha(f) for prefix in prefixes for f in (a.candidate/prefix).rglob('*') if f.is_file()}
if not expected or actual != expected:
    raise SystemExit('Native candidate file inventory/hash mismatch')
if any(f.is_symlink() for prefix in prefixes for f in (a.candidate/prefix).rglob('*')):
    raise SystemExit('Native payload symlinks refused')
if a.output.exists(): raise SystemExit('Output must be new; preserve reviewed artifacts')
a.output.mkdir(parents=True)
for name in ['lib','android','ios','README.md','CHANGELOG.md','LICENSE','pubspec.yaml']:
    item = source/name
    if item.is_dir(): shutil.copytree(item,a.output/name,ignore=shutil.ignore_patterns('build','.gradle','.cxx','local.properties','Frameworks','jniLibs'))
    else: shutil.copy2(item,a.output/name)
for prefix in prefixes:
    target = a.output/pathlib.Path(prefix).relative_to('packages/bug_capsule_patch')
    shutil.copytree(a.candidate/prefix,target)
manifest = a.output/'pubspec.yaml'
s = manifest.read_text().replace('publish_to: none\n','').replace('resolution: workspace\n','')
s = s.replace('  bug_capsule:\n    path: ../bug_capsule\n', '  bug_capsule: ^'+a.core_version+'\n')
if 'path:' in s or 'workspace' in s or 'publish_to:' in s: raise SystemExit('Non-hosted manifest refused')
manifest.write_text(s)
version = next(line.split(':',1)[1].strip() for line in s.splitlines() if line.startswith('version:'))
record = {'sdkSourceCommit':subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip(),
          'nativeEngineSourceCommit':meta['engineCommit'],'coreDependency':a.core_version,'version':version,
          'nativeFiles':{str(pathlib.Path(k).relative_to('packages/bug_capsule_patch')):v for k,v in actual.items()}}
(a.output/'NATIVE-PROVENANCE.json').write_text(json.dumps(record,indent=2)+'\n')
# Pub ignores native build directories by default; an explicit allowlist is required.
(a.output/'.pubignore').write_text('.dart_tool/\nbuild/\npubspec.lock\npubspec_overrides.yaml\n')
archive=a.output.with_name(a.output.name+'.tar.gz')
with tarfile.open(archive,'w:gz') as out: out.add(a.output,arcname=a.output.name)
archive.with_name(archive.name+'.sha256').write_text(sha(archive)+'  '+archive.name+'\n')
print(a.output)
print('Staged only: publish dry-run and real external consumer checks are required before publication.')
