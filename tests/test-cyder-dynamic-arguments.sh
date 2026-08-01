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
touch "$exe" "$support/bottles/shared/.cyder-bootstrap-v1" "$support/bottles/shared/user.reg"
printf 'CX26.2.0-W11-Cyder003\n' >"$engine/version"

cat >"$engine/bin/wine" <<'SH'
#!/usr/bin/env bash
printf '<%s>\n' "$@" >"$CYDER_TEST_ARGUMENT_LOG"
if [[ -n "${CYDER_TEST_ENV_LOG:-}" ]]; then
  printf 'prefix=%s\nmarker=%s\n' "${WINEPREFIX:-}" "${GAME_TEST_MARKER:-}" >"$CYDER_TEST_ENV_LOG"
fi
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

# A settings file without this EXE's profile is the normal global-settings
# fallback and must not be reported as a settings-apply error by the ERR trap.
/usr/bin/plutil -create xml1 "$support/settings.json"
/usr/bin/plutil -insert schemaVersion -integer 4 "$support/settings.json"
/usr/bin/plutil -insert perProfile -dictionary "$support/settings.json"
diagnostic_output="$(
  CYDER_RUNTIME_ROOT="$runtime" \
  CYDER_SUPPORT="$support" \
  CYDER_TEST_ARGUMENT_LOG="$argument_log" \
  CYDER_DIAGNOSTIC_VERBOSE=1 \
    bash "$ROOT/scripts/cyder_launcher.sh" --launch-exe "$exe" 2>&1
)"
assert_not_contains "$diagnostic_output" 'diagnostic event=error' \
  "a missing per-profile entry must silently fall back to global settings"

# The shell launch backend must consume the same one-shot settings request that
# the game-library Test button creates, without routing through Swift.
request_dir="$support/launch-requests"
request="$request_dir/test-request.json"
environment_log="$TMP/environment.log"
mkdir -p "$request_dir"
printf '%s\n' '{"arguments":["saved override","--flag"],"environment":{"GAME_TEST_MARKER":"from-request"}}' >"$request"
CYDER_RUNTIME_ROOT="$runtime" \
CYDER_SUPPORT="$support" \
CYDER_TEST_ARGUMENT_LOG="$argument_log" \
CYDER_TEST_ENV_LOG="$environment_log" \
CYDER_TEST_SETTINGS_REQUEST="$request" \
  bash "$ROOT/scripts/cyder_launcher.sh" --launch-exe "$exe"
assert test ! -e "$request"
assert_contains "$(cat "$argument_log")" '<saved override>' \
  "one-shot launch settings must supply saved arguments through Bash"
assert_contains "$(cat "$environment_log")" 'marker=from-request' \
  "one-shot launch settings must supply environment variables through Bash"

# An existing independent profile must select its own bottle in the Bash path.
profile_id="$(bash "$ROOT/scripts/cyder-profile.sh" id "$exe")"
profile_bottle="$support/bottles/$profile_id"
profile_metadata="$support/profiles/$profile_id"
mkdir -p "$profile_bottle" "$profile_metadata"
touch "$profile_bottle/user.reg"
bash "$ROOT/scripts/cyder-profile.sh" metadata "$profile_metadata" "$profile_id" "$exe" golden
CYDER_RUNTIME_ROOT="$runtime" \
CYDER_SUPPORT="$support" \
CYDER_TEST_ARGUMENT_LOG="$argument_log" \
CYDER_TEST_ENV_LOG="$environment_log" \
  bash "$ROOT/scripts/cyder_launcher.sh" --launch-exe "$exe"
assert_contains "$(cat "$environment_log")" "prefix=$profile_bottle" \
  "Bash launch must resolve and use an independent profile bottle"

# Restore the credential-redaction fixture after the additional backend calls.
CYDER_RUNTIME_ROOT="$runtime" \
CYDER_SUPPORT="$support" \
CYDER_TEST_ARGUMENT_LOG="$argument_log" \
CYDER_CAPTURE_WINE_LOG=1 \
  bash "$ROOT/scripts/cyder_launcher.sh" \
    --launch-exe "$exe" -- \
    'tw.login.maplestory.beanfun.com' '8484' 'BeanFun' 'T9 test account' '0123456789'

launch_log="$(readlink "$support/Logs/last-launch.log")"
launch_log="$support/Logs/$launch_log"
summary="$(cat "$launch_log")"
assert_contains "$summary" '<5 game arguments redacted>' "launch summary should redact dynamic arguments"
if [[ "$summary" == *'0123456789'* || "$summary" == *'T9 test account'* ]]; then
  echo "ASSERT failed: launch logs must never persist dynamic credentials" >&2
  exit 1
fi

CYDER_RUNTIME_ROOT="$runtime" \
CYDER_SUPPORT="$support" \
CYDER_TEST_ARGUMENT_LOG="$argument_log" \
CYDER_CAPTURE_WINE_LOG=1 \
CYDER_REDACT_DYNAMIC_ARGS=1 \
  bash "$ROOT/scripts/cyder_launcher.sh" \
    --launch-exe "$exe" -- 'BeanFun' 'T9 test account' '0123456789'
redacted_log="$(readlink "$support/Logs/last-launch.log")"
redacted_summary="$(cat "$support/Logs/$redacted_log")"
assert_contains "$redacted_summary" '<3 game arguments redacted>' "support logs should always redact arguments"
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
assert_contains "$app" 'pendingLaunchArguments = applicationArguments.isEmpty' \
  "native Cyder should treat empty post-exe argv as no dynamic arguments"
assert_contains "$app" 'CYDER_TEST_SETTINGS_REQUEST' "internal launch settings should use environment rather than argv"
assert_contains "$app" 'CYDER_CAPTURE_WINE_LOG' "test launches should enable Wine log capture by default"
assert_contains "$app" 'CYDER_LAUNCH_KIND' "test launches should mark launch kind for log headers"
common="$(cat "$ROOT/scripts/cyder-common.sh")"
assert_contains "$common" 'Running command:' "Bash Wine logs should include a CrossOver-style command header"
assert_contains "$common" 'game_args_text="<${#game_args[@]} game arguments redacted>"' \
  "Bash diagnostics must always redact game arguments"

# UI: command-line args field should be multiline like environment variables.
library_ui="$(cat "$ROOT/scripts/cyder_game_library_ui.swift")"
assert_contains "$library_ui" 'private let arguments = CyderPlaceholderTextView()' \
  "game launch options should use a multiline arguments field"
assert_contains "$library_ui" 'multilineInput(arguments)' \
  "arguments field should reuse the environment multiline layout"
assert_contains "$library_ui" 'private func parseEnvironment(_ text: String)' \
  "environment field should accept space- or newline-separated KEY=value pairs"

echo "PASS test-cyder-dynamic-arguments"
