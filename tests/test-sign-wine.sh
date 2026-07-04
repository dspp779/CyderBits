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
  */wine|*/wineserver) echo "Mach-O 64-bit executable x86_64" ;;
  *) echo "ASCII text" ;;
esac
INNER

cat > "$TMP/codesign-stub" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
echo "codesign $*" >> "$CODESIGN_LOG"
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

echo "PASS test-sign-wine"
