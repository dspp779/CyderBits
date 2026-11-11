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
assert_contains "$(cat "$ROOT/scripts/create-cyder-app.sh")" \
  'cyder-ensure-graphics.sh' \
  "Cyder.app must bundle the graphics payload ensurer"
assert_not_contains "$(cat "$ROOT/scripts/cyder-common.sh")" \
  'install-dxvk-prefix.sh' \
  "Launch path must not copy DXVK PE into prefixes"
assert_not_contains "$(cat "$ROOT/scripts/build-wine.sh")" \
  'cyder-compatdb-runtime.patch' \
  "DXVK prepend must not require an ntdll patch"

build_dxvk="$(cat "$ROOT/scripts/build-dxvk.sh")"
assert_contains "$build_dxvk" 'pin-dxvk-version.py' \
  "build-dxvk.sh must pin DXVK via pin-dxvk-version.py"
assert_contains "$build_dxvk" 'lib/dxvk/version' \
  "build-dxvk.sh must write lib/dxvk/version for graphics pack"
assert_contains "$build_dxvk" '__MINGW64_VERSION_MAJOR < 15' \
  "build-dxvk.sh must skip dummy D3DDEVINFO_RESOURCEMANAGER on MinGW-w64 15+"
assert_contains "$build_dxvk" 'install/wine-cx26-x86_64' \
  "build-dxvk.sh default engine must be the CX26 install prefix"
assert_not_contains "$build_dxvk" 'maplestory-oem25' \
  "build-dxvk.sh must not default to the retired OEM work tree"

# B4G4R4A4 emulation for Metal GPUs without 4-bit formats.
emu_patch="$ROOT/patches/cyder-dxvk-b4g4r4a4-emulation.patch"
assert_contains "$build_dxvk" 'cyder-dxvk-b4g4r4a4-emulation.patch' \
  "build-dxvk.sh must apply the B4G4R4A4 emulation patch"
emu_text="$(cat "$emu_patch")"
assert_contains "$emu_text" 'VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT' \
  "emulation must check real 4444 format support, not only the extension feature"
assert_contains "$emu_text" 'VK_FORMAT_B8G8R8A8_UNORM (emulated)' \
  "emulation must fall back to B8G8R8A8"
for hook in 'ConvertB4G4R4A4ToB8G8R8A8(convertedStorage' \
            'ConvertB4G4R4A4ToB8G8R8A8(stagingSlice' \
            'PackB4G4R4A4InPlace(pMappedResource' \
            'ExpandB4G4R4A4InPlace(reinterpret_cast' \
            'ExpandB4G4R4A4InPlace(entry->MapInfo'; do
  assert_contains "$emu_text" "$hook" "emulation must convert texels at $hook"
done

# Round-trip the conversion helpers the patch adds.
mkdir -p "$TMP/emu/src/d3d11"
(cd "$TMP/emu" && patch -s -p1 --batch < <(awk '
  /^diff / { keep = ($0 ~ /d3d11_b4g4r4a4\.h/) }
  keep' "$emu_patch"))
cat > "$TMP/emu/t.cpp" <<'CPP'
#include "d3d11_b4g4r4a4.h"
#include <vector>
using namespace dxvk;
int main() {
  for (uint32_t v = 0; v < 65536; v++)
    if (PackB4G4R4A4(ExpandB4G4R4A4(uint16_t(v))) != v) return 1;
  if (ExpandB4G4R4A4(0xF00F) != 0xFF0000FFu) return 2;
  const uint32_t W = 7, H = 3, pitch = 32;
  std::vector<char> buf(pitch * H, 0x55);
  std::vector<uint16_t> src(W * H);
  for (uint32_t i = 0; i < W * H; i++) src[i] = uint16_t(i * 2654435761u);
  for (uint32_t y = 0; y < H; y++) std::memcpy(&buf[y * pitch], &src[y * W], W * 2);
  std::vector<char> ref(pitch * H, 0);
  ConvertB4G4R4A4ToB8G8R8A8(ref.data(), pitch, pitch * H, src.data(), W * 2, W * 2 * H, W, H, 1);
  ExpandB4G4R4A4InPlace(buf.data(), pitch, pitch * H, W, H, 1);
  for (uint32_t y = 0; y < H; y++)
    if (std::memcmp(&buf[y * pitch], &ref[y * pitch], W * 4)) return 3;
  PackB4G4R4A4InPlace(buf.data(), pitch, pitch * H, W, H, 1);
  for (uint32_t y = 0; y < H; y++)
    if (std::memcmp(&buf[y * pitch], &src[y * W], W * 2)) return 4;
  return 0;
}
CPP
if command -v clang++ >/dev/null 2>&1; then
  clang++ -std=c++17 -I "$TMP/emu/src/d3d11" "$TMP/emu/t.cpp" -o "$TMP/emu/t"
  "$TMP/emu/t" || { echo "FAIL B4G4R4A4 conversion round-trip (code $?)" >&2; exit 1; }
else
  echo "SKIP B4G4R4A4 conversion round-trip: clang++ not found"
fi

echo "PASS test-cyder-dxvk"
