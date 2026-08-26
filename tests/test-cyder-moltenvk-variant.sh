#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
# shellcheck source=../scripts/cyder-macos-compat.sh
source "$ROOT/scripts/cyder-macos-compat.sh"
# shellcheck source=../scripts/cyder-moltenvk-variant.sh
source "$ROOT/scripts/cyder-moltenvk-variant.sh"

FAKE="$(mktemp -d "${TMPDIR:-/tmp}/cyder-mvk-variant.XXXXXX")"
cleanup() { rm -rf "$FAKE"; }
trap cleanup EXIT

UNIX="$FAKE/lib/wine/x86_64-unix"
mkdir -p "$UNIX"
# Empty reals are enough for symlink apply; shim needs the marker string.
: >"$UNIX/libMoltenVK-1.4.2.dylib"
: >"$UNIX/libMoltenVK-1.2.10.dylib"
printf 'cyder-moltenvk-timeline-wait-poll\n' >"$UNIX/libMoltenvk-shim-body.txt"
# Minimal Mach-O is not required for marker check; stub a file and mock otool via PATH.
printf 'cyder-moltenvk-timeline-wait-poll\n' >"$UNIX/libMoltenVK.dylib"
# Provide a fake otool that reports the re-export for the shim.
BIN="$FAKE/bin"
mkdir -p "$BIN"
cat >"$BIN/otool" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *libMoltenVK.dylib* ]]; then
  echo "	@loader_path/libMoltenVK.real.dylib (compatibility version 1.0.0, current version 1.0.0)"
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/otool"
# Prefer system strings(1); ensure otool mock wins.
export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"

CYDER_MOCK_MACOS=11.0
assert_eq "$(cyder_resolve_moltenvk_variant 1.4.2)" "1.2.10" \
  "macOS 11 must force MoltenVK 1.2.10 even when preference is 1.4.2"

CYDER_MOCK_MACOS=13.0
assert_eq "$(cyder_resolve_moltenvk_variant 1.2.10)" "1.2.10" \
  "macOS 13 must respect preference 1.2.10"
assert_eq "$(cyder_resolve_moltenvk_variant 1.4.2)" "1.4.2" \
  "macOS 13 must respect preference 1.4.2"

CYDER_MOCK_MACOS=13.0
cyder_apply_moltenvk_variant "$FAKE" "1.4.2"
assert_eq "$(readlink "$UNIX/libMoltenVK.real.dylib")" "libMoltenVK-1.4.2.dylib" \
  "apply 1.4.2 must point .real at versioned dylib"
cyder_apply_moltenvk_variant "$FAKE" "1.4.2"
assert_eq "$(readlink "$UNIX/libMoltenVK.real.dylib")" "libMoltenVK-1.4.2.dylib" \
  "apply twice must stay stable"
cyder_apply_moltenvk_variant "$FAKE" "1.2.10"
assert_eq "$(readlink "$UNIX/libMoltenVK.real.dylib")" "libMoltenVK-1.2.10.dylib" \
  "switching preference must retarget .real"

CYDER_MOCK_MACOS=11.0
cyder_apply_moltenvk_variant "$FAKE" "1.4.2"
assert_eq "$(readlink "$UNIX/libMoltenVK.real.dylib")" "libMoltenVK-1.2.10.dylib" \
  "apply on macOS 11 must force 1.2.10"

# Soft apply on engines without dual layout must succeed.
SINGLE="$(mktemp -d "${TMPDIR:-/tmp}/cyder-mvk-single.XXXXXX")"
mkdir -p "$SINGLE/lib/wine/x86_64-unix"
: >"$SINGLE/lib/wine/x86_64-unix/libMoltenVK.dylib"
assert cyder_apply_moltenvk_variant_if_present "$SINGLE" "1.4.2"
rm -rf "$SINGLE"

common="$(cat "$ROOT/scripts/cyder-common.sh")"
launcher="$(cat "$ROOT/scripts/cyder_launcher.sh")"
assert_contains "$common" 'cyder_apply_moltenvk_variant' \
  "common.sh must call MoltenVK variant apply"
assert_contains "$(cat "$ROOT/scripts/cyder-common.sh")" 'cyder-moltenvk-variant.sh' \
  "common.sh must source moltenvk variant helper"
# Launcher loads settings which apply; also assert explicit hook if present.
if ! grep -Fq 'cyder_apply_moltenvk' <<<"$launcher$common"; then
  echo "ASSERT failed: launcher path must apply MoltenVK variant" >&2
  exit 1
fi

settings="$(cat "$ROOT/scripts/cyder_settings.swift")"
assert_contains "$settings" 'moltenvkVariant' "settings must store moltenvkVariant"
assert_contains "$settings" 'schemaVersion = 13' "schema must bump to 13"
assert_contains "$settings" 'var menuTitle: String { rawValue }' \
  "MoltenVK menu titles must be version numbers only"
assert_not_contains "$settings" 'MoltenVK 1.4.2' \
  "MoltenVK menu must not prefix titles with MoltenVK"

ui="$(cat "$ROOT/scripts/cyder_settings_ui.swift")"
assert_contains "$ui" 'moltenvkVariant' "settings UI must expose MoltenVK variant"
assert_contains "$ui" 'showMoltenvk = backend.usesDxvkTranslation' \
  "MoltenVK picker must only show when graphics backend is DXVK"
assert_contains "$ui" 'moltenvkVariant.isHidden = !showMoltenvk' \
  "MoltenVK picker visibility must follow DXVK selection"

echo "PASS test-cyder-moltenvk-variant"
