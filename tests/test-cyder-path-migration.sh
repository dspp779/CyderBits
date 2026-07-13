#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
source "$ROOT/scripts/cyder-common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export CYDER_SUPPORT="$HOME/Library/Application Support/Cyder"
export CYDER_RUNTIME_ROOT="$HOME/.cyder/runtime"
export CYDER_SCRIPTS="$TMP/empty-scripts"
mkdir -p "$CYDER_SCRIPTS"
cyder_init_paths "$ROOT/scripts"

legacy_engine="$CYDER_LEGACY_ENGINES/$CYDER_ENGINE_NAME"
mkdir -p "$legacy_engine/bin" "$CYDER_LEGACY_SHARED_PREFIX/drive_c"
printf '%s\n' 'CX26.2.0-W11-Cyder003' >"$legacy_engine/version"
printf '%s\n' 'legacy-prefix' >"$CYDER_LEGACY_SHARED_PREFIX/user.reg"

archive_root="$TMP/archive/wine-x86_64"
mkdir -p "$archive_root/bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$archive_root/bin/wine"
chmod +x "$archive_root/bin/wine"
printf '%s\n' 'CX26.2.0-W11-Cyder003' >"$archive_root/version"
engine_archive="$TMP/engine-wine-x86_64-CX26.2.0-W11-Cyder003.tar.xz"
(
  cd "$TMP/archive"
  tar -cf - wine-x86_64 | xz -c >"$engine_archive"
)

dest="$(cyder_ensure_shared_engine "$engine_archive")"

assert test ! -e "$legacy_engine"
assert test -x "$dest/bin/wine"
assert test -f "$CYDER_SHARED_PREFIX/user.reg"
assert_contains "$(cat "$CYDER_SHARED_PREFIX/user.reg")" "legacy-prefix" \
  "same-version engine relocation should preserve the migrated bottle"
if [[ "$CYDER_ENGINES" == *[[:space:]]* ]]; then
  echo "ASSERT failed: new engine path must not contain whitespace" >&2
  exit 1
fi

safe_engines="$CYDER_ENGINES"
CYDER_ENGINES="$TMP/path with space/Engines"
set +e
cyder_validate_runtime_path >/dev/null 2>&1
unsafe_status=$?
set -e
CYDER_ENGINES="$safe_engines"
assert_eq "$unsafe_status" "1" "runtime path validation should reject whitespace"

echo "PASS test-cyder-path-migration"
