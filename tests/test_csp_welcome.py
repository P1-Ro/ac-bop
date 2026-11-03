"""
tools/csp_welcome.py: packs CSP extra options into the welcome message the way
Content Manager does, keeps the visible text, replaces an earlier block rather
than stacking a second one, and --check reads back what players will get.
"""

from __future__ import annotations

import base64
import io
import os
import sys
import tempfile
import zlib
from contextlib import redirect_stdout
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))

import csp_welcome  # noqa: E402

results: list[tuple[bool, str]] = []


def check(cond: bool, msg: str) -> None:
    results.append((bool(cond), msg))
    print(("PASS: " if cond else "FAIL: ") + msg)


def run(*args: str) -> tuple[int, str]:
    out = io.StringIO()
    with redirect_stdout(out):
        code = csp_welcome.main(list(args))
    return code, out.getvalue()


OPTIONS = """[SCRIPT_1]
SCRIPT = 'http://203.0.113.5:8770/csp/vsc.lua?car={SessionID}'
REQUIRED = 1
"""


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        srv = Path(tmp)
        (srv / "cfg").mkdir()
        (srv / "cfg" / "server_cfg.ini").write_text(
            "[SERVER]\nNAME=Test\nWELCOME_MESSAGE=cfg/welcome.txt ; shown on join\n"
        )
        (srv / "cfg" / "welcome.txt").write_text("Welcome to the test server!\n")
        (srv / "cfg" / "csp_extra_options.ini").write_text(OPTIONS)

        code, out = run("-s", tmp, "--check")
        check(code == 1 and "NO CSP extra options" in out,
              "--check spots a welcome message carrying no extra options")

        code, out = run("-s", tmp)
        text = (srv / "cfg" / "welcome.txt").read_text()
        check(code == 0 and text.startswith("Welcome to the test server!"),
              "the visible welcome text is kept")
        sep = "\t" * 32 + "$CSP0:"
        check(text.count(sep) == 1, "the options follow CSP's separator: 32 tabs and $CSP0:")
        blob = text.split(sep, 1)[1].strip()
        check(not blob.endswith("="), "base64 padding is cut, as Content Manager does")
        decoded = zlib.decompress(base64.b64decode(blob + "=" * (-len(blob) % 4))).decode()
        check(decoded == OPTIONS.strip(), "the block decodes back to the options file exactly")

        (srv / "cfg" / "csp_extra_options.ini").write_text(OPTIONS + "\n[EXTRA_RULES]\nX = 1\n")
        run("-s", tmp)
        text = (srv / "cfg" / "welcome.txt").read_text()
        _, hidden = csp_welcome.split(text)
        check(text.count("$CSP0:") == 1 and "[EXTRA_RULES]" in (hidden or ""),
              "packing again replaces the old block instead of adding a second")

        code, out = run("-s", tmp, "--check")
        check(code == 0 and "/csp/vsc.lua" in out, "--check prints the options players will get")

        (srv / "cfg" / "csp_extra_options.ini").write_text("[EXTRA_RULES]\nX = 1\n")
        run("-s", tmp)
        code, out = run("-s", tmp, "--check")
        check(code == 1 and "no [SCRIPT_...] entry" in out,
              "--check warns when the limiter's script entry is missing")

        # No WELCOME_MESSAGE configured: written to cfg/welcome.txt, with a
        # reminder to point the server at it.
        (srv / "cfg" / "server_cfg.ini").write_text("[SERVER]\nNAME=Test\n")
        (srv / "cfg" / "welcome.txt").unlink()
        (srv / "cfg" / "csp_extra_options.ini").write_text(OPTIONS)
        code, out = run("-s", tmp)
        check(code == 0 and (srv / "cfg" / "welcome.txt").is_file()
              and "WELCOME_MESSAGE=cfg/welcome.txt" in out,
              "without WELCOME_MESSAGE it writes cfg/welcome.txt and says to set it")

    failed = [m for ok, m in results if not ok]
    print("-" * 72)
    print(f"{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
