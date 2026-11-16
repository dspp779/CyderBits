#!/usr/bin/env bash
# maplestory-launch.sh starts MapleStory with Wine directly for testing. The
# account ID and one-time password reach the game's argv only: never the
# terminal, the log or a dry-run line. It prints the window to control.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
SCRIPT="$ROOT/.agents/skills/wine-game-compat-testing/scripts/maplestory-launch.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/game" "$TMP/engine/bin" "$TMP/prefix"
: >"$TMP/game/MapleStory.exe"
cat >"$TMP/engine/bin/wine" <<EOF
#!/bin/bash
{ echo "cwd=\$PWD"; echo "args=\$*"; env | grep -E '^(WINEPREFIX|WINEDEBUG|CYDER_|CX_|MS_)' | sort; } >"$TMP/wine.part"
mv "$TMP/wine.part" "$TMP/wine.called"
echo "cyder: graphics backend=\${CYDER_GRAPHICS_BACKEND:-none}"
EOF
chmod +x "$TMP/engine/bin/wine"
cat >"$TMP/windows" <<'EOF'
#!/bin/bash
cat <<'JSON'
{"windows": [
 {"pid": 41, "window_id": 7, "title": "", "layer": 0, "bounds": {"Width": 300, "Height": 200}},
 {"pid": 42, "window_id": 9, "title": "MapleStory", "layer": 0, "bounds": {"Width": 1366, "Height": 788}}]}
JSON
EOF
chmod +x "$TMP/windows"
run() { MS_ACCOUNT_ID=T9abc123 MS_OTP=SECRETOTP CYDER_WINE_WINDOWS_CMD="$TMP/windows" TMPDIR="$TMP" \
  bash "$SCRIPT" --game-dir "$TMP/game" --engine "$TMP/engine" --prefix "$TMP/prefix" --wait 5 "$@"; }

dry="$(run --dry-run --backend dxmt)"
assert_contains "$dry" "<MS_ACCOUNT_ID> <MS_OTP>" "dry run masks the secrets"
assert_not_contains "$dry" "SECRETOTP" "dry run never prints the OTP"
assert_not_contains "$dry" "T9abc123" "dry run never prints the account ID"
assert_contains "$dry" "CX_GRAPHICS_BACKEND=dxmt" "the backend is set for Wine and Cyder's engine"
[[ ! -e "$TMP/wine.called" ]] || { echo "FAIL dry run started Wine" >&2; exit 1; }

out="$(run --backend dxvk --log "$TMP/game.log")"
for _ in $(seq 50); do [[ -s "$TMP/wine.called" ]] && break; sleep 0.1; done
assert_contains "$out" "pid=42 window_id=9 title=MapleStory size=1366x788" "the titled game window is chosen"
assert_not_contains "$out" "SECRETOTP" "output never shows the OTP"
called="$(cat "$TMP/wine.called")"
assert_contains "$called" "args=MapleStory.exe tw.login.maplestory.beanfun.com 8484 BeanFun T9abc123 SECRETOTP" \
  "the game gets the Beanfun argv"
assert_contains "$called" "cwd=$TMP/game" "the game starts in its own folder"
assert_contains "$called" "CYDER_MAPLESTORY_FILE_CACHE=1" "the WZ cache matches a Cyder launch"
assert_contains "$called" "CYDER_MAPLESTORY_READAHEAD=1" "the WZ read-ahead matches a Cyder launch"
assert_not_contains "$called" "MS_OTP" "the secrets are not left in Wine's environment"
assert_not_contains "$(cat "$TMP/game.log")" "SECRETOTP" "the log never holds the OTP"
[[ -s "$TMP/game.log.mono" ]] || { echo "FAIL no clock offset file" >&2; exit 1; }

if MS_ACCOUNT_ID=PlayerName MS_OTP=x bash "$SCRIPT" --game-dir "$TMP/game" --engine "$TMP/engine" \
     --prefix "$TMP/prefix" --dry-run 2>"$TMP/err"; then echo "FAIL display name accepted" >&2; exit 1; fi
assert_contains "$(cat "$TMP/err")" "ServiceAccountID" "a display name is refused before an OTP is spent"
if bash "$SCRIPT" --game-dir "$TMP/game" --engine "$TMP/engine" --prefix "$TMP/prefix" --dry-run 2>/dev/null; then
  echo "FAIL missing secrets accepted" >&2; exit 1; fi
echo "PASS maplestory-launch keeps the OTP out of output and logs and finds the game window"
