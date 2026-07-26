#!/usr/bin/env bash
# MapleStory OEM special edition entrypoint.
# Keeps the public Cyder.app identity, but isolates engine + bottle names so
# they do not collide with the regular Cyder wine-x86_64 / bottles/shared tree.
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"

export CYDER_RUNTIME_ROOT="${CYDER_RUNTIME_ROOT:-$HOME/.cyder/runtime}"
export CYDER_SUPPORT="${CYDER_SUPPORT:-$HOME/Library/Application Support/Cyder}"
export CYDER_BUNDLE_ID="local.cyder.app"
export CYDER_CAPTURE_WINE_LOG="${CYDER_CAPTURE_WINE_LOG:-0}"
export CYDER_TEMPLATE_REVISION=2
export CYDER_OEM_FLAVOR=maplestory

# Separate from the official Cyder layout under the same runtime/support roots.
export CYDER_ENGINE_NAME="${CYDER_ENGINE_NAME:-maplestory-oem25}"
export CYDER_BOTTLE_NAME="${CYDER_BOTTLE_NAME:-maplestory-oem25}"
export CYDER_PREFIX="${CYDER_PREFIX:-${CYDER_SHARED_PREFIX:-$CYDER_SUPPORT/bottles/$CYDER_BOTTLE_NAME}}"
export CYDER_SHARED_PREFIX="$CYDER_PREFIX"
export CYDER_WINE_FRONTEND_ARGS="${CYDER_WINE_FRONTEND_ARGS:---wait-children --enable-alt-loader macdrv}"

# Optional OEM prepare helper (present when packaged). Native UI may invoke it.
if [[ -x "$SELF/CyderOEMBootstrap" ]]; then
  export CYDER_OEM_BOOTSTRAP_HELPER="$SELF/CyderOEMBootstrap"
fi

# CrossOver Perl frontend reads bottle metadata via CX_BOTTLE.
export CX_BOTTLE="$CYDER_PREFIX"

exec "$SELF/CyderSwift" "$@"
