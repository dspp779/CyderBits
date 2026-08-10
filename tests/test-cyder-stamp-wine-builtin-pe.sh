#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$ROOT/scripts/stamp-wine-builtin-pe.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-stamp-wine-builtin-pe.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

DLL="$TMP/d3d11.dll"
python3 - "$DLL" <<'PY'
from pathlib import Path
import struct
import sys

data = bytearray(160)
data[:2] = b"MZ"
data[64:96] = b"unpatched DOS stub data........"
struct.pack_into("<I", data, 60, 120)
data[120:124] = b"PE\0\0"
Path(sys.argv[1]).write_bytes(data)
PY

python3 "$STAMP" "$DLL"
python3 - "$DLL" <<'PY'
from pathlib import Path
import struct
import sys

data = Path(sys.argv[1]).read_bytes()
assert data[64:96] == b"Wine builtin DLL" + b"\0" * 16
assert struct.unpack_from("<I", data, 60)[0] == 120
assert data[120:124] == b"PE\0\0"
PY

before="$(shasum -a 256 "$DLL")"
python3 "$STAMP" "$DLL"
after="$(shasum -a 256 "$DLL")"
[[ "$before" == "$after" ]]

printf 'not a PE' >"$TMP/not-pe.dll"
if python3 "$STAMP" "$TMP/not-pe.dll"; then
  echo "FAIL: non-PE input was accepted" >&2
  exit 1
fi

echo "PASS test-cyder-stamp-wine-builtin-pe"
