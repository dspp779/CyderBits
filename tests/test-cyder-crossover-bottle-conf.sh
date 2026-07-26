#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
# shellcheck source=../scripts/cyder-common.sh
source "$ROOT/scripts/cyder-common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ENGINE="$TMP/engine"
mkdir -p "$ENGINE/bin" "$ENGINE/share/crossover/bottle_data"
: >"$ENGINE/bin/wine"
cat >"$ENGINE/share/crossover/bottle_data/cxbottle.conf" <<'EOF'
;; template
[Bottle]
;;"Template" = ""

[EnvironmentVariables]
;;"PROMPT" = "$p$g"
EOF

BOTTLE="$TMP/bottle"
cyder_seed_crossover_bottle_conf "$ENGINE/bin/wine" "$BOTTLE"
assert test -r "$BOTTLE/cxbottle.conf"
conf="$(cat "$BOTTLE/cxbottle.conf")"
assert_contains "$conf" '"WineArch" = "win64"' "WineArch should be injected"
assert_contains "$conf" '"Template" = "win10_64"' "Template should be injected"
if [[ "$conf" == *'"RAW_AUDIO_PARSE" = "1"'* ]]; then
  echo "ASSERT failed: generic CrossOver seed must not inject RAW_AUDIO_PARSE" >&2
  exit 1
fi

# MapleStory OEM bottles receive the audio parser and CP950-compatible locale.
OEM_BOTTLE="$TMP/oem-bottle"
CYDER_OEM_FLAVOR=maplestory cyder_seed_crossover_bottle_conf "$ENGINE/bin/wine" "$OEM_BOTTLE"
oem_conf="$(cat "$OEM_BOTTLE/cxbottle.conf")"
assert_contains "$oem_conf" '"RAW_AUDIO_PARSE" = "1"' \
  "OEM seed should inject RAW_AUDIO_PARSE"
assert_contains "$oem_conf" '"LANG" = "zh_TW.UTF-8"' \
  "OEM seed should set LANG"
assert_contains "$oem_conf" '"LC_ALL" = "zh_TW.UTF-8"' \
  "OEM seed should set LC_ALL"
assert_contains "$oem_conf" '"LC_CTYPE" = "zh_TW.UTF-8"' \
  "OEM seed should set LC_CTYPE"

# Existing conf is left alone.
printf 'keep-me\n' >"$BOTTLE/cxbottle.conf"
cyder_seed_crossover_bottle_conf "$ENGINE/bin/wine" "$BOTTLE"
assert_eq "$(cat "$BOTTLE/cxbottle.conf")" "keep-me" \
  "existing cxbottle.conf must not be overwritten"

# Repair: bottle with system.reg but no conf still gets seeded.
REPAIR="$TMP/repair-bottle"
mkdir -p "$REPAIR"
: >"$REPAIR/system.reg"
cyder_seed_crossover_bottle_conf "$ENGINE/bin/wine" "$REPAIR"
assert test -r "$REPAIR/cxbottle.conf"
if [[ "$(cat "$REPAIR/cxbottle.conf")" == *'"RAW_AUDIO_PARSE" = "1"'* ]]; then
  echo "ASSERT failed: generic repair seed must not inject RAW_AUDIO_PARSE" >&2
  exit 1
fi

# Retail engines without bottle_data are a no-op.
RETAIL="$TMP/retail"
mkdir -p "$RETAIL/bin" "$TMP/retail-bottle"
: >"$RETAIL/bin/wine"
cyder_seed_crossover_bottle_conf "$RETAIL/bin/wine" "$TMP/retail-bottle"
assert test ! -e "$TMP/retail-bottle/cxbottle.conf"

# Frontend flags belong only to the CrossOver Perl launcher or an explicit
# OEM override. Do not infer them from a retail Wine --help response.
cat >"$RETAIL/bin/wine" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then
  echo "supports --wait-children"
fi
SH
chmod +x "$RETAIL/bin/wine"
unset CYDER_WINE_FRONTEND_ARGS
assert_eq "$(cyder_wine_frontend_args "$RETAIL/bin/wine")" "" \
  "retail Wine must not receive CrossOver frontend flags"

# Engine / bottle name overrides stay under the shared roots.
(
  export CYDER_ENGINE_NAME=maplestory-oem25
  export CYDER_BOTTLE_NAME=maplestory-oem25
  unset CYDER_PREFIX CYDER_SHARED_PREFIX
  # shellcheck source=../scripts/cyder-common.sh
  source "$ROOT/scripts/cyder-common.sh"
  cyder_init_paths "$ROOT/scripts"
  assert_eq "$CYDER_ENGINE_NAME" "maplestory-oem25" "engine name override"
  assert_eq "$CYDER_PREFIX" \
    "$HOME/Library/Application Support/Cyder/bottles/maplestory-oem25" \
    "prefix path uses CYDER_BOTTLE_NAME"
  assert_eq "$CYDER_SHARED_PREFIX" \
    "$HOME/Library/Application Support/Cyder/bottles/maplestory-oem25" \
    "shared prefix remains a compatibility alias"
)

echo "PASS test-cyder-crossover-bottle-conf"
