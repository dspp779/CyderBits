#!/usr/bin/env python3
"""Build targeted CDB v1 variants for the Wine runtime verification harness."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


HEADER = struct.Struct("<8sHHIQIIII")
TLV = struct.Struct("<HHI")
RULE_END = 0x0002
ACTION_APPEND_ARG = 0x0030
ACTION_DLL_OVERRIDE = 0x0031


def records(data: bytes) -> list[tuple[int, int, bytes]]:
    offset = HEADER.size
    result = []
    while offset < len(data):
        record_type, flags, size = TLV.unpack_from(data, offset)
        offset += TLV.size
        result.append((record_type, flags, data[offset : offset + size]))
        offset += size
    return result


def encode(source: bytes, items: list[tuple[int, int, bytes]], rule_count: int) -> bytes:
    body = b"".join(TLV.pack(record_type, flags, len(payload)) + payload
                    for record_type, flags, payload in items)
    header = list(HEADER.unpack_from(source))
    header[4] = HEADER.size + len(body)
    header[5] = len(items)
    header[6] = rule_count
    return HEADER.pack(*header) + body


def exercised_rule_end(items: list[tuple[int, int, bytes]]) -> int:
    """Return the end of the Steam rule exercised by this verifier."""
    action = next(i for i, item in enumerate(items)
                  if item[0] == ACTION_APPEND_ARG)
    return next(i for i in range(action + 1, len(items))
                if items[i][0] == RULE_END)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("variant", choices=("optional", "required", "truncated",
                                            "duplicate", "unicode", "dll"))
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    source = args.source.read_bytes()
    if args.variant == "truncated":
        args.output.write_bytes(source[:-1])
        return

    items = records(source)
    rule_count = HEADER.unpack_from(source)[6]
    if args.variant in ("optional", "required"):
        end = exercised_rule_end(items)
        items.insert(end, (0x7FFE, 0 if args.variant == "optional" else 1, b"new"))
    elif args.variant == "duplicate":
        items = items + items
        rule_count *= 2
    elif args.variant == "unicode":
        action_indexes = [i for i, item in enumerate(items)
                          if item[0] == ACTION_APPEND_ARG]
        items[action_indexes[-1]] = (
            ACTION_APPEND_ARG,
            1,
            '\u6e2c\u8a66 arg "quoted"\\'.encode("utf-8"),
        )
    elif args.variant == "dll":
        end = exercised_rule_end(items)
        items.insert(end, (ACTION_DLL_OVERRIDE, 1, b"ddraw=n,b"))

    args.output.write_bytes(encode(source, items, rule_count))


if __name__ == "__main__":
    main()
