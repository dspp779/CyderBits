#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Independent of the developer machine's installed codecs and environment.
for name in GST_PLUGIN_PATH GST_PLUGIN_PATH_1_0 GST_PLUGIN_SYSTEM_PATH GST_PLUGIN_SYSTEM_PATH_1_0 \
  GST_PLUGIN_SCANNER GST_PLUGIN_SCANNER_1_0 GST_REGISTRY GST_REGISTRY_1_0 \
  CYDER_MEDIA_PLUGIN_DIR CYDER_MEDIA_SCANNER CYDER_MEDIA_REGISTRY; do
  unset "$name"
done
source "$ROOT/scripts/cyder-common.sh"
export CYDER_SUPPORT="$TMP/support"
cyder_init_paths "$ROOT/scripts"
engine="$TMP/搬移 engine"
other="$TMP/second engine"
for path in "$engine" "$other"; do
  mkdir -p "$path/bin" "$path/lib/wine/gstreamer-1.0" \
    "$path/lib/wine/x86_64-unix" "$path/libexec/gstreamer-1.0"
  touch "$path/lib/wine/x86_64-unix/libgstreamer-1.0.0.dylib"
  printf '#!/bin/sh\nexit 0\n' >"$path/libexec/gstreamer-1.0/gst-plugin-scanner"
  chmod +x "$path/libexec/gstreamer-1.0/gst-plugin-scanner"
  printf 'Cyder012\n' >"$path/version"
done

cyder_apply_media_launch_environment "$engine"
assert_eq "$CYDER_MEDIA_STATUS" bundled "relocated full-video engine should select its media stack"
assert_eq "$GST_PLUGIN_PATH_1_0" "$engine/lib/wine/gstreamer-1.0" "preserve spaces and Unicode"
assert_eq "$GST_PLUGIN_SYSTEM_PATH_1_0" "$GST_PLUGIN_PATH_1_0" "avoid host system plugins"
assert_eq "$GST_PLUGIN_SCANNER" "$engine/libexec/gstreamer-1.0/gst-plugin-scanner" "select bundled scanner"
first_registry="$GST_REGISTRY_1_0"
assert test -w "$(dirname "$first_registry")"
cyder_apply_media_launch_environment "$engine"
assert_eq "$GST_REGISTRY_1_0" "$first_registry" "same engine should reuse its cache"
printf 'Cyder013\n' >"$engine/version"
cyder_apply_media_launch_environment "$engine"
assert test "$GST_REGISTRY_1_0" != "$first_registry"
cyder_apply_media_launch_environment "$other"
assert_eq "$GST_PLUGIN_PATH_1_0" "$other/lib/wine/gstreamer-1.0" "engine switch must clear managed paths"
assert test "$GST_REGISTRY_1_0" != "$first_registry"
cyder_apply_media_launch_environment "$TMP/old-engine"
assert_eq "$CYDER_MEDIA_STATUS" unavailable "legacy engine remains launchable"
assert_eq "${GST_PLUGIN_PATH_1_0-unset}|${GST_PLUGIN_SCANNER-unset}|${GST_REGISTRY_1_0-unset}" \
  'unset|unset|unset' "old engine must not inherit the previous engine's media paths"

# Intentional external settings, even an empty path, remain authoritative.
export GST_PLUGIN_SYSTEM_PATH_1_0=""
cyder_apply_media_launch_environment "$engine"
assert_eq "$CYDER_MEDIA_STATUS" external "an intentional empty path must be respected"
assert_eq "${GST_PLUGIN_PATH_1_0-unset}" unset "do not mix bundled and custom stacks"
unset GST_PLUGIN_SYSTEM_PATH_1_0
export GST_PLUGIN_PATH=/external/plugins GST_PLUGIN_SCANNER_1_0=/external/scanner
cyder_apply_media_launch_environment "$engine"
assert_eq "$GST_PLUGIN_PATH|$GST_PLUGIN_SCANNER_1_0" '/external/plugins|/external/scanner' "respect legacy aliases and versioned scanner"
unset GST_PLUGIN_PATH GST_PLUGIN_SCANNER_1_0
export GST_REGISTRY_1_0="$TMP/custom-registry.bin"
cyder_apply_media_launch_environment "$engine"
assert_eq "$GST_REGISTRY_1_0" "$TMP/custom-registry.bin" "preserve a custom registry while fixing discovery"
cyder_apply_media_launch_environment "$TMP/old-engine"
assert_eq "$GST_REGISTRY_1_0" "$TMP/custom-registry.bin" "do not clear an externally owned registry"
unset GST_REGISTRY_1_0
export GST_REGISTRY="$TMP/legacy-registry.bin"
cyder_apply_media_launch_environment "$engine"
assert_eq "$GST_REGISTRY" "$TMP/legacy-registry.bin" "respect the unversioned registry alias"
assert_eq "${GST_REGISTRY_1_0-unset}" unset "do not shadow a custom registry with a versioned value"
cyder_apply_media_launch_environment "$TMP/old-engine"
unset GST_REGISTRY

# A bad cache location must not prevent a non-media game from launching.
touch "$TMP/not-a-directory"
saved_support="$CYDER_SUPPORT"
CYDER_SUPPORT="$TMP/not-a-directory"
cyder_apply_media_launch_environment "$engine" 2>/dev/null
assert_eq "$CYDER_MEDIA_STATUS" bundled-default-cache "cache failure should fall back without aborting"
assert_eq "${GST_REGISTRY_1_0-unset}" unset "do not export an unwritable registry"
CYDER_SUPPORT="$saved_support"

# A caller changing one previously managed path opts into an external stack.
cyder_apply_media_launch_environment "$engine"
export GST_PLUGIN_PATH_1_0=/changed/plugins
cyder_apply_media_launch_environment "$other"
assert_eq "$GST_PLUGIN_PATH_1_0" /changed/plugins "preserve caller edits across engine switches"
assert_eq "${GST_PLUGIN_SCANNER-unset}" unset "remove the previously managed scanner"
unset GST_PLUGIN_PATH_1_0
chmod -x "$other/libexec/gstreamer-1.0/gst-plugin-scanner"
cyder_apply_media_launch_environment "$other"
assert_eq "$CYDER_MEDIA_STATUS" unavailable "partial stack must not publish broken scanner paths"

# Exercise the actual launch boundary: a fake Wine launcher starts a child,
# which must receive the same stack under every supported graphics preference.
mkdir -p "$TMP/arch-bin" "$TMP/prefix"
printf '#!/bin/bash\n[[ "${1:-}" != -x86_64 ]] || shift\nexec "$@"\n' >"$TMP/arch-bin/arch"
cat >"$engine/bin/wine" <<'SH'
#!/bin/bash
/bin/bash -c 'printf "%s\n" "$GST_PLUGIN_PATH_1_0" "$GST_PLUGIN_SYSTEM_PATH_1_0" "$GST_PLUGIN_SCANNER" "$GST_REGISTRY_1_0" >"$CYDER_TEST_MEDIA_CHILD"'
SH
chmod +x "$TMP/arch-bin/arch" "$engine/bin/wine"
touch "$TMP/game.exe"
for backend in dxmt d3dmetal wined3d; do
  (
    export PATH="$TMP/arch-bin:$PATH" CYDER_TEST_MEDIA_CHILD="$TMP/$backend.child"
    export CYDER_SHARED_PREFIX="$TMP/prefix" CYDER_GRAPHICS_BACKEND="$backend"
    export CYDER_CAPTURE_WINE_LOG=1 CYDER_MSYNC=0 CYDER_ESYNC=0 CYDER_POWER_MODE=normal
    export CYDER_WINE_START_MODE=direct
    # These unrelated subsystems must not touch the developer's actual runtime.
    cyder_apply_moltenvk_variant_from_preference() { :; }
    cyder_apply_gptk_launch_environment() { :; }
    cyder_validate_moltenvk_for_backend() { :; }
    cyder_apply_scrolling_for_exe() { :; }
    cyder_run_wine_exe "$engine/bin/wine" "$TMP/game.exe"
  )
  child="$(cat "$TMP/$backend.child")"
  assert_contains "$child" "$engine/lib/wine/gstreamer-1.0" "$backend launcher child must inherit plugin paths"
  assert_contains "$child" "$engine/libexec/gstreamer-1.0/gst-plugin-scanner" "$backend child must inherit scanner"
  assert_contains "$child" '/registry-x86_64-' "$backend child must inherit private registry"
done
assert_contains "$(cat "$CYDER_SUPPORT/Logs/last-launch.log")" 'Media runtime: bundled' "diagnostics must identify the selected media stack"
echo 'PASS: media runtime relocation, overrides, cache identity and launcher inheritance'
