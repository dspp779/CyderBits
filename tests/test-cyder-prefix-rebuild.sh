#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
# shellcheck source=../scripts/cyder-common.sh
source "$ROOT/scripts/cyder-common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CYDER_SUPPORT="$TMP/support"
CYDER_SHARED_PREFIX="$TMP/bottles/shared"
CYDER_TEMPLATE_REVISION=2
CYDER_BOOTSTRAP_MARKER="$CYDER_SHARED_PREFIX/.cyder-bootstrap-v1"
mkdir -p "$CYDER_SUPPORT" "$CYDER_SHARED_PREFIX"
export CYDER_SUPPORT CYDER_SHARED_PREFIX CYDER_TEMPLATE_REVISION CYDER_BOOTSTRAP_MARKER

# These stubs exercise the lifecycle transaction without requiring a Wine
# engine or downloading bootstrap components.
cyder_has_running_prefix() { return 1; }
CYDER_REBUILD_PROVISION_CALLS=0
cyder_provision_prefix_baseline() {
  local wine_bin="$1" engine_root="$2" prefix="$3"
  CYDER_REBUILD_PROVISION_CALLS=$((CYDER_REBUILD_PROVISION_CALLS + 1))
  [[ "${CYDER_REBUILD_TEST_PROVISION_FAIL:-0}" != 1 ]] || return 1
  mkdir -p "$prefix/drive_c/windows/system32"
  printf 'new-prefix\n' >"$prefix/system.reg"
  : >"$prefix/user.reg"
  : >"$prefix/drive_c/windows/system32/kernel32.dll"
  : >"$prefix/.cyder-golden-baseline-v2"
  [[ "${CYDER_REBUILD_TEST_HEALTH_FAIL:-0}" != 1 ]] || return 1
  CYDER_BOOTSTRAP_HEALTH_CHECKED=1
}

# A successful rebuild keeps no full copy of the previous shared bottle.
cyder_rebuild_shared_prefix /tmp/fake-wine /tmp/fake-engine
assert_eq "$CYDER_REBUILD_PROVISION_CALLS" "1" \
  "successful rebuild should provision once into staging"
assert_contains "$(cat "$CYDER_SHARED_PREFIX/system.reg")" "new-prefix" \
  "successful rebuild should publish the provisioned baseline"
assert test -f "$CYDER_BOOTSTRAP_MARKER"
if find "$TMP" -type d \( -path '*/backups/*' -o -name '.rebuild-previous-*' \) -print -quit | grep -q .; then
  echo "ASSERT failed: successful rebuild should not retain the previous bottle" >&2
  exit 1
fi

printf 'old-prefix\n' >"$CYDER_SHARED_PREFIX/system.reg"

CYDER_REBUILD_TEST_HEALTH_FAIL=1
export CYDER_REBUILD_TEST_HEALTH_FAIL
CYDER_REBUILD_PROVISION_CALLS=0
if cyder_rebuild_shared_prefix /tmp/fake-wine /tmp/fake-engine; then
  echo "ASSERT failed: provision health failure should fail rebuild" >&2
  exit 1
fi
assert_contains "$(cat "$CYDER_SHARED_PREFIX/system.reg")" "old-prefix" \
  "provision failure should leave the previous prefix untouched"
if find "$TMP/bottles" -maxdepth 1 -name '.rebuild-*' -print -quit | grep -q .; then
  echo "ASSERT failed: failed provision should not leave staging behind" >&2
  exit 1
fi

rm -rf "$CYDER_SHARED_PREFIX"
unset CYDER_REBUILD_TEST_HEALTH_FAIL
CYDER_REBUILD_TEST_PROVISION_FAIL=1
export CYDER_REBUILD_TEST_PROVISION_FAIL
CYDER_REBUILD_PROVISION_CALLS=0
if cyder_rebuild_shared_prefix /tmp/fake-wine /tmp/fake-engine; then
  echo "ASSERT failed: provision failure should fail rebuild" >&2
  exit 1
fi
[[ ! -e "$CYDER_SHARED_PREFIX" ]] || {
  echo "ASSERT failed: failed first prefix should not be published" >&2
  exit 1
}

echo "PASS test-cyder-prefix-rebuild"
