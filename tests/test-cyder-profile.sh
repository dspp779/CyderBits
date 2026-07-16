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
ruby -rjson - "$TMP/layout/bottles/$id/profile.json" <<'RUBY'
path = ARGV.fetch(0)
value = JSON.parse(File.read(path))
value["recipeId"] = ""
File.write(path, JSON.generate(value))
RUBY
if cyder_profile_validate_metadata "$TMP/layout/bottles/$id/profile.json" "$id" 2>/dev/null; then
  echo "empty recipe id unexpectedly validated" >&2
  exit 1
fi
cyder_profile_write_metadata "$TMP/layout/bottles/$id" "$id" "$TMP/source" recommended age-of-empires-ii
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

game_root="$TMP/games"
mkdir -p "$game_root/一號 遊戲" "$game_root/另一個"
printf exe >"$game_root/一號 遊戲/遊戲.exe"
printf exe >"$game_root/另一個/遊戲.exe"
store="$TMP/store"
first_bottle="$(cyder_profile_create "$game_root/一號 遊戲/遊戲.exe" "$TMP/layout/templates/pristine" "$store")"
first_id="$(cyder_profile_id_for_path "$game_root/一號 遊戲/遊戲.exe")"
assert test -d "$first_bottle"
assert test -f "$store/profiles/$first_id/profile.json"
assert test ! -e "$store/bottles/$first_id/profile.json"
assert_contains "$(cyder_profile_resolve "$game_root/一號 遊戲/遊戲.exe" "$store")" "$first_bottle" "resolve uses canonical EXE path"
if cyder_profile_resolve "$game_root/另一個/遊戲.exe" "$store" >/dev/null 2>&1; then
  echo "same basename unexpectedly resolved to another profile" >&2
  exit 1
fi
second_bottle="$(cyder_profile_create "$game_root/另一個/遊戲.exe" "$TMP/layout/templates/pristine" "$store")"
second_id="$(cyder_profile_id_for_path "$game_root/另一個/遊戲.exe")"
if [[ "$first_id" == "$second_id" || "$first_bottle" == "$second_bottle" ]]; then
  echo "same basename profiles unexpectedly share identity" >&2
  exit 1
fi

remove_exe="$game_root/remove-me.exe"
printf exe >"$remove_exe"
remove_bottle="$(cyder_profile_create "$remove_exe" "$TMP/layout/templates/pristine" "$store")"
remove_id="$(cyder_profile_id_for_path "$remove_exe")"
cyder_profile_remove "$remove_exe" "$store"
assert test ! -e "$remove_bottle"
assert test ! -e "$store/profiles/$remove_id"

# Template publication keeps pristine/recommended independent and publishes
# the manifest only after the complete clone is ready.
template_root="$TMP/template-root"
mkdir -p "$TMP/template-source-pristine/drive_c" "$TMP/template-source-recommended/drive_c"
printf pristine >"$TMP/template-source-pristine/system.reg"
printf recommended >"$TMP/template-source-recommended/system.reg"
published="$(CYDER_PROFILE_COPY_MODE=fallback cyder_profile_publish_template "$TMP/template-source-pristine" pristine "$template_root" 7 cx26 age-of-empires-ii)"
assert_eq "$published" "$template_root/templates/pristine" "publish returns pristine destination"
cyder_profile_template_ready pristine "$template_root" 7 cx26
assert_contains "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0)))["engineVersion"]' "$template_root/templates/pristine/manifest.json")" cx26 "template manifest stores engine version"
if CYDER_PROFILE_COPY_MODE=fallback cyder_profile_publish_template "$TMP/missing-template" pristine "$template_root" 8 cx27 >/dev/null 2>&1; then
  echo "missing source unexpectedly published" >&2
  exit 1
fi
cyder_profile_template_ready pristine "$template_root" 7 cx26
if CYDER_PROFILE_COPY_MODE=fallback cyder_profile_publish_template "$TMP/template-source-pristine" pristine "$template_root" 8 cx27 'Bad ID' >/dev/null 2>&1; then
  echo "invalid recipe unexpectedly replaced existing template" >&2
  exit 1
fi
cyder_profile_template_ready pristine "$template_root" 7 cx26
CYDER_PROFILE_COPY_MODE=fallback cyder_profile_publish_template "$TMP/template-source-recommended" recommended "$template_root" 3 cx26 recipe-x >/dev/null
cyder_profile_template_ready recommended "$template_root" 3 cx26
# CLI dispatch exposes the same backend for the app/bootstrap integration.
bash "$ROOT/scripts/cyder-profile.sh" template-ready pristine "$template_root" 7 cx26
if bash "$ROOT/scripts/cyder-profile.sh" template-ready pristine "$template_root" 8 cx26; then
  echo "CLI template-ready ignored a revision mismatch" >&2
  exit 1
fi
if find "$template_root/templates" -maxdepth 1 -type d -name '.cyder-template-*' | grep -q .; then
  echo "recommended publish left staging directories" >&2
  exit 1
fi
# A schema-1 manifest remains valid, but without engineVersion it is not ready
# for a versioned template request.
cyder_profile_write_template_manifest "$template_root/templates/recommended" 1 recipe-x
cyder_profile_validate_template_manifest "$template_root/templates/recommended/manifest.json" recommended
if cyder_profile_template_ready recommended "$template_root" 1 cx26; then
  echo "legacy schema-1 template unexpectedly reported ready" >&2
  exit 1
fi
cat >"$template_root/templates/recommended/manifest.json" <<'JSON'
{"schemaVersion":2,"templateId":"recommended","revision":1,"recipeId":null}
JSON
if cyder_profile_validate_template_manifest "$template_root/templates/recommended/manifest.json" recommended 2>/dev/null; then
  echo "schema-2 manifest without engineVersion unexpectedly validated" >&2
  exit 1
fi
CYDER_PROFILE_COPY_MODE=fallback cyder_profile_publish_template "$TMP/template-source-recommended" recommended "$template_root" 3 cx26 recipe-x >/dev/null
cyder_profile_template_ready recommended "$template_root" 3 cx26

mv "$template_root/templates/recommended" "$template_root/templates/recommended.real"
ln -s "$template_root/templates/recommended.real" "$template_root/templates/recommended"
if cyder_profile_template_ready recommended "$template_root" 3 cx26; then
  echo "symlinked template unexpectedly reported ready" >&2
  exit 1
fi
rm "$template_root/templates/recommended"
mv "$template_root/templates/recommended.real" "$template_root/templates/recommended"
mv "$template_root/templates/recommended/manifest.json" "$template_root/templates/recommended/manifest.real.json"
ln -s "$template_root/templates/recommended/manifest.real.json" "$template_root/templates/recommended/manifest.json"
if cyder_profile_template_ready recommended "$template_root" 3 cx26; then
  echo "symlinked manifest unexpectedly reported ready" >&2
  exit 1
fi
rm "$template_root/templates/recommended/manifest.json"
mv "$template_root/templates/recommended/manifest.real.json" "$template_root/templates/recommended/manifest.json"
mv "$store/profiles/$first_id" "$store/profiles/$first_id.real"
ln -s "$store/profiles/$first_id.real" "$store/profiles/$first_id"
if cyder_profile_resolve "$game_root/一號 遊戲/遊戲.exe" "$store" >/dev/null 2>&1; then
  echo "profile symlink unexpectedly resolved" >&2
  exit 1
fi
rm "$store/profiles/$first_id"
mv "$store/profiles/$first_id.real" "$store/profiles/$first_id"
mv "$store/bottles/$first_id" "$store/bottles/$first_id.real"
ln -s "$store/bottles/$first_id.real" "$store/bottles/$first_id"
if cyder_profile_resolve "$game_root/一號 遊戲/遊戲.exe" "$store" >/dev/null 2>&1; then
  echo "bottle symlink unexpectedly resolved" >&2
  exit 1
fi
rm "$store/bottles/$first_id"
mv "$store/bottles/$first_id.real" "$store/bottles/$first_id"
assert test "$(cyder_profile_create "$game_root/一號 遊戲/遊戲.exe" "$TMP/layout/templates/pristine" "$store")" = "$first_bottle"
if cyder_profile_create "$game_root/一號 遊戲/遊戲.exe" "$TMP/layout/templates/invalid" "$store" >/dev/null 2>&1; then
  echo "invalid template unexpectedly created profile" >&2
  exit 1
fi
assert test ! -e "$store/bottles/profile-invalid"
cyder_recipe_validate "$ROOT/recipes/defaults.json"
cat >"$TMP/invalid-recipe.json" <<'JSON'
[{"id":"Bad ID","revision":0,"displayName":"broken","baseTemplate":"recommended","settings":{},"environment":{},"arguments":[],"components":[]}]
JSON
if cyder_recipe_validate "$TMP/invalid-recipe.json" 2>/dev/null; then
  echo "invalid recipe unexpectedly passed validation" >&2
  exit 1
fi
echo "cyder profile tests: ok"
