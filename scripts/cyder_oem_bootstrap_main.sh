#!/usr/bin/env bash
# Optional OEM prepare helper for MapleStory special edition.
# Prefer the shared Cyder bootstrap path (cyder_init_bottle seeds cxbottle.conf).
# This helper remains for first-run UI progress when CyderSwift invokes it.
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$SELF/../Resources" && pwd)"
PREPARE_ONLY=0
if [[ "${1:-}" == "--prepare-only" ]]; then
  PREPARE_ONLY=1
  shift
fi

export CYDER_RUNTIME_ROOT="${CYDER_RUNTIME_ROOT:-$HOME/.cyder/runtime}"
export CYDER_SUPPORT="${CYDER_SUPPORT:-$HOME/Library/Application Support/Cyder}"
export CYDER_OEM_FLAVOR=maplestory
export CYDER_ENGINE_NAME="${CYDER_ENGINE_NAME:-maplestory-oem25}"
export CYDER_BOTTLE_NAME="${CYDER_BOTTLE_NAME:-maplestory-oem25}"
export CYDER_PREFIX="${CYDER_PREFIX:-${CYDER_SHARED_PREFIX:-$CYDER_SUPPORT/bottles/$CYDER_BOTTLE_NAME}}"
export CYDER_SHARED_PREFIX="$CYDER_PREFIX"
export CYDER_ENGINE_VERSION_LABEL="${CYDER_ENGINE_VERSION_LABEL:-MapleStory OEM CrossOver 25.0.1.38865}"
export CYDER_TEMPLATE_REVISION="${CYDER_TEMPLATE_REVISION:-2}"
export CYDER_BUNDLE_ID="${CYDER_BUNDLE_ID:-local.cyder.app}"
export CYDER_WINE_FRONTEND_ARGS="${CYDER_WINE_FRONTEND_ARGS:---wait-children --enable-alt-loader macdrv}"
export CX_BOTTLE="$CYDER_PREFIX"

archive_name="$(tr -d '[:space:]' <"$RES/engine-archive.txt")"
archive="$RES/$archive_name"
launcher="$RES/ogom-scripts/cyder_launcher.sh"

mkdir -p "$CYDER_SUPPORT/Logs"

CYDER_ENGINE_SRC="$archive" \
CYDER_LIBARCHIVE_SRC="$RES/addons/libarchive" \
OGOM="$RES" \
WINE_INSTALL="$archive" \
ENTITLEMENTS_PLIST="$RES/entitlements.plist" \
CYDER_ENTITLEMENTS="$RES/entitlements.plist" \
  bash "$launcher" --engine-src "$archive" --bootstrap-only

if [[ "$PREPARE_ONLY" -eq 1 ]]; then
  exit 0
fi

exec "$SELF/CyderSwift" "$@"
