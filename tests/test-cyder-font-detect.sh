#!/usr/bin/env bash
# Default MingLiU target detection: one find per font folder, not a fork per file.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
source "$ROOT/scripts/cyder-common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
command() { [[ "$1 $2" == "-v fc-list" ]] && return 1; builtin command "$@"; }
host="$(HOME="$TMP/empty" cyder_detect_default_font_preset)"
mkdir -p "$TMP/a/Library/Fonts/Microsoft" "$TMP/b/Library/Fonts" "$TMP/c/Library/Fonts"
touch "$TMP/a/Library/Fonts/Microsoft/PMINGLIU.TTF" "$TMP/b/Library/Fonts/新細明體.ttc" "$TMP/c/Library/Fonts/Other.ttf"
assert_eq "$(HOME="$TMP/a" cyder_detect_default_font_preset)" mingliu "case-insensitive MingLiU in a subfolder"
assert_eq "$(HOME="$TMP/b" cyder_detect_default_font_preset)" mingliu "Chinese 新細明體 file name"
assert_eq "$(HOME="$TMP/c" cyder_detect_default_font_preset)" "$host" "unrelated fonts fall back to the host result"
for i in $(seq 1 600); do : >"$TMP/c/Library/Fonts/font-$i.ttf"; done
start=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time')
HOME="$TMP/c" cyder_detect_default_font_preset >/dev/null
elapsed=$(/usr/bin/perl -MTime::HiRes=time -e "printf '%.3f', time - $start")
/usr/bin/perl -e "exit($elapsed < 0.3 ? 0 : 1)" || { echo "ASSERT failed: detection took ${elapsed}s for 600 fonts" >&2; exit 1; }
echo "PASS test-cyder-font-detect (${elapsed}s for 600 extra fonts)"
