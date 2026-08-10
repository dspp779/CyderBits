#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cyder-ensure-graphics-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

resources_root="$tmp/Resources"
resources="$resources_root/graphics"
runtime="$tmp/runtime"
engine_name="wine-test"
engine="$runtime/Engines/$engine_name"
fake_zstd="$resources_root/tools/zstd/zstd"
mkdir -p "$resources" "$resources_root/tools/zstd" "$tmp/staging/dxvk" "$tmp/staging/dxmt"

printf 'dxvk payload\n' >"$tmp/staging/dxvk/d3d11.dll"
printf 'dxvk-1.2.3\n' >"$tmp/staging/dxvk/version"
printf 'dxmt payload\n' >"$tmp/staging/dxmt/d3d11.dll"
printf 'dxmt-4.5.6\n' >"$tmp/staging/dxmt/version"
tar -cf "$resources/dxvk-1.2.3.tar.zst" -C "$tmp/staging" dxvk
tar -cf "$resources/dxmt-4.5.6.tar.zst" -C "$tmp/staging" dxmt
printf '1.2.3\n' >"$resources/dxvk-version.txt"
printf '4.5.6\n' >"$resources/dxmt-version.txt"
printf '%s  %s\n' "$(shasum -a 256 "$resources/dxvk-1.2.3.tar.zst" | awk '{print $1}')" \
  "dxvk-1.2.3.tar.zst" >"$resources/dxvk-artifact-sha256.txt"
printf '%s  %s\n' "$(shasum -a 256 "$resources/dxmt-4.5.6.tar.zst" | awk '{print $1}')" \
  "dxmt-4.5.6.tar.zst" >"$resources/dxmt-artifact-sha256.txt"

cat >"$fake_zstd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "-d" && "$2" == "-c" ]]
cat "$3"
EOF
chmod +x "$fake_zstd"

env -u CYDER_ZSTD \
  PATH=/usr/bin:/bin \
  CYDER_OGOM="$resources_root" \
  CYDER_GRAPHICS_SRC="$resources" \
  CYDER_RUNTIME_ROOT="$runtime" \
  CYDER_ENGINES="$runtime/Engines" \
  CYDER_ENGINE_NAME="$engine_name" \
  bash "$ROOT/scripts/cyder-ensure-graphics.sh"

assert test -f "$runtime/graphics/dxvk/1.2.3/d3d11.dll"
assert test -f "$runtime/graphics/dxmt/4.5.6/d3d11.dll"
assert test -L "$runtime/graphics/current-dxvk"
assert test -L "$runtime/graphics/current-dxmt"
assert_eq "$(readlink "$engine/lib/dxvk")" "../../../graphics/current-dxvk" \
  "DXVK engine symlink must be relative to engine lib"
assert_eq "$(readlink "$engine/lib/dxmt")" "../../../graphics/current-dxmt" \
  "DXMT engine symlink must be relative to engine lib"
assert test -f "$engine/lib/dxvk/d3d11.dll"
assert test -f "$engine/lib/dxmt/d3d11.dll"

rm -rf "$tmp/staging/dxvk"
mkdir -p "$tmp/staging/dxvk"
printf 'updated dxvk payload\n' >"$tmp/staging/dxvk/d3d11.dll"
printf 'dxvk-1.2.4\n' >"$tmp/staging/dxvk/version"
tar -cf "$resources/dxvk-1.2.4.tar.zst" -C "$tmp/staging" dxvk
printf '1.2.4\n' >"$resources/dxvk-version.txt"
printf '%s  %s\n' "$(shasum -a 256 "$resources/dxvk-1.2.4.tar.zst" | awk '{print $1}')" \
  "dxvk-1.2.4.tar.zst" >"$resources/dxvk-artifact-sha256.txt"

env -u CYDER_ZSTD \
  PATH=/usr/bin:/bin \
  CYDER_OGOM="$resources_root" \
  CYDER_GRAPHICS_SRC="$resources" \
  CYDER_RUNTIME_ROOT="$runtime" \
  CYDER_ENGINES="$runtime/Engines" \
  CYDER_ENGINE_NAME="$engine_name" \
  bash "$ROOT/scripts/cyder-ensure-graphics.sh"

assert_eq "$(<"$engine/lib/dxvk/d3d11.dll")" "updated dxvk payload" \
  "DXVK engine symlink must follow the updated current payload"
assert_eq "$(readlink "$runtime/graphics/current-dxvk")" "dxvk/1.2.4" \
  "DXVK current symlink must be updated atomically"

echo "PASS test-cyder-ensure-graphics"
