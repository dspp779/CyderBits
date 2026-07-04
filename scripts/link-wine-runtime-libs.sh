#!/usr/bin/env bash
# Make Wine runtime libraries relocatable (bundle Homebrew dylibs into the tree).
# Prefer scripts/bundle-wine-dylibs.sh; this wrapper keeps older docs working.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/bundle-wine-dylibs.sh" "$@"
