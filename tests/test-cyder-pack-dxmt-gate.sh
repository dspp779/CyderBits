#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

graphics_pack="$(cat "$ROOT/scripts/pack-graphics-payloads.sh")"
engine_pack="$(cat "$ROOT/scripts/pack-engine-artifact.sh")"
assert_contains "$graphics_pack" 'lib/dxmt' \
  "graphics pack must require the DXMT payload"
assert_contains "$engine_pack" "pack-graphics-payloads.sh" \
  "engine pack must create graphics payloads before stripping the engine"
assert_contains "$engine_pack" 'graphics_pack_args+=(--force)' \
  "engine pack must forward --force to graphics pack"
assert_contains "$engine_pack" "--exclude 'lib/dxmt'" \
  "engine archive must exclude DXMT"
assert_contains "$engine_pack" "--exclude 'lib/dxvk'" \
  "engine archive must exclude DXVK"
assert_contains "$engine_pack" "--exclude 'lib/dxvk2'" \
  "engine archive must exclude DXVK2"

graphics_pack_line="$(rg -n -F 'pack-graphics-payloads.sh' \
  "$ROOT/scripts/pack-engine-artifact.sh" | head -n1 | cut -d: -f1)"
archive_exit_line="$(rg -n -F 'if [[ -f "$ARCHIVE" && "$FORCE" -ne 1 ]]; then' \
  "$ROOT/scripts/pack-engine-artifact.sh" | cut -d: -f1)"
[[ "$graphics_pack_line" -lt "$archive_exit_line" ]] || {
  echo "ASSERT failed: existing engine archive must not bypass graphics packing" >&2
  exit 1
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cyder-engine-pack-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
engine="$tmp/engine"
artifacts="$tmp/artifacts"
fake_zstd="$tmp/zstd"
mkdir -p "$engine/bin" "$engine/lib/dxvk" "$engine/lib/dxmt" "$artifacts"
printf 'dxvk v1.2.3\n' >"$engine/lib/dxvk/version"
printf 'dxmt v4.5.6\n' >"$engine/lib/dxmt/version"
touch "$engine/bin/wine" "$artifacts/engine-wine-x86_64-test.tar.xz"
chmod +x "$engine/bin/wine"

python3 - "$engine/lib/dxvk/d3d11.dll" <<'PY'
import struct
import sys

contents = bytearray(128)
contents[:2] = b"MZ"
struct.pack_into("<I", contents, 60, 96)
contents[96:100] = b"PE\0\0"
open(sys.argv[1], "wb").write(contents)
PY
printf 'dxmt\n' >"$engine/lib/dxmt/payload"
cat >"$fake_zstd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat >"$output"
EOF
chmod +x "$fake_zstd"

CYDER_ENGINE_ARTIFACTS_DIR="$artifacts" CYDER_ENGINE_VERSION_LABEL="test" \
  CYDER_ZSTD="$fake_zstd" WINE_INSTALL="$engine" \
  bash "$ROOT/scripts/pack-engine-artifact.sh"
assert test -f "$artifacts/graphics/dxvk-1.2.3.tar.zst"
assert test -f "$artifacts/graphics/dxmt-4.5.6.tar.zst"
assert test -f "$artifacts/graphics/dxvk-version.txt"
assert test -f "$artifacts/graphics/dxmt-version.txt"
assert test -f "$artifacts/graphics/dxvk-artifact-sha256.txt"
assert test -f "$artifacts/graphics/dxmt-artifact-sha256.txt"

echo "PASS test-cyder-pack-dxmt-gate"
