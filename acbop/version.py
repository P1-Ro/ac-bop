"""What is actually running: package version plus the git commit it was deployed from."""

from __future__ import annotations

import subprocess
import time
from pathlib import Path

from . import __version__

ROOT = Path(__file__).resolve().parent.parent


def _git(*args: str) -> str | None:
    # safe.directory: under systemd the service user usually does not own the
    # checkout, and git refuses to read a repo owned by someone else without it.
    try:
        out = subprocess.run(
            ["git", "-c", "safe.directory=*", "-C", str(ROOT), *args],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip() or None


def _build_info() -> dict:
    # --dirty flags a checkout that was edited in place after deploying.
    commit = _git("describe", "--always", "--dirty", "--abbrev=7", "--exclude=*")
    return {
        "version": __version__,
        "commit": commit,
        "commit_date": _git("log", "-1", "--format=%cI") if commit else None,
        "started": time.time(),
    }


# Resolved once at import, so it describes the code this process loaded rather
# than whatever has since been pulled into the directory.
BUILD = _build_info()


def describe() -> str:
    return f"{BUILD['version']} ({BUILD['commit']})" if BUILD["commit"] else BUILD["version"]
