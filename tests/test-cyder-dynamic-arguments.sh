#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

runtime="$TMP/runtime"
support="$TMP/support"
engine="$runtime/Engines/wine-x86_64"
exe="$TMP/game.exe"
argument_log="$TMP/arguments.log"

mkdir -p "$engine/bin" "$support/bottles/shared"
touch "$exe" "$support/bottles/shared/.cyder-bootstrap-v1"
printf 'CX26.2.0-W11-Cyder003\n' >"$engine/version"

cat >"$engine/bin/wine" <<'SH'
#!/usr/bin/env bash
printf '<%s>\n' "$@" >"$CYDER_TEST_ARGUMENT_LOG"
SH
chmod +x "$engine/bin/wine"

CYDER_RUNTIME_ROOT="$runtime" \
CYDER_SUPPORT="$support" \
CYDER_TEST_ARGUMENT_LOG="$argument_log" \
CYDER_CAPTURE_WINE_LOG=1 \
  bash "$ROOT/scripts/cyder_launcher.sh" \
    --launch-exe "$exe" -- \
    'tw.login.maplestory.beanfun.com' '8484' 'BeanFun' 'T9 test account' '0123456789'

actual=()
while IFS= read -r line; do
  actual+=("$line")
done <"$argument_log"
expected=(
  "<$exe>"
  '<tw.login.maplestory.beanfun.com>'
  '<8484>'
  '<BeanFun>'
  '<T9 test account>'
  '<0123456789>'
)
assert_eq "${#actual[@]}" "${#expected[@]}" "dynamic launch should preserve the argument count"
for index in "${!expected[@]}"; do
  assert_eq "${actual[$index]}" "${expected[$index]}" "dynamic launch should preserve argv boundary $index"
done

launch_log="$(readlink "$support/Logs/last-launch.log")"
launch_log="$support/Logs/$launch_log"
summary="$(cat "$launch_log")"
assert_contains "$summary" 'T9 test account 0123456789' "debug launch summary should include dynamic arguments"

CYDER_RUNTIME_ROOT="$runtime" \
CYDER_SUPPORT="$support" \
CYDER_TEST_ARGUMENT_LOG="$argument_log" \
CYDER_CAPTURE_WINE_LOG=1 \
CYDER_REDACT_DYNAMIC_ARGS=1 \
  bash "$ROOT/scripts/cyder_launcher.sh" \
    --launch-exe "$exe" -- 'BeanFun' 'T9 test account' '0123456789'
redacted_log="$(readlink "$support/Logs/last-launch.log")"
redacted_summary="$(cat "$support/Logs/$redacted_log")"
assert_contains "$redacted_summary" '<3 dynamic arguments redacted>' "support logs should offer opt-in argument redaction"
if [[ "$redacted_summary" == *'0123456789'* || "$redacted_summary" == *'T9 test account'* ]]; then
  echo "ASSERT failed: opt-in redaction must hide dynamic credentials" >&2
  exit 1
fi

app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
if [[ "$app" == *'if arg == "--launch-exe"'* || "$app" == *'if arg == "--"'* ]]; then
  echo "ASSERT failed: native Cyder must not reserve public command-line options" >&2
  exit 1
fi
assert_contains "$app" 'Public argv contract: `Cyder [game.exe] [game argument ...]`' "native Cyder should expose an option-free argv contract"
assert_contains "$app" 'pendingLaunchArguments = Array(applicationArguments)' "native Cyder should preserve dynamic argv"
assert_contains "$app" 'CYDER_TEST_SETTINGS_REQUEST' "internal launch settings should use environment rather than argv"
assert_contains "$app" 'CYDER_CAPTURE_WINE_LOG' "test launches should enable Wine log capture by default"
assert_contains "$app" 'CYDER_LAUNCH_KIND' "test launches should mark launch kind for log headers"
assert_contains "$app" 'Running command:' "Wine launch logs should include a CrossOver-style command header"
assert_contains "$app" 'let gameArguments = launchArguments ?? savedGameArguments' "dynamic arguments should replace saved arguments"
assert_contains "$app" 'CYDER_REDACT_DYNAMIC_ARGS' "native diagnostics should offer opt-in dynamic argument redaction"

echo "PASS test-cyder-dynamic-arguments"
