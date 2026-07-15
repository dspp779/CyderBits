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
cyder_profile_write_metadata "$TMP/layout/bottles/$id" "$id" "$TMP/source" recommended age-of-empires-ii
cyder_profile_validate_metadata "$TMP/layout/bottles/$id/profile.json" "$id"
assert_contains "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0)))["sourcePath"]' "$TMP/layout/bottles/$id/profile.json")" "$TMP/source" "metadata stores canonical source"
if cyder_profile_clone_bottle "$TMP/source" "$TMP/layout/bottles/$id" 2>/dev/null; then
  echo "clone unexpectedly overwrote destination" >&2
  exit 1
fi
cyder_recipe_validate "$ROOT/recipes/defaults.json"
cat >"$TMP/invalid-recipe.json" <<'JSON'
[{"id":"Bad ID","revision":0,"displayName":"broken","baseTemplate":"recommended","settings":{},"environment":{},"arguments":[],"components":[]}]
JSON
if cyder_recipe_validate "$TMP/invalid-recipe.json" 2>/dev/null; then
  echo "invalid recipe unexpectedly passed validation" >&2
  exit 1
fi
echo "cyder profile tests: ok"
