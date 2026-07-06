#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
# shellcheck source=../scripts/cyder-common.sh
source "$ROOT/scripts/cyder-common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
APP_RES="$TMP/Resources"
mkdir -p "$APP_RES/addons/libarchive/bin"
touch "$APP_RES/addons/libarchive/bin/bsdtar.exe"

CYDER_OGOM="$APP_RES"
out="$(cyder_resolve_libarchive_src)"
assert_contains "$out" "addons/libarchive" "app bundle should resolve addons/libarchive"

echo "PASS test-cyder-libarchive-src"
