#!/usr/bin/env python3
"""Cyder launcher — open Windows EXE with shared prefix."""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from cyder_common import (
    BOOTSTRAP_MARKER,
    DEFAULT_ENGINE_SRC,
    ENGINE_NAME,
    ENGINES,
    SHARED_PREFIX,
    SUPPORT,
    bootstrap_shared_prefix,
    choose_exe,
    ensure_shared_engine,
    run_wine_exe,
)


def resolve_exe(argv: list[str]) -> Path | None:
    for a in argv:
        p = Path(a).expanduser()
        if p.suffix.lower() == ".exe" and p.is_file():
            return p.resolve()
    return None


def pick_exe() -> Path:
    return choose_exe()


def _wine_bin_path(engine_src: Path) -> Path:
    installed = ENGINES / ENGINE_NAME / "bin" / "wine"
    if installed.is_file():
        return installed
    return engine_src.resolve() / "bin" / "wine"


def main() -> None:
    parser = argparse.ArgumentParser(description="Cyder launcher — run a Windows EXE with shared prefix")
    parser.add_argument("exe", nargs="*", help="Windows .exe path(s)")
    parser.add_argument("--engine-src", type=Path, default=DEFAULT_ENGINE_SRC)
    parser.add_argument("--dry-run", action="store_true", help="Print paths without installing engine or launching")
    parser.add_argument(
        "--bootstrap-only",
        action="store_true",
        help="Bootstrap shared prefix (mono, tar, hi-res) and exit",
    )
    args = parser.parse_args()

    if args.bootstrap_only:
        engine = ensure_shared_engine(args.engine_src)
        wine = engine / "bin" / "wine"
        print(f"WINEPREFIX={SHARED_PREFIX}")
        print(f"BOOTSTRAP_MARKER={BOOTSTRAP_MARKER}")
        bootstrap_shared_prefix(wine, engine_src=args.engine_src)
        return

    exe = resolve_exe(args.exe) or (None if args.dry_run else pick_exe())
    if exe is None:
        sys.exit("No .exe specified")

    if args.dry_run:
        wine = _wine_bin_path(args.engine_src)
        print(f"WINEPREFIX={SHARED_PREFIX}")
        print(f"wine={wine}")
        print(f"exe={exe}")
        print(f"cwd={exe.parent}")
        return

    engine = ensure_shared_engine(args.engine_src)
    wine = engine / "bin" / "wine"
    try:
        bootstrap_shared_prefix(wine, engine_src=args.engine_src)
    except subprocess.CalledProcessError as e:
        log = SUPPORT / "Logs" / "bootstrap-error.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(f"{e}\n", encoding="utf-8")
        msg = f"請查看：{log}"
        subprocess.call(
            ["osascript", "-e", f'display alert "Cyder 初始化失敗" message "{msg}" as warning']
        )
        sys.exit(1)
    run_wine_exe(wine, exe, prefix=SHARED_PREFIX)


if __name__ == "__main__":
    main()
