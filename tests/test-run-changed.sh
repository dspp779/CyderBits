#!/usr/bin/env bash
# tests/run.sh: --changed selection (unpushed work, Swift typecheck), skip
# (exit 77), shared Swift module cache, per-test limit and time estimate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
# The checks below set release mode themselves; a release run must not leak in.
unset CYDER_TEST_FULL_TIMING CYDER_TEST_DESKTOP
export CYDER_TEST_DURATIONS="$(mktemp)"
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
assert_not_contains "$observer" test-cyder-app-integration.sh "a Swift change no longer pulls in every app-build test"
assert_eq "$(python3 -I "$ROOT/tests/select-changed.py" --files scripts/cyder_launch_observer.swift --swift-changed)" yes \
  "a Swift change asks for the app typecheck"
assert_eq "$(python3 -I "$ROOT/tests/select-changed.py" --files scripts/cyder-common.sh --swift-changed)" no "a shell change does not"
unnamed_swift="scripts/cyder_$(printf un)named_feature.swift"
assert_eq "$(pick "$unnamed_swift")" "" "a Swift file no test names is covered by the typecheck, not the whole suite"
assert_not_contains "$observer" test-cyder-compatdb-data.sh "unrelated tests are not selected"

# A throwaway repo with its own copy of the runner.
repo="$TMP/repo"
mkdir -p "$repo/tests/lib" "$repo/scripts"
cp "$ROOT/tests/run.sh" "$ROOT/tests/assert.sh" "$ROOT/tests/select-changed.py" "$repo/tests/"
cp "$ROOT/tests/lib/swiftc" "$ROOT/tests/lib/typecheck-app.sh" "$repo/tests/lib/"
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
assert_contains "$out" "3 tests, about 0 min 15 s (0 timed before; limit 240s each)" "the run starts with a count and an estimate"
assert_contains "$(cat "$CYDER_TEST_DURATIONS")" "test-a.sh" "passing tests' durations are kept for the next estimate"
assert_contains "$(bash "$repo/tests/run.sh" test-a.sh 2>&1)" "1 tests, about 0 min 0 s (1 timed before" "the next estimate uses them"
assert_contains "$out" "skip test-b.sh (needs an idle desktop)" "a skip is reported with its reason"
assert_contains "$out" "passed: 2  failed: 0  skipped: 1" "the summary counts skips"
out="$(CYDER_TEST_FULL_TIMING=1 bash "$repo/tests/run.sh" 2>&1)" && status=0 || status=$?
assert_eq "$status" 1 "a skip fails a release run"
assert_contains "$out" "limit 600s each" "release runs allow longer tests"
printf '#!/bin/bash\nsleep 5\n' >"$repo/tests/test-slow.sh"
out="$(bash "$repo/tests/run.sh" --timeout 1 slow 2>&1)" && status=0 || status=$?
assert_eq "$status" 1 "a test over the limit fails"
assert_contains "$out" "test-slow.sh hit the 1s limit" "the limit is named"
rm "$repo/tests/test-slow.sh"

assert_contains "$(bash "$repo/tests/run.sh" --changed 2>&1)" "no tests affected" "no changes run nothing"
echo 'echo a2' >"$repo/scripts/a.sh"
out="$(bash "$repo/tests/run.sh" --changed 2>&1)"
assert_contains "$out" "ok   test-a.sh" "an uncommitted change selects its test"
assert_not_contains "$out" "test-b.sh" "other tests do not run"
git -C "$repo" -c user.email=t@t -c user.name=t commit -qam change
out="$(bash "$repo/tests/run.sh" --changed main 2>&1)"
assert_contains "$out" "passed: 1  failed: 0  skipped: 0" "a committed change against the base selects its test"

# Without a base, --changed covers only what has not been pushed.
git init -q --bare "$TMP/remote.git"
git -C "$repo" remote add origin "$TMP/remote.git"
git -C "$repo" push -q -u origin topic 2>/dev/null
out="$(bash "$repo/tests/run.sh" --changed 2>&1)"
assert_contains "$out" "changes against origin/topic" "the default base is the upstream branch"
assert_contains "$out" "no tests affected" "pushed work is not run again"
echo 'echo b2' >"$repo/scripts/b.sh"
git -C "$repo" -c user.email=t@t -c user.name=t commit -qam unpushed
out="$(bash "$repo/tests/run.sh" --changed 2>&1)"
assert_contains "$out" "skip test-b.sh" "an unpushed commit selects its test"
assert_not_contains "$out" "test-a.sh" "already-pushed changes are not selected"

# A Swift change typechecks the whole app first; a failure stops the run.
echo '// x' >"$repo/scripts/cyder_x.swift"
out="$(CYDER_TEST_TYPECHECK_CMD=true bash "$repo/tests/run.sh" --changed 2>&1)"
assert_contains "$out" "ok   app typecheck" "a Swift change runs the app typecheck"
out="$(CYDER_TEST_TYPECHECK_CMD=false bash "$repo/tests/run.sh" --changed 2>&1)" && status=0 || status=$?
assert_eq "$status" 1 "a failed typecheck fails the run"
assert_contains "$out" "FAIL app typecheck" "and says so"
rm -f "$CYDER_TEST_DURATIONS"
echo "PASS run.sh --changed, skips, module cache, limit and estimate"
