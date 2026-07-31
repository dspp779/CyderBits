#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

script="$(cat "$ROOT/scripts/release-cyder.sh")"

assert_contains "$script" '--channel test|release' \
  "usage should document test and release channels"
assert_contains "$script" 'export SIGN_IDENTITY=-' \
  "test channel should default to ad-hoc signing"
assert_contains "$script" 'release channel refuses SIGN_IDENTITY=-' \
  "release channel must reject ad-hoc identity"
assert_contains "$script" 'notarytool submit' \
  "release channel must submit to Apple notarization"
assert_contains "$script" 'stapler staple' \
  "release channel must staple the notarization ticket"
assert_contains "$script" 'Cyder.app.zip' \
  "release channel must produce a post-staple publish zip"
assert_contains "$script" 'resolve_pinned_engine' \
  "release channel should resolve the pinned engine archive"
assert_contains "$script" 'create-cyder-app.sh' \
  "pipeline must build via create-cyder-app.sh"
assert_contains "$script" '--sign-identity' \
  "pipeline should accept an explicit --sign-identity"
assert_contains "$script" 'test channel with non-adhoc' \
  "test channel should warn when an explicit non-adhoc identity is used"

# Dry-run test channel should not require Developer ID or network.
# Inherit a release-looking SIGN_IDENTITY to ensure test still forces ad-hoc.
out="$(
  SIGN_IDENTITY='Developer ID Application: Example' \
    bash "$ROOT/scripts/release-cyder.sh" --channel test --dry-run --out-dir /tmp/cyder-release-dry 2>&1
)"
assert_contains "$out" 'create-cyder-app.sh' "test dry-run should invoke create-cyder-app"
assert_contains "$out" 'SIGN_IDENTITY=-' "test dry-run should force ad-hoc identity"

echo "PASS test-release-cyder"
