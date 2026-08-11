#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

help="$(bash "$ROOT/scripts/pack-graphics-payloads.sh" --help)"
assert_contains "$help" "dxvk" "graphics pack help must list DXVK"
assert_contains "$help" "dxvk2" "graphics pack help must list DXVK2"
assert_contains "$help" "dxmt" "graphics pack help must list DXMT"

pack="$(<"$ROOT/scripts/pack-graphics-payloads.sh")"
assert_contains "$pack" "stamp-wine-builtin-pe.py" \
  "graphics pack must stamp staged DXVK DLLs as Wine builtins"
assert_contains "$pack" '"$name" == dxvk || "$name" == dxvk2' \
  "graphics pack must stamp both DXVK families as Wine builtins"
assert_contains "$pack" 'pack_payload dxvk2' \
  "graphics pack must produce a DXVK2 payload archive"
assert_contains "$pack" 'artifact-sha256.txt' \
  "graphics pack must write artifact checksum sidecars"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cyder-graphics-pack-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
engine="$tmp/engine"
output_dir="$tmp/relative-output"
fake_zstd="$tmp/zstd"
mkdir -p "$engine/lib/dxvk" "$engine/lib/dxmt" "$engine/lib/dxvk2"
printf 'dxvk v1.2.3\n' >"$engine/lib/dxvk/version"
printf 'dxvk v2.7.1\n' >"$engine/lib/dxvk2/version"
printf 'dxmt v4.5.6\n' >"$engine/lib/dxmt/version"

python3 - "$engine/lib/dxvk/d3d11.dll" <<'PY'
import struct
import sys

contents = bytearray(128)
contents[:2] = b"MZ"
struct.pack_into("<I", contents, 60, 96)
contents[96:100] = b"PE\0\0"
open(sys.argv[1], "wb").write(contents)
PY
python3 - "$engine/lib/dxvk2/d3d11.dll" <<'PY'
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

(
  cd "$tmp"
  CYDER_ZSTD="$fake_zstd" bash "$ROOT/scripts/pack-graphics-payloads.sh" \
    --engine "$engine" --output-dir "$(basename "$output_dir")"
)
assert test -f "$output_dir/dxvk-1.2.3.tar.zst"
assert test -f "$output_dir/dxvk2-2.7.1.tar.zst"
assert test -f "$output_dir/dxmt-4.5.6.tar.zst"
assert test -f "$output_dir/dxvk-version.txt"
assert test -f "$output_dir/dxvk2-version.txt"
assert test -f "$output_dir/dxmt-version.txt"
assert test -f "$output_dir/dxvk-artifact-sha256.txt"
assert test -f "$output_dir/dxvk2-artifact-sha256.txt"
assert test -f "$output_dir/dxmt-artifact-sha256.txt"

echo "PASS test-cyder-pack-graphics-payloads"
