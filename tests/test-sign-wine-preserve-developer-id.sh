#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/root/bin"
touch "$TMP/root/bin/wine" "$TMP/entitlements.plist"

cat > "$TMP/file-stub" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
echo "Mach-O 64-bit executable x86_64"
INNER

cat > "$TMP/codesign-stub" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
echo "codesign $*" >> "$CODESIGN_LOG"
# Display identity / verify paths used by preserve mode.
if [[ "${1:-}" == "-dv" ]]; then
  echo "Authority=Developer ID Application: Test" >&2
  exit 0
fi
if [[ "${1:-}" == "--verify" ]]; then
  exit 0
fi
# Ad-hoc re-sign must not run when preserving Developer ID.
if [[ "${1:-}" == "--force" ]]; then
  identity=""
  prev=""
  for arg in "$@"; do
    if [[ "$prev" == "--sign" ]]; then
      identity="$arg"
      break
    fi
    prev="$arg"
  done
  if [[ "$identity" == "-" ]]; then
    echo "unexpected ad-hoc --sign - while preserving Developer ID: $*" >&2
    exit 99
  fi
fi
exit 0
INNER

cat > "$TMP/xattr-stub" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
echo "xattr $*" >> "$XATTR_LOG"
INNER

chmod +x "$TMP/file-stub" "$TMP/codesign-stub" "$TMP/xattr-stub"
: > "$TMP/codesign.log"
: > "$TMP/xattr.log"

output="$(
  FILE_CMD="$TMP/file-stub" \
  CODESIGN_CMD="$TMP/codesign-stub" \
  XATTR_CMD="$TMP/xattr-stub" \
  CODESIGN_LOG="$TMP/codesign.log" \
  XATTR_LOG="$TMP/xattr.log" \
  SIGN_IDENTITY=- \
  bash "$ROOT/scripts/sign-wine.sh" --root "$TMP/root" --entitlements "$TMP/entitlements.plist" 2>&1
)"

assert_contains "$output" "Preserving Developer ID signatures" "adhoc mode should preserve Developer ID"
if grep -E -- '--sign[[:space:]]+-' "$TMP/codesign.log" >/dev/null 2>&1; then
  echo "adhoc preserve mode must not invoke codesign --sign -" >&2
  cat "$TMP/codesign.log" >&2
  exit 1
fi
if ! grep -q -- '--verify' "$TMP/codesign.log"; then
  echo "preserve mode should still verify signatures" >&2
  cat "$TMP/codesign.log" >&2
  exit 1
fi
if ! grep -q 'xattr -c' "$TMP/xattr.log"; then
  echo "preserve mode should still clear quarantine xattrs" >&2
  cat "$TMP/xattr.log" >&2
  exit 1
fi

echo "PASS test-sign-wine-preserve-developer-id"
