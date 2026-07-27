#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
RECIPE="$ROOT/recipes/defaults.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

output="$($ROOT/scripts/cyder-recipe.sh validate "$RECIPE")"
assert_contains "$output" "validated 6 recipe(s)" "defaults should validate offline"
output="$($ROOT/scripts/cyder-recipe.sh plan "$RECIPE" bluecg "$TMP")"
assert_contains "$output" "setting.dpi=192" "plan should expose BlueCG DPI"
assert_contains "$output" "setting.renderer=builtin" "plan should expose BlueCG renderer"

mkdir -p "$TMP/bottle"
output="$($ROOT/scripts/cyder-recipe.sh apply "$RECIPE" bluecg "$TMP/bottle")"
assert_contains "$output" "applied=bluecg@1" "pure settings recipe should apply"
assert test -f "$TMP/bottle/.cyder-recipe-settings.json"
assert test -f "$TMP/bottle/.cyder-recipe-applied.json"
assert_contains "$(cat "$TMP/bottle/.cyder-recipe-applied.json")" '"revision": 1' \
  "revision should be written after apply"

mkdir -p "$TMP/lf2"
if "$ROOT/scripts/cyder-recipe.sh" apply "$RECIPE" lf2 "$TMP/lf2" >/dev/null 2>"$TMP/lf2-error"; then
  echo "ASSERT failed: LF2 components must not claim offline apply" >&2
  exit 1
fi
assert_contains "$(cat "$TMP/lf2-error")" "CYD-REC-003" \
  "missing component failure should be explicit"
[[ ! -e "$TMP/lf2/.cyder-recipe-applied.json" ]] || {
  echo "ASSERT failed: component failure must not update applied revision" >&2
  exit 1
}

mkdir -p "$TMP/richman"
mkdir -p "$TMP/richman-game"
printf 'test executable\n' >"$TMP/richman-game/rich4.exe"
richman_output="$(
  "$ROOT/scripts/cyder-recipe.sh" apply "$RECIPE" richman-4 \
    "$TMP/richman" "$TMP/richman-game/rich4.exe"
)"
assert_contains "$richman_output" "installed=cnc-ddraw@7.1.0.0" \
  "cnc-ddraw recipe should provision the pinned offline payload"
assert_contains "$richman_output" "applied=richman-4@1" \
  "recipe should be marked applied only after provisioning succeeds"
assert test -f "$TMP/richman-game/ddraw.dll"
assert test -f "$TMP/richman-game/ddraw.ini"
assert test -d "$TMP/richman-game/Shaders"

cat >"$TMP/invalid.json" <<'JSON'
[{"id":"bad","revision":0,"displayName":"Bad","baseTemplate":"recommended","settings":{"dpi":999},"environment":{},"arguments":[],"components":[]}]
JSON
if "$ROOT/scripts/cyder-recipe.sh" validate "$TMP/invalid.json" >/dev/null 2>"$TMP/invalid-error"; then
  echo "ASSERT failed: invalid recipe unexpectedly passed validation" >&2
  exit 1
fi
assert_contains "$(cat "$TMP/invalid-error")" "CYD-REC-001" \
  "invalid recipe should have stable error code"

echo "PASS test-cyder-recipe"
