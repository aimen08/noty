#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Noty.app"

for locale in en zh-Hans; do
    plutil -lint "$ROOT/Resources/$locale.lproj/Localizable.strings"
    plutil -lint "$ROOT/Resources/$locale.lproj/Localizable.stringsdict"
done

python3 - "$ROOT" <<'PY'
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
def keys(locale, name):
    source = root / "Resources" / f"{locale}.lproj" / name
    with tempfile.TemporaryDirectory() as directory:
        converted = Path(directory) / "converted.plist"
        subprocess.run(
            ["plutil", "-convert", "xml1", "-o", str(converted), str(source)],
            check=True,
        )
        with converted.open("rb") as f:
            return set(plistlib.load(f))

for name in ("Localizable.strings", "Localizable.stringsdict"):
    assert keys("en", name) == keys("zh-Hans", name), f"key mismatch in {name}"
PY

"$ROOT/build.sh" debug
for locale in en zh-Hans; do
    test -f "$APP/Contents/Resources/$locale.lproj/Localizable.strings"
    test -f "$APP/Contents/Resources/$locale.lproj/Localizable.stringsdict"
done
