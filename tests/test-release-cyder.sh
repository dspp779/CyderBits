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
assert_contains "$script" 'CYDER_REQUIRE_NATIVE_SWIFT' \
  "release channel must fail closed when native Swift compilation fails"
assert_contains "$script" 'verify_release_app_contract' \
  "release channel must verify version and universal native CyderSwift"
assert_contains "$script" '/usr/bin/lipo "$swift" -verify_arch x86_64 arm64' \
  "release channel must pass the input file before lipo verification options"
assert_contains "$script" 'requires a stable semantic version' \
  "release channel must reject dev and rc version strings"
assert_contains "$(cat "$ROOT/scripts/create-cyder-app.sh")" 'cyder-app-version.txt' \
  "App build must read its version from the shared version file"
assert_eq "$(tr -d '[:space:]' <"$ROOT/config/cyder-app-version.txt")" "0.11.1" \
  "current 0.11.1 must be the shared App version"

# Dry-run test channel should not require Developer ID or network.
# Inherit a release-looking SIGN_IDENTITY to ensure test still forces ad-hoc.
out="$(
  SIGN_IDENTITY='Developer ID Application: Example' \
    bash "$ROOT/scripts/release-cyder.sh" --channel test --dry-run --out-dir /tmp/cyder-release-dry 2>&1
)"
assert_contains "$out" 'create-cyder-app.sh' "test dry-run should invoke create-cyder-app"
assert_contains "$out" 'SIGN_IDENTITY=-' "test dry-run should force ad-hoc identity"

release_out="$(
  SIGN_IDENTITY='Developer ID Application: Example' \
    bash "$ROOT/scripts/release-cyder.sh" --channel release --version 0.11.1 --dry-run --out-dir /tmp/cyder-release-dry 2>&1
)"
assert_contains "$release_out" 'create-cyder-app.sh' \
  "release dry-run should print the App build command"
assert_contains "$release_out" 'Release dry-run complete' \
  "release dry-run should complete without an existing App"

set +e
unstable_out="$(bash "$ROOT/scripts/release-cyder.sh" --channel release --version 0.9.4-rc1 --dry-run 2>&1)"
unstable_status=$?
set -e
assert_eq "$unstable_status" "1" "release channel should reject a prerelease version before signing"
assert_contains "$unstable_out" "requires a stable semantic version" \
  "release rejection should explain the stable-version contract"

echo "PASS test-release-cyder"
