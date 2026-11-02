#!/usr/bin/env python3
"""Stage a hosted optional adapter package. Prints the staged directory; uploads nothing."""
import argparse, pathlib, re, shutil, subprocess

ADAPTERS = ['firebase', 'geolocator', 'google_maps', 'shorebird', 'stripe']

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('adapter', choices=ADAPTERS)
p.add_argument('--output', type=pathlib.Path, required=True, help='New parent directory')
p.add_argument('--core-version', required=True)
a = p.parse_args()

root = pathlib.Path(__file__).resolve().parents[1]
name = 'bug_capsule_' + a.adapter
source = root / 'packages' / name
pubspec = (source / 'pubspec.yaml').read_text()
version = re.search(r'^version: (\S+)$', pubspec, re.M)[1]
target = a.output / f'{name}-{version}'
if target.exists():
    raise SystemExit('Output must be new; preserve reviewed artifacts')

target.mkdir(parents=True)
shutil.copytree(source / 'lib', target / 'lib')
for item in ['README.md', 'CHANGELOG.md', 'LICENSE']:
    shutil.copy2(source / item, target / item)

s = pubspec.replace('publish_to: none\n', '').replace('resolution: workspace\n', '')
s = s.replace('  bug_capsule:\n    path: ../bug_capsule\n', f'  bug_capsule: ^{a.core_version}\n')
# The tests stay in the repository, so their dependencies do not ship.
s = re.sub(r'^dev_dependencies:\n(?:(?:  .*)?\n)*', '', s, flags=re.M).rstrip() + '\n'
if 'path:' in s or 'workspace' in s or 'publish_to:' in s:
    raise SystemExit('Non-hosted manifest refused')
(target / 'pubspec.yaml').write_text(s)

if not re.search(rf'^  bug_capsule: \^{re.escape(a.core_version)}$', (target / 'README.md').read_text(), re.M):
    raise SystemExit('README installs a different core version')
declared = next(iter(re.findall(r"= '([^']+)';", (source / 'lib/src/version.dart').read_text())), version) \
    if (source / 'lib/src/version.dart').exists() else version
if declared != version:
    raise SystemExit(f'lib/src/version.dart says {declared}, pubspec says {version}')

commit = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
print(target)
print(f'Staged from {commit}. Run a publish dry run and a real external consumer before uploading.')
