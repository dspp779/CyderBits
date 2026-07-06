#!/usr/bin/env bash
# CyderBits.app must ship cyder_common.py next to cyder_create_game_app.py.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

assert_contains \
  "$(cat "$ROOT/scripts/create-cyderbits-app.sh")" \
  'cp "$SCRIPT_DIR/cyder_common.py" "$RES/cyder_common.py"' \
  "create-cyderbits-app.sh should bundle cyder_common.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RES="$TMP/Resources"
mkdir -p "$RES/engine-payload/bin" "$RES/ogom-scripts"
touch "$RES/engine-payload/bin/wine"
cp "$ROOT/scripts/cyder_create_game_app.py" "$RES/"
cp "$ROOT/scripts/cyder_common.py" "$RES/"

output="$(cd "$RES" && python3 cyder_create_game_app.py --help 2>&1)"
assert_contains "$output" "wrap a Windows EXE" "packager module should load"

APP="$ROOT/dist/CyderBits.app/Contents/Resources"
if [[ -f "$APP/cyder_create_game_app.py" ]]; then
  if [[ ! -f "$APP/cyder_common.py" ]]; then
    echo "ASSERT failed: dist CyderBits.app should include cyder_common.py" >&2
    exit 1
  fi
  output="$(cd "$APP" && python3 cyder_create_game_app.py --help 2>&1)"
  assert_contains "$output" "wrap a Windows EXE" "bundled packager should import cyder_common"
fi

echo "PASS test-cyderbits-app"
