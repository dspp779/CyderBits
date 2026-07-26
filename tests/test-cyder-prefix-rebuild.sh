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

# These stubs exercise the delete-then-provision lifecycle without requiring a Wine
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

# A successful rebuild provisions directly into the active prefix.
cyder_rebuild_shared_prefix /tmp/fake-wine /tmp/fake-engine
assert_eq "$CYDER_REBUILD_PROVISION_CALLS" "1" \
  "successful rebuild should provision once into the active prefix"
assert_contains "$(cat "$CYDER_SHARED_PREFIX/system.reg")" "new-prefix" \
  "successful rebuild should publish the provisioned baseline"
assert test -f "$CYDER_BOOTSTRAP_MARKER"
if find "$TMP" -type d \( -path '*/backups/*' -o -name '.rebuild-previous-*' \) -print -quit | grep -q .; then
  echo "ASSERT failed: rebuild should not create previous-bottle staging" >&2
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
if [[ -e "$CYDER_SHARED_PREFIX" ]]; then
  echo "ASSERT failed: provision failure after delete must leave no bottle" >&2
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

# Full rebuild must delete stale files before provisioning the same path.
unset CYDER_REBUILD_TEST_PROVISION_FAIL
mkdir -p "$CYDER_SHARED_PREFIX/drive_c"
printf 'old-prefix\n' >"$CYDER_SHARED_PREFIX/system.reg"
: >"$CYDER_SHARED_PREFIX/user.reg"
printf 'stale-conf\n' >"$CYDER_SHARED_PREFIX/cxbottle.conf"
CYDER_REBUILD_PROVISION_CALLS=0
cyder_rebuild_shared_prefix /tmp/fake-wine /tmp/fake-engine
assert_contains "$(cat "$CYDER_SHARED_PREFIX/system.reg")" "new-prefix" \
  "rebuild should provision a brand-new bottle"
if [[ -e "$CYDER_SHARED_PREFIX/cxbottle.conf" ]]; then
  echo "ASSERT failed: full rebuild must drop files from the previous bottle" >&2
  exit 1
fi

echo "PASS test-cyder-prefix-rebuild"
