"""
Put CSP extra options (the limiter's [SCRIPT_...] entry) where players' games
will actually see them: inside the server's welcome message.

Vanilla acServer never reads cfg/csp_extra_options.ini. CSP finds its extra
options hidden at the end of the welcome message, and Content Manager writes
them there when it starts a server preset. Run acServer any other way (a
dedicated box, a Linux host, a server manager) and the [SCRIPT_...] entry
never reaches anyone, so the safety car's speed limiter never loads.

Run from the acServer folder (the one holding cfg/), then restart acServer:

    python3 tools/csp_welcome.py                 # pack cfg/csp_extra_options.ini
    python3 tools/csp_welcome.py --check         # show what the server sends now
    python3 tools/csp_welcome.py -s /path/to/acServer -o other_options.ini

Any text already in the welcome message is kept; only the hidden block is
replaced. The format is CSP's: 32 tabs, "$CSP0:", then the options
zlib-compressed and base64-encoded with the trailing "=" cut.
"""

from __future__ import annotations

import argparse
import base64
import configparser
import sys
import zlib
from pathlib import Path

SEPARATOR = "\t" * 32 + "$CSP0:"
DEFAULT_WELCOME = "cfg/welcome.txt"


def encode(options: str) -> str:
    packed = base64.b64encode(zlib.compress(options.encode("utf-8"), 6)).decode("ascii")
    return SEPARATOR + packed.rstrip("=")


def split(message: str) -> tuple[str, str | None]:
    """The visible welcome text, and the extra options hidden after it (if any)."""
    at = message.find("$CSP0:")
    if at < 0:
        return message, None
    visible = message[:at].rstrip("\t")
    blob = message[at + len("$CSP0:"):].strip()
    try:
        raw = base64.b64decode(blob + "=" * (-len(blob) % 4))
        return visible, zlib.decompress(raw).decode("utf-8", errors="replace")
    except Exception as exc:  # noqa: BLE001 - shown to the user as-is
        return visible, f"<could not decode the hidden block: {exc}>"


def welcome_setting(server_cfg: Path) -> str:
    cp = configparser.ConfigParser(strict=False, interpolation=None, inline_comment_prefixes=(";",))
    cp.optionxform = str
    cp.read(server_cfg, encoding="utf-8-sig")
    if not cp.has_section("SERVER"):
        return ""
    return cp.get("SERVER", "WELCOME_MESSAGE", fallback="").strip()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("-s", "--server-dir", default=".", help="acServer folder (holds cfg/)")
    ap.add_argument("-o", "--options", help="extra options file (default cfg/csp_extra_options.ini)")
    ap.add_argument("--check", action="store_true", help="print what the welcome message carries now")
    args = ap.parse_args(argv)

    server = Path(args.server_dir)
    server_cfg = server / "cfg" / "server_cfg.ini"
    if not server_cfg.is_file():
        print(f"no {server_cfg}: run this from the acServer folder, or pass -s", file=sys.stderr)
        return 2

    setting = welcome_setting(server_cfg)
    welcome = server / (setting or DEFAULT_WELCOME)
    current = welcome.read_text(encoding="utf-8-sig", errors="replace") if welcome.is_file() else ""
    visible, hidden = split(current)

    if args.check:
        if not setting:
            print("server_cfg.ini has no WELCOME_MESSAGE, so players get no extra options at all.")
            return 1
        print(f"welcome message: {welcome}")
        if hidden is None:
            print("it carries NO CSP extra options: the limiter script will not load.")
            return 1
        print("CSP extra options it carries:\n")
        print(hidden)
        if "/csp/vsc.lua" not in hidden:
            print("\nno [SCRIPT_...] entry for /csp/vsc.lua in there: the limiter will not load.")
            return 1
        return 0

    options_path = Path(args.options) if args.options else server / "cfg" / "csp_extra_options.ini"
    if not options_path.is_file():
        print(f"no {options_path}: write the [SCRIPT_...] entry there first (see README)", file=sys.stderr)
        return 2
    options = options_path.read_text(encoding="utf-8-sig").strip()
    if not options:
        print(f"{options_path} is empty", file=sys.stderr)
        return 2

    welcome.parent.mkdir(parents=True, exist_ok=True)
    welcome.write_text(visible.rstrip() + encode(options) + "\n", encoding="utf-8", newline="\n")
    print(f"packed {options_path} into {welcome}")
    if "/csp/vsc.lua" not in options:
        print("warning: no [SCRIPT_...] entry for /csp/vsc.lua in it, so the limiter still will not load")
    if not setting:
        print(f"now set WELCOME_MESSAGE={DEFAULT_WELCOME} under [SERVER] in {server_cfg}")
    print("restart acServer for players to get it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
