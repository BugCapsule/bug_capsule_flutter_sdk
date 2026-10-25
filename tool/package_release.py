#!/usr/bin/env python3
"""Build a standalone source candidate; never publish or alter the checkout."""
from pathlib import Path
import shutil, tarfile, hashlib, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = root / "packages/bug_capsule"
if (source / "README.md").read_bytes() != (root / "README.md").read_bytes():
    raise SystemExit("Package README must match the root README before release")
version = next(line.split(":", 1)[1].strip() for line in (source / "pubspec.yaml").read_text().splitlines() if line.startswith("version:"))
import re
runtime_version = re.search(r"const bugCapsuleVersion = '([^']+)';", (source / "lib/src/version.dart").read_text())
if runtime_version is None or runtime_version.group(1) != version:
    raise SystemExit("CLI/SDK runtime version must match pubspec.yaml")
stage = root / "dist" / ("bug_capsule-" + version)
if stage.exists(): shutil.rmtree(stage)
stage.mkdir(parents=True, exist_ok=True)
for name in ["lib", "bin", "tool", "example", "README.md", "CHANGELOG.md", "LICENSE", "pubspec.yaml"]:
    item = source / name
    if item.is_dir():
        if (stage / name).exists(): shutil.rmtree(stage / name)
        shutil.copytree(item, stage / name)
    else: shutil.copy2(item, stage / name)
manifest = stage / "pubspec.yaml"
manifest.write_text(manifest.read_text().replace("resolution: workspace\n", ""))
# Validate outside the repository: parent .gitignore must not hide dist contents.
with tempfile.TemporaryDirectory(prefix="bugcapsule-pub-") as temporary:
    candidate = Path(temporary) / stage.name
    shutil.copytree(stage, candidate)
    subprocess.run(["flutter", "pub", "publish", "--dry-run"], cwd=candidate, check=True)
archive = stage.parent / (stage.name + ".tar.gz")
with tarfile.open(archive, "w:gz") as output: output.add(stage, arcname=stage.name)
archive.with_name(archive.name + ".sha256").write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name + "\n")
print(archive)
