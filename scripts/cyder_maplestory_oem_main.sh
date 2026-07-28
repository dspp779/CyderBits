#!/usr/bin/env bash
# MapleStory OEM special edition entrypoint.
# Isolates bundle identity, Application Support, engine, and bottle from the
# official Cyder.app so Finder "Open With" and preferences do not collide.
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"

export CYDER_RUNTIME_ROOT="${CYDER_RUNTIME_ROOT:-$HOME/.cyder/runtime}"
# Separate support root → separate settings.json, game library, logs, GPTK runtime copy.
export CYDER_SUPPORT="${CYDER_SUPPORT:-$HOME/Library/Application Support/Cyder-maplestory-oem25}"
export CYDER_BUNDLE_ID="${CYDER_BUNDLE_ID:-local.cyder.maplestory-oem25}"
export CYDER_CAPTURE_WINE_LOG="${CYDER_CAPTURE_WINE_LOG:-0}"
export CYDER_TEMPLATE_REVISION=2
export CYDER_OEM_FLAVOR=maplestory

# Separate from the official Cyder layout under the same ~/.cyder/runtime tree.
export CYDER_ENGINE_NAME="${CYDER_ENGINE_NAME:-maplestory-oem25}"
export CYDER_BOTTLE_NAME="${CYDER_BOTTLE_NAME:-maplestory-oem25}"
export CYDER_PREFIX="${CYDER_PREFIX:-${CYDER_SHARED_PREFIX:-$CYDER_SUPPORT/bottles/$CYDER_BOTTLE_NAME}}"
export CYDER_SHARED_PREFIX="$CYDER_PREFIX"
export CYDER_WINE_FRONTEND_ARGS="${CYDER_WINE_FRONTEND_ARGS:---wait-children --enable-alt-loader macdrv}"

# One-time: older OEM builds stored the bottle under the shared Cyder support root.
_legacy_oem_bottle="$HOME/Library/Application Support/Cyder/bottles/$CYDER_BOTTLE_NAME"
if [[ -d "$_legacy_oem_bottle" && ! -e "$CYDER_PREFIX" ]]; then
  mkdir -p "$(dirname "$CYDER_PREFIX")"
  mv "$_legacy_oem_bottle" "$CYDER_PREFIX"
fi
unset _legacy_oem_bottle

# Optional OEM prepare helper (present when packaged). Native UI may invoke it.
if [[ -x "$SELF/CyderOEMBootstrap" ]]; then
  export CYDER_OEM_BOOTSTRAP_HELPER="$SELF/CyderOEMBootstrap"
fi

sync_dxvk="$SELF/../Resources/ogom-scripts/cyder-oem-sync-dxvk.sh"
archive_name_file="$SELF/../Resources/engine-archive.txt"
if [[ -x "$sync_dxvk" && -f "$archive_name_file" ]]; then
  archive_name="$(tr -d '[:space:]' <"$archive_name_file")"
  archive_path="$SELF/../Resources/$archive_name"
  "$sync_dxvk" \
    --engine "$CYDER_RUNTIME_ROOT/Engines/$CYDER_ENGINE_NAME" \
    --archive "$archive_path" || true
fi

# CrossOver Perl frontend reads bottle metadata via CX_BOTTLE.
export CX_BOTTLE="$CYDER_PREFIX"

exec "$SELF/CyderSwift" "$@"
