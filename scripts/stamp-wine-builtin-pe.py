#!/usr/bin/env python3
"""Stamp PE DLLs so Wine accepts them as builtin modules."""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

DOS_HEADER_SIZE = 64
COFF_HEADER_SIZE = 20
BUILTIN_SIGNATURE = b"Wine builtin DLL" + b"\0" * 16


def stamp_dll(path: Path) -> bool:
    """Stamp one PE DLL, returning whether its contents changed."""
    try:
        with path.open("r+b") as file:
            header = file.read(DOS_HEADER_SIZE)
            if len(header) != DOS_HEADER_SIZE or header[:2] != b"MZ":
                raise ValueError("not a PE file")

            pe_offset = struct.unpack_from("<I", header, 60)[0]
            if pe_offset < DOS_HEADER_SIZE + len(BUILTIN_SIGNATURE):
                raise ValueError(f"PE header overlaps builtin signature at offset {pe_offset}")

            file.seek(pe_offset)
            if file.read(4) != b"PE\0\0":
                raise ValueError("missing PE signature")

            coff_header = file.read(COFF_HEADER_SIZE)
            if len(coff_header) != COFF_HEADER_SIZE:
                raise ValueError("truncated COFF header")
            optional_header_size = struct.unpack_from("<H", coff_header, 16)[0]
            if len(file.read(optional_header_size)) != optional_header_size:
                raise ValueError("truncated optional header")

            file.seek(DOS_HEADER_SIZE)
            if file.read(len(BUILTIN_SIGNATURE)) == BUILTIN_SIGNATURE:
                return False
            file.seek(DOS_HEADER_SIZE)
            file.write(BUILTIN_SIGNATURE)
            return True
    except OSError as exc:
        raise ValueError(str(exc)) from exc


def dll_paths(path: Path) -> list[Path]:
    if path.is_dir():
        return sorted(candidate for candidate in path.rglob("*.dll") if candidate.is_file())
    return [path]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="PE DLL or directory containing PE DLLs")
    args = parser.parse_args(argv)

    paths = dll_paths(args.path)
    if not paths:
        print(f"stamp-wine-builtin-pe: no DLLs found in {args.path}", file=sys.stderr)
        return 1

    changed = 0
    skipped = 0
    directory_mode = args.path.is_dir()
    for path in paths:
        try:
            changed += stamp_dll(path)
        except ValueError as exc:
            if directory_mode:
                print(f"stamp-wine-builtin-pe: skip {path}: {exc}", file=sys.stderr)
                skipped += 1
                continue
            print(f"stamp-wine-builtin-pe: {path}: {exc}", file=sys.stderr)
            return 1
    print(f"Stamped {changed} of {len(paths)} DLL(s)" + (f" (skipped {skipped})" if skipped else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
