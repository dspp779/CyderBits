#!/usr/bin/env python3
"""Cyder launcher — dev CLI wrapper around cyder_launcher.sh."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parent / "cyder_launcher.sh"

if __name__ == "__main__":
    raise SystemExit(subprocess.call(["bash", str(_SCRIPT), *sys.argv[1:]]))
