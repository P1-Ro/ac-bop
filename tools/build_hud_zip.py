"""
Package hud/ as the installable acbop HUD zip.

A single acbop_hud/ folder holding assettocorsa/apps/lua/acbop-HUD. Drop it on
Content Manager, or copy the assettocorsa folder over the game's.

    python3 tools/build_hud_zip.py            # -> dist/acbop_hud_v<version>.zip
    python3 tools/build_hud_zip.py -o x.zip
"""

from __future__ import annotations

import argparse
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HUD = ROOT / "hud"
APP = HUD / "assettocorsa" / "apps" / "lua" / "acbop-HUD"
PREFIX = "acbop_hud"
# What a CSP app is made of. Anything else in hud/ is a stray (a download, an
# editor backup) and stops the build rather than shipping to every driver.
APP_FILES = {".lua", ".ini", ".png", ".ttf"}


def hud_version() -> str:
    text = (APP / "manifest.ini").read_text(encoding="utf-8", errors="replace")
    m = re.search(r"^VERSION\s*=\s*(\S+)", text, re.M)
    if not m:
        sys.exit("no VERSION in manifest.ini")
    return m.group(1)


def build(out: Path) -> Path:
    strays = [p for p in HUD.rglob("*") if p.is_file() and p.suffix.lower() not in APP_FILES]
    if strays:
        sys.exit("not an app file, remove it from hud/: " + ", ".join(
            str(p.relative_to(ROOT)) for p in strays))
    out.parent.mkdir(parents=True, exist_ok=True)
    # Fixed timestamps, so the same tree always gives the same zip.
    stamp = (2024, 1, 1, 0, 0, 0)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(zipfile.ZipInfo(PREFIX + "/", stamp), b"")
        for path in sorted(HUD.rglob("*")):
            name = f"{PREFIX}/{path.relative_to(HUD).as_posix()}"
            if path.is_dir():
                z.writestr(zipfile.ZipInfo(name + "/", stamp), b"")
            else:
                info = zipfile.ZipInfo(name, stamp)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                z.writestr(info, path.read_bytes())
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("-o", "--output", type=Path)
    args = ap.parse_args()
    out = args.output or ROOT / "dist" / f"acbop_hud_v{hud_version()}.zip"
    build(out)
    print(out)


if __name__ == "__main__":
    main()
