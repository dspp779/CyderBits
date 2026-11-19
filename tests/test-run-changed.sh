#!/usr/bin/env bash
# tests/run.sh: --changed selection, skip (exit 77), shared Swift module cache.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pick() { python3 -I "$ROOT/tests/select-changed.py" --files "$@" 2>/dev/null; }
assert_eq "$(pick docs/x.md CHANGELOG.md .agents/skills/a/SKILL.md)" "" "documentation selects no tests"
assert_eq "$(pick tests/run.sh)" ALL "a runner change runs everything"
assert_eq "$(pick tests/lib/swiftc)" ALL "a runner helper change runs everything"
unnamed="no/such/$(printf un)named.txt"  # not spelled out, or this test would name it
assert_eq "$(pick "$unnamed")" ALL "a file no test names runs everything"
lifecycle="$(pick tests/test-cyder-lifecycle.sh)"
assert_contains "$lifecycle" test-cyder-lifecycle.sh "a changed test selects itself"
assert_contains "$lifecycle" test-cyder-status-item.sh "and the tests that run it"
observer="$(pick scripts/cyder_launch_observer.swift)"
assert_contains "$observer" test-cyder-launch-observer.sh "a test that compiles the changed file is selected"
assert_contains "$observer" test-cyder-open-files-lifecycle.sh "a test that runs a selected test is selected"
assert_contains "$observer" test-cyder-app-integration.sh "a Swift change selects the tests that build the app"
assert_not_contains "$observer" test-cyder-compatdb-data.sh "unrelated tests are not selected"

# A throwaway repo with its own copy of the runner.
repo="$TMP/repo"
mkdir -p "$repo/tests/lib" "$repo/scripts"
cp "$ROOT/tests/run.sh" "$ROOT/tests/assert.sh" "$ROOT/tests/select-changed.py" "$repo/tests/"
cp "$ROOT/tests/lib/swiftc" "$repo/tests/lib/"
echo 'echo a' >"$repo/scripts/a.sh"
echo 'echo b' >"$repo/scripts/b.sh"
printf '#!/bin/bash\ngrep -q a.sh "$0"; exit 0\n' >"$repo/tests/test-a.sh"
printf '#!/bin/bash\n# uses b.sh\necho "needs an idle desktop"; exit 77\n' >"$repo/tests/test-b.sh"
cat >"$repo/tests/test-cache.sh" <<'T'
#!/bin/bash
# Records the cache the wrapper gives swiftc.
[[ "$(command -v swiftc)" == */tests/lib/swiftc && -n "$CYDER_TEST_MODULE_CACHE" ]]
T
git -C "$repo" init -q -b main
git -C "$repo" -c user.email=t@t -c user.name=t add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm base
git -C "$repo" switch -qc topic

out="$(bash "$repo/tests/run.sh" 2>&1)" && status=0 || status=$?
assert_eq "$status" 0 "a skipped test does not fail the run"
assert_contains "$out" "skip test-b.sh (needs an idle desktop)" "a skip is reported with its reason"
assert_contains "$out" "passed: 2  failed: 0  skipped: 1" "the summary counts skips"
out="$(CYDER_TEST_FULL_TIMING=1 bash "$repo/tests/run.sh" 2>&1)" && status=0 || status=$?
assert_eq "$status" 1 "a skip fails a release run"

assert_contains "$(bash "$repo/tests/run.sh" --changed 2>&1)" "no tests affected" "no changes run nothing"
echo 'echo a2' >"$repo/scripts/a.sh"
out="$(bash "$repo/tests/run.sh" --changed 2>&1)"
assert_contains "$out" "ok   test-a.sh" "an uncommitted change selects its test"
assert_not_contains "$out" "test-b.sh" "other tests do not run"
git -C "$repo" -c user.email=t@t -c user.name=t commit -qam change
out="$(bash "$repo/tests/run.sh" --changed main 2>&1)"
assert_contains "$out" "passed: 1  failed: 0  skipped: 0" "a committed change against the base selects its test"
echo "PASS run.sh --changed, skips and the shared module cache"
