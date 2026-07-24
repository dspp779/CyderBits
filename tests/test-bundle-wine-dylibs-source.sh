#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

script="$(<"$ROOT/scripts/bundle-wine-dylibs.sh")"

assert_contains "$script" 'VULKAN_SOURCE="${VULKAN_SOURCE:-existing}"' \
  "repacking should preserve an engine's existing MoltenVK by default"
assert_contains "$script" '"crossover": (' \
  "bundler should have an explicit CrossOver MoltenVK selection path"
assert_contains "$script" '"homebrew": (' \
  "bundler should keep Homebrew as an explicit alternative"
assert_contains "$script" "macho_minos" \
  "bundler must gate Mach-O minos after copy"
assert_contains "$script" 'MACOSX_DEPLOYMENT_TARGET' \
  "minos gate must honour the product-floor deployment target"
assert_contains "$script" "remove orphan" \
  "bundler should drop leftover dylibs no longer in the seed graph"

crossover_block="$(sed -n '/"crossover": (/,/),/p' "$ROOT/scripts/bundle-wine-dylibs.sh")"
first_candidate="$(printf '%s\n' "$crossover_block" | rg 'libMoltenVK\.dylib' | head -1)"
assert_contains "$first_candidate" 'graphics_lib' \
  "CrossOver mode must prefer the CrossOver graphics artifact over Homebrew"

existing_block="$(sed -n '/"existing": (/,/),/p' "$ROOT/scripts/bundle-wine-dylibs.sh")"
first_existing="$(printf '%s\n' "$existing_block" | rg 'libMoltenVK\.dylib' | head -1)"
assert_contains "$first_existing" 'unix_lib' \
  "artifact repacking must preserve the already-tested engine renderer"

# Functional gate: a synthetic high-minos dylib must fail the bundler.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-bundle-minos.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/wine/lib/wine/x86_64-unix" "$TMP/brew/lib" \
  "$TMP/empty-graphics/lib" "$TMP/empty-media/lib"
# Build a tiny x86_64 dylib with minos 14.0 (above the 10.15 floor).
echo 'int ogom_bundle_minos_probe=1;' > "$TMP/probe.c"
arch -x86_64 clang -dynamiclib -mmacosx-version-min=14.0 \
  "$TMP/probe.c" -o "$TMP/brew/lib/libffi.8.dylib"
cp "$TMP/brew/lib/libffi.8.dylib" "$TMP/wine/lib/wine/x86_64-unix/libffi.8.dylib"

cat > "$TMP/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$1"
WINE="$2"
BREW="$3"
EMPTY_GRAPHICS="$4"
EMPTY_MEDIA="$5"
# Non-empty overrides: env-x86_64 treats "" as unset for :- defaults.
export HOMEBREW_PREFIX="$BREW"
export HOMEBREW_REPOSITORY="$BREW"
export HOMEBREW_CELLAR="$BREW/Cellar"
export GRAPHICS_INSTALL="$EMPTY_GRAPHICS"
export MEDIA_INSTALL="$EMPTY_MEDIA"
export MACOSX_DEPLOYMENT_TARGET=10.15
# shellcheck disable=SC1091
source "$ROOT/scripts/env-x86_64.sh"
bash "$ROOT/scripts/bundle-wine-dylibs.sh" "$WINE"
EOF
chmod +x "$TMP/run.sh"

set +e
out="$("$TMP/run.sh" "$ROOT" "$TMP/wine" "$TMP/brew" \
  "$TMP/empty-graphics" "$TMP/empty-media" 2>&1)"
status=$?
set -e
assert_eq "$status" "1" "bundler must fail when a dylib minos exceeds 10.15"
assert_contains "$out" "minos exceeds product floor" \
  "failure message should mention the product-floor minos gate"
assert_contains "$out" "libffi.8.dylib" \
  "failure should name the high-minos dylib"

echo "PASS test-bundle-wine-dylibs-source"
