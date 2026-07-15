#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/assert.sh"
source "$ROOT/scripts/cyder-profile.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/source/drive_c"
printf 'fixture\n' >"$TMP/source/system.reg"
id="$(cyder_profile_id_for_path "$TMP/source")"
assert_contains "$id" "profile-" "profile id has stable prefix"
cyder_profile_init_layout "$TMP/layout"
assert test -d "$TMP/layout/templates/pristine"
CYDER_PROFILE_COPY_MODE=fallback cyder_profile_clone_bottle "$TMP/source" "$TMP/layout/bottles/$id"
assert test -f "$TMP/layout/bottles/$id/system.reg"
if cyder_profile_clone_bottle "$TMP/source" "$TMP/layout/bottles/$id" 2>/dev/null; then
  echo "clone unexpectedly overwrote destination" >&2
  exit 1
fi
cyder_recipe_validate "$ROOT/recipes/defaults.json"
echo "cyder profile tests: ok"
