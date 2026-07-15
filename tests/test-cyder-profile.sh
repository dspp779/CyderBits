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
mkdir -p "$TMP/other/source"
other_id="$(cyder_profile_id_for_path "$TMP/other/source")"
if [[ "$id" == "$other_id" ]]; then
  echo "different paths unexpectedly share profile identity" >&2
  exit 1
fi
cyder_profile_init_layout "$TMP/layout"
assert test -d "$TMP/layout/templates/pristine"
cyder_profile_write_template_manifest "$TMP/layout/templates/pristine" 3 age-of-empires-ii
cyder_profile_validate_template_manifest "$TMP/layout/templates/pristine/manifest.json" pristine
if cyder_profile_write_template_manifest "$TMP/layout/templates/pristine" 3 'Bad ID' 2>/dev/null; then
  echo "invalid manifest recipe id unexpectedly accepted" >&2
  exit 1
fi
CYDER_PROFILE_COPY_MODE=fallback cyder_profile_clone_bottle "$TMP/source" "$TMP/layout/bottles/$id"
assert test -f "$TMP/layout/bottles/$id/system.reg"
cyder_profile_write_metadata "$TMP/layout/bottles/$id" "$id" "$TMP/source" recommended age-of-empires-ii
cyder_profile_validate_metadata "$TMP/layout/bottles/$id/profile.json" "$id"
assert_contains "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0)))["sourcePath"]' "$TMP/layout/bottles/$id/profile.json")" "$TMP/source" "metadata stores canonical source"
if cyder_profile_clone_bottle "$TMP/source" "$TMP/layout/bottles/$id" 2>/dev/null; then
  echo "clone unexpectedly overwrote destination" >&2
  exit 1
fi
mkdir -p "$TMP/layout/bottles/.cyder-clone-second-leftover"
printf stale >"$TMP/layout/bottles/.cyder-clone-second-leftover/partial"
mkdir -p "$TMP/layout/bottles/.cyder-clone-other-foreign"
printf keep >"$TMP/layout/bottles/.cyder-clone-other-foreign/partial"
CYDER_PROFILE_COPY_MODE=fallback cyder_profile_clone_bottle "$TMP/source" "$TMP/layout/bottles/second"
if [[ -e "$TMP/layout/bottles/.cyder-clone-second-leftover" ]]; then
  echo "stale clone staging was not cleaned" >&2
  exit 1
fi
assert test -d "$TMP/layout/bottles/.cyder-clone-other-foreign"
CYDER_PROFILE_COPY_MODE=fallback cyder_profile_clone_bottle "$TMP/source" "$TMP/new-parent/nested/third"
assert test -f "$TMP/new-parent/nested/third/system.reg"
if cyder_profile_clone_bottle "$TMP/source" "$TMP/layout/bottles/bad*name" 2>/dev/null; then
  echo "unsafe clone destination name unexpectedly accepted" >&2
  exit 1
fi
mkdir -p "$TMP/layout/bottles/.cyder-clone-third.lock"
printf '%s\n' "$$" >"$TMP/layout/bottles/.cyder-clone-third.lock/pid"
mkdir -p "$TMP/layout/bottles/.cyder-clone-third-foreign"
if cyder_profile_clone_bottle "$TMP/source" "$TMP/layout/bottles/third" 2>/dev/null; then
  echo "active clone lock was unexpectedly ignored" >&2
  exit 1
fi
assert test -d "$TMP/layout/bottles/.cyder-clone-third-foreign"
rm -rf "$TMP/layout/bottles/.cyder-clone-third.lock" "$TMP/layout/bottles/.cyder-clone-third-foreign"
legacy_root="$TMP/legacy-root"
cyder_profile_import_legacy_bottle "$TMP/source" "$legacy_root" >/dev/null
legacy_id="$(cyder_profile_id_for_path "$TMP/source")"
cyder_profile_validate_metadata "$legacy_root/profiles/$legacy_id/profile.json" "$legacy_id"
assert test -f "$TMP/source/system.reg"
assert_contains "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0)))["legacy"]' "$legacy_root/profiles/$legacy_id/profile.json")" true "legacy metadata flag"
cyder_recipe_validate "$ROOT/recipes/defaults.json"
cat >"$TMP/invalid-recipe.json" <<'JSON'
[{"id":"Bad ID","revision":0,"displayName":"broken","baseTemplate":"recommended","settings":{},"environment":{},"arguments":[],"components":[]}]
JSON
if cyder_recipe_validate "$TMP/invalid-recipe.json" 2>/dev/null; then
  echo "invalid recipe unexpectedly passed validation" >&2
  exit 1
fi
echo "cyder profile tests: ok"
