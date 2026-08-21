#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- cyder_init_paths uses global downloads, not CYDER_SUPPORT/downloads ---
SUPPORT="$TMP/iso-support"
mkdir -p "$SUPPORT"
# shellcheck source=../scripts/cyder-common.sh
source "$ROOT/scripts/cyder-common.sh"
unset CYDER_DOWNLOADS || true
export CYDER_SUPPORT="$SUPPORT"
cyder_init_paths "$ROOT/scripts"
assert_eq "$CYDER_DOWNLOADS" "$HOME/Library/Application Support/Cyder/downloads" \
  "CYDER_DOWNLOADS must be global Cyder downloads, not bottle support"
[[ "$CYDER_DOWNLOADS" != "$SUPPORT/downloads" ]] || {
  echo "CYDER_DOWNLOADS must not follow isolated CYDER_SUPPORT" >&2
  exit 1
}

# Explicit override still wins.
export CYDER_DOWNLOADS="$TMP/override-downloads"
cyder_init_paths "$ROOT/scripts"
assert_eq "$CYDER_DOWNLOADS" "$TMP/override-downloads" \
  "explicit CYDER_DOWNLOADS override must be preserved"

# --- locked download: parallel waiters share one successful artifact ---
# shellcheck source=../scripts/cyder-download-locked.sh
source "$ROOT/scripts/cyder-download-locked.sh"

PAYLOAD="$TMP/payload.bin"
printf 'cyder-lock-fixture-v1\n' >"$PAYLOAD"
EXPECTED="$(/usr/bin/shasum -a 256 "$PAYLOAD" | awk '{print $1}')"
DEST="$TMP/cache/artifact.bin"
mkdir -p "$TMP/cache" "$TMP/bin"

cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || exit 2
# Simulate slow download so the second waiter hits the lock.
sleep 0.8
cp "$CURL_FIXTURE" "$out"
EOF
chmod +x "$TMP/bin/curl"

export PATH="$TMP/bin:$PATH"
export CURL_FIXTURE="$PAYLOAD"
export CYDER_DOWNLOAD_LOCK_TIMEOUT_SEC=30

rm -f "$DEST"
set +e
(
  cyder_download_locked "$DEST" "https://example.test/artifact.bin" "$EXPECTED"
) >"$TMP/a.log" 2>&1 &
pid_a=$!
(
  cyder_download_locked "$DEST" "https://example.test/artifact.bin" "$EXPECTED"
) >"$TMP/b.log" 2>&1 &
pid_b=$!
wait "$pid_a"
status_a=$?
wait "$pid_b"
status_b=$?
set -e

assert_eq "$status_a" "0" "first parallel download must succeed"
assert_eq "$status_b" "0" "second parallel download must succeed"
actual="$(/usr/bin/shasum -a 256 "$DEST" | awk '{print $1}')"
assert_eq "$actual" "$EXPECTED" "locked download must leave a valid checksummed file"
[[ ! -d "${DEST}.lock" ]] || {
  echo "download lock directory must be released" >&2
  exit 1
}

# Cached hit should not invoke curl (remove curl from PATH).
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
cyder_download_locked "$DEST" "https://example.test/artifact.bin" "$EXPECTED"

# Install scripts source the lock helper.
assert_contains "$(cat "$ROOT/scripts/install-wine-mono.sh")" "cyder-download-locked.sh" \
  "Mono installer must use locked download helper"
assert_contains "$(cat "$ROOT/scripts/install-wine-gecko.sh")" "cyder-download-locked.sh" \
  "Gecko installer must use locked download helper"
assert_contains "$(cat "$ROOT/scripts/create-cyder-app.sh")" "cyder-download-locked.sh" \
  "app pack must ship cyder-download-locked.sh"

echo "PASS test-cyder-download-locked"
