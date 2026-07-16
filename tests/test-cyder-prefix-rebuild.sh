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
mkdir -p "$CYDER_SUPPORT" "$CYDER_SHARED_PREFIX"
export CYDER_SUPPORT CYDER_SHARED_PREFIX

# These stubs exercise the lifecycle transaction without requiring a Wine
# engine or downloading bootstrap components.
cyder_has_running_prefix() { return 1; }
cyder_prepare_pristine_template() { :; }
cyder_prepare_golden_template() {
  mkdir -p "$CYDER_SUPPORT/templates/golden"
  printf 'new-prefix\n' >"$CYDER_SUPPORT/templates/golden/system.reg"
}
cyder_profile_backend_load() { :; }
cyder_profile_clone_bottle() {
  [[ "${CYDER_REBUILD_TEST_CLONE_FAIL:-0}" != 1 ]] || return 1
  mkdir -p "$2"
  cp -R "$1"/. "$2"/
}
cyder_health_check_prefix() {
  [[ "${CYDER_REBUILD_TEST_HEALTH_FAIL:-0}" != 1 ]]
}

printf 'old-prefix\n' >"$CYDER_SHARED_PREFIX/system.reg"
CYDER_REBUILD_TEST_HEALTH_FAIL=1
export CYDER_REBUILD_TEST_HEALTH_FAIL
if cyder_rebuild_shared_prefix /tmp/fake-wine /tmp/fake-engine; then
  echo "ASSERT failed: health-check failure should fail rebuild" >&2
  exit 1
fi
assert_contains "$(cat "$CYDER_SHARED_PREFIX/system.reg")" "old-prefix" \
  "health-check failure should restore previous prefix"
[[ ! -f "$CYDER_SHARED_PREFIX/.new-prefix" ]] || {
  echo "ASSERT failed: failed replacement must not remain active" >&2
  exit 1
}
if find "$TMP/bottles" -maxdepth 1 -name '.rebuild-*' -print -quit | grep -q .; then
  echo "ASSERT failed: failed replacement should not leave staging after publish" >&2
  exit 1
fi
if find "$CYDER_SUPPORT/backups" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
  echo "ASSERT failed: rollback should move backup back into place" >&2
  exit 1
fi

rm -rf "$CYDER_SHARED_PREFIX"
unset CYDER_REBUILD_TEST_HEALTH_FAIL
CYDER_REBUILD_TEST_CLONE_FAIL=1
export CYDER_REBUILD_TEST_CLONE_FAIL
if cyder_rebuild_shared_prefix /tmp/fake-wine /tmp/fake-engine; then
  echo "ASSERT failed: Golden clone failure should fail rebuild" >&2
  exit 1
fi
[[ ! -e "$CYDER_SHARED_PREFIX" ]] || {
  echo "ASSERT failed: failed first prefix should not be published" >&2
  exit 1
}

echo "PASS test-cyder-prefix-rebuild"
