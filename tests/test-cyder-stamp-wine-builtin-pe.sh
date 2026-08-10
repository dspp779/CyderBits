#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/assert.sh"
STAMP="$ROOT/scripts/stamp-wine-builtin-pe.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-stamp-wine-builtin-pe.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

DLL="$TMP/d3d11.dll"
python3 - "$DLL" <<'PY'
from pathlib import Path
import struct
import sys

data = bytearray(192)
data[:2] = b"MZ"
data[64:96] = b"unpatched DOS stub data........"
struct.pack_into("<I", data, 60, 120)
data[120:124] = b"PE\0\0"
struct.pack_into("<H", data, 120 + 4 + 16, 32)
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

TRUNCATED="$TMP/truncated-pe.dll"
python3 - "$TRUNCATED" <<'PY'
from pathlib import Path
import struct
import sys

data = bytearray(124)
data[:2] = b"MZ"
struct.pack_into("<I", data, 60, 120)
data[120:124] = b"PE\0\0"
Path(sys.argv[1]).write_bytes(data)
PY

if python3 "$STAMP" "$TRUNCATED"; then
  echo "FAIL: truncated PE input was accepted" >&2
  exit 1
fi

python3 - "$TRUNCATED" <<'PY'
from pathlib import Path
import sys

assert Path(sys.argv[1]).read_bytes()[64:96] != b"Wine builtin DLL" + b"\0" * 16
PY

TRUNCATED_OPTIONAL="$TMP/truncated-optional-header.dll"
python3 - "$TRUNCATED_OPTIONAL" <<'PY'
from pathlib import Path
import struct
import sys

data = bytearray(144)
data[:2] = b"MZ"
struct.pack_into("<I", data, 60, 120)
data[120:124] = b"PE\0\0"
struct.pack_into("<H", data, 120 + 4 + 16, 32)
Path(sys.argv[1]).write_bytes(data)
PY

if python3 "$STAMP" "$TRUNCATED_OPTIONAL"; then
  echo "FAIL: truncated optional header input was accepted" >&2
  exit 1
fi

DIR="$TMP/dir-stamp"
mkdir -p "$DIR"
printf 'not a PE' >"$DIR/junk.dll"
python3 - "$DIR/good.dll" <<'INNER'
from pathlib import Path
import struct
import sys

data = bytearray(192)
data[:2] = b"MZ"
data[64:96] = b"unpatched DOS stub data........"
struct.pack_into("<I", data, 60, 120)
data[120:124] = b"PE\0\0"
struct.pack_into("<H", data, 120 + 4 + 16, 32)
Path(sys.argv[1]).write_bytes(data)
INNER
dir_out="$(python3 "$STAMP" "$DIR" 2>&1)"
assert_contains "$dir_out" "skip" "directory mode should skip non-PE DLLs"
assert_contains "$dir_out" "Stamped 1" "directory mode should stamp valid PE DLLs"

echo "PASS test-cyder-stamp-wine-builtin-pe"
