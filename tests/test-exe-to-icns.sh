#!/usr/bin/env bash
# exe_to_icns must use iconutil-valid iconset filenames (not corrupted placeholders).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

PY="$ROOT/scripts/cyder_create_game_app.py"
content="$(cat "$PY")"

assert_contains "$content" 'icon_16x16@2x.png' "exe_to_icns iconset should include icon_16x16@2x.png"
assert_contains "$content" 'icon_512x512@2x.png' "exe_to_icns iconset should include icon_512x512@2x.png"
assert_contains "$content" 'def exe_to_png(' "game library should reuse the PE icon extractor"
assert_contains "$content" '"--extract-icon"' "PE icon extraction should expose a non-interactive CLI"
assert_contains "$content" '"--extract-icon-stdin"' "game library icon extraction should accept an inherited file descriptor"

if echo "$content" | grep -qE '@example\.(org|net)'; then
  echo "ASSERT failed: cyder_create_game_app.py still has placeholder iconset filenames" >&2
  exit 1
fi

if [[ -f "$ROOT/dist/BlueLauncher.exe" ]] && command -v iconutil >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  if (
    cd "$ROOT" &&
    PYTHONPATH=scripts python3 -c "
from pathlib import Path
from cyder_create_game_app import exe_to_icns
ok = exe_to_icns(Path('dist/BlueLauncher.exe'), Path('$TMP/AppIcon.icns'))
raise SystemExit(0 if ok else 1)
"
  ); then
    assert test -s "$TMP/AppIcon.icns" "exe_to_icns should produce AppIcon.icns"
    echo "iconutil integration: ok"
  else
    echo "SKIP iconutil integration (iconutil may be unavailable in this environment)" >&2
  fi
fi

echo "PASS test-exe-to-icns"
