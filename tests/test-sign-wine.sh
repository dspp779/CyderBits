#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/root/bin" "$TMP/root/share"
touch "$TMP/root/bin/wine" "$TMP/root/bin/wineserver" "$TMP/root/share/readme.txt"

cat > "$TMP/file-stub" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
path="${@: -1}"
case "$path" in
  */root-script/bin/wine) echo "Perl script text executable" ;;
  */root-script/bin/wineloader) echo "Mach-O 64-bit executable x86_64" ;;
  */wine|*/wineserver) echo "Mach-O 64-bit executable x86_64" ;;
  *) echo "ASCII text" ;;
esac
INNER

cat > "$TMP/codesign-stub" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
echo "codesign $*" >> "$CODESIGN_LOG"
if [[ "${1:-}" == "--verify" ]]; then
  exit 0
fi
INNER

cat > "$TMP/xattr-stub" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
echo "xattr $*" >> "$XATTR_LOG"
INNER

chmod +x "$TMP/file-stub" "$TMP/codesign-stub" "$TMP/xattr-stub"
touch "$TMP/entitlements.plist"

output="$(
  FILE_CMD="$TMP/file-stub" \
  CODESIGN_CMD="$TMP/codesign-stub" \
  XATTR_CMD="$TMP/xattr-stub" \
  CODESIGN_LOG="$TMP/codesign.log" \
  XATTR_LOG="$TMP/xattr.log" \
  bash "$ROOT/scripts/sign-wine.sh" --root "$TMP/root" --entitlements "$TMP/entitlements.plist" --dry-run 2>&1 || true
)"

assert_contains "$output" "bin/wine" "dry-run should include wineloader"
assert_contains "$output" "bin/wineserver" "dry-run should include wineserver"

if [[ "$output" == *"codesign"*"readme.txt"* ]] || [[ "$output" == *"--options runtime"*"readme.txt"* ]]; then
  echo "non-Mach-O file should not be selected for signing" >&2
  exit 1
fi

# Symlinks to brew dylibs must not be xattr'd via -cr (permission errors).
if [[ "$output" == *"xattr -cr"* ]]; then
  echo "sign-wine must not use xattr -cr (follows symlinks into Homebrew)" >&2
  exit 1
fi

mkdir -p "$TMP/root-script/bin"
touch "$TMP/root-script/bin/wine" "$TMP/root-script/bin/wineloader"
script_output="$({
  FILE_CMD="$TMP/file-stub" \
  CODESIGN_CMD="$TMP/codesign-stub" \
  XATTR_CMD="$TMP/xattr-stub" \
  CODESIGN_LOG="$TMP/codesign.log" \
  XATTR_LOG="$TMP/xattr.log" \
  bash "$ROOT/scripts/sign-wine.sh" --root "$TMP/root-script" --entitlements "$TMP/entitlements.plist" --dry-run
} 2>&1)"
assert_contains "$script_output" "bin/wineloader" "script-based CrossOver wine should verify its native wineloader"

# A transient invalid signature must be retried once and verified again.
mkdir -p "$TMP/root-retry/bin"
touch "$TMP/root-retry/bin/wine" "$TMP/root-retry/bin/wineserver"
cat > "$TMP/codesign-retry-stub" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
echo "codesign $*" >> "$CODESIGN_LOG"
if [[ "${1:-}" == "--verify" && "${@: -1}" == */bin/wineserver ]]; then
  count_file="$CODESIGN_RETRY_COUNT"
  count="$(cat "$count_file")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$count_file"
  [[ "$count" -gt 1 ]]
fi
INNER
chmod +x "$TMP/codesign-retry-stub"
printf '0\n' >"$TMP/retry-count"
: >"$TMP/retry-codesign.log"
retry_output="$(
  FILE_CMD="$TMP/file-stub" \
  CODESIGN_CMD="$TMP/codesign-retry-stub" \
  XATTR_CMD="$TMP/xattr-stub" \
  CODESIGN_LOG="$TMP/retry-codesign.log" \
  CODESIGN_RETRY_COUNT="$TMP/retry-count" \
  XATTR_LOG="$TMP/xattr.log" \
  bash "$ROOT/scripts/sign-wine.sh" --root "$TMP/root-retry" --entitlements "$TMP/entitlements.plist" 2>&1
)"
assert_contains "$retry_output" "Retrying invalid signature" \
  "an invalid Mach-O signature should be retried"
retry_sign_count="$(grep -c -- '--force --sign' "$TMP/retry-codesign.log")"
assert_eq "$retry_sign_count" "3" "two initial signs plus one retry should run"
assert_eq "$(cat "$TMP/retry-count")" "2" "retried file should be strictly verified twice"

echo "PASS test-sign-wine"
