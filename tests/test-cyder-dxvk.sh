#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-dxvk.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PAYLOAD="$TMP/dxvk"

mkdir -p "$PAYLOAD/x86_64-windows"
python3 - "$PAYLOAD/x86_64-windows/d3d11.dll" <<'PY'
import struct
import sys

contents = bytearray(128)
contents[:2] = b"MZ"
struct.pack_into("<I", contents, 60, 96)
contents[96:100] = b"PE\0\0"
open(sys.argv[1], "wb").write(contents)
PY

python3 "$ROOT/scripts/stamp-wine-builtin-pe.py" "$PAYLOAD"

python3 - "$PAYLOAD/x86_64-windows/d3d11.dll" <<'PY'
import sys
from pathlib import Path

contents = Path(sys.argv[1]).read_bytes()
assert contents[64:96] == b"Wine builtin DLL" + b"\0" * 16
PY

# Prepend model: DXVK is stamped for builtin load order; bottles keep Wine PE.
patch_text="$(cat "$ROOT/patches/cyder-compatdb-runtime.patch")"
assert_not_contains "$patch_text" '!strcmp( backend, "dxvk" ) ? "n,b" : "b"' \
  "DXVK must not use native-first n,b overrides in the prepend model"
assert_contains "$patch_text" 'add_backend_override( applied, modules[i], "b" )' \
  "DXVK/DXMT backend modules must use builtin load order"
assert_contains "$(cat "$ROOT/scripts/create-cyder-app.sh")" \
  'cyder-ensure-graphics.sh' \
  "Cyder.app must bundle the graphics payload ensurer"
assert_not_contains "$(cat "$ROOT/scripts/cyder-common.sh")" \
  'install-dxvk-prefix.sh' \
  "Launch path must not copy DXVK PE into prefixes"

build_dxvk="$(cat "$ROOT/scripts/build-dxvk.sh")"
assert_contains "$build_dxvk" 'pin-dxvk-version.py' \
  "build-dxvk.sh must pin DXVK via pin-dxvk-version.py"
assert_contains "$build_dxvk" 'lib/dxvk/version' \
  "build-dxvk.sh must write lib/dxvk/version for graphics pack"

echo "PASS test-cyder-dxvk"
