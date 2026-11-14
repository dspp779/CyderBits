#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d /private/tmp/cyder-component-hooks.XXXXXX)"
trap 'rm -rf "$TEMP"' EXIT
export HOME="$TEMP/home" CYDER_RESOURCES="$TEMP/Resources" CYDER_RUNTIME_ROOT="$TEMP/runtime"
mkdir -p "$HOME" "$CYDER_RESOURCES/component-manifests" "$CYDER_RESOURCES/ogom-scripts"
printf '{}\n' >"$CYDER_RESOURCES/component-manifests/index.json"
cat >"$CYDER_RESOURCES/ogom-scripts/cyder-component-integrity.rb" <<'RUBY'
require 'json'
puts JSON.generate('fixtureArguments' => ARGV, 'sdkroot' => ENV.key?('SDKROOT'))
exit 3
RUBY
source "$ROOT/scripts/cyder-component-check.sh"
cyder_check_components all quick "$TEMP/bottle with spaces" 2>"$TEMP/quick"
cyder_check_components engine full 2>"$TEMP/full"
/usr/bin/ruby -r json - "$TEMP" <<'RUBY'
root = ARGV.fetch(0)
{'quick' => ['all','quick','5'], 'full' => ['engine','full','60']}.each do |name, expected|
  args = JSON.parse(File.readlines(File.join(root,name)).first).fetch('fixtureArguments')
  values = %w[--component --depth --budget].map { |key| args[args.index(key)+1] }
  if name == 'quick'
    raise 'prefix missing' unless args[args.index('--bottle')+1] == File.join(root, 'bottle with spaces')
  else
    raise 'install-only scan must not assume a prefix' if args.include?('--bottle')
  end
  raise 'wrong diagnostic scope/budget' unless values == expected && args.include?('--summary')
end
RUBY
# The system Ruby's rbconfig runs xcrun at start unless SDKROOT is set.
grep -q '"sdkroot":true' "$TEMP/quick" || { echo 'integrity scan must run with SDKROOT set' >&2; exit 1; }

# Launch preparation: start returns at once, wait blocks until the scan ends.
cat >"$CYDER_RESOURCES/ogom-scripts/cyder-component-integrity.rb" <<'RUBY'
sleep 1
File.write(ENV.fetch('SCAN_DONE'), 'done')
RUBY
export SCAN_DONE="$TEMP/scan-done"
started=$SECONDS
cyder_check_components_start all quick "$TEMP/bottle with spaces" 2>/dev/null
[[ $((SECONDS - started)) -lt 1 && ! -e "$SCAN_DONE" ]] || { echo 'start must not wait for the scan' >&2; exit 1; }
cyder_check_components_wait
[[ -e "$SCAN_DONE" && -z "${CYDER_COMPONENT_CHECK_PID:-}" ]] || { echo 'wait must return after the scan' >&2; exit 1; }
cyder_check_components_wait  # a second wait with nothing running is a no-op

# One scan per launch: prepare starts it after graphics, final skips it.
graphics_line=$(grep -n 'cyder_prepare_graphics_prefix "$wine" "$engine" "$prefix"' "$ROOT/scripts/cyder_launcher.sh" | head -1 | cut -d: -f1)
start_line=$(grep -n 'cyder_check_components_start all quick "$prefix"' "$ROOT/scripts/cyder_launcher.sh" | head -1 | cut -d: -f1)
[[ -n "$graphics_line" && -n "$start_line" && "$start_line" -gt "$graphics_line" ]] ||
  { echo 'prepare must start the scan after the graphics update' >&2; exit 1; }
grep -q 'cyder_check_components_wait; fi' <<<"$(sed -n '/^cyder_on_exit() {/,/^}/p' "$ROOT/scripts/cyder_launcher.sh")" ||
  { echo 'an early launcher exit must wait for the scan' >&2; exit 1; }
phase_case="$(sed -n '/case "${CYDER_LAUNCH_PREPARATION_PHASE:-}" in/,/esac/p' "$ROOT/scripts/cyder-common.sh" | grep -A4 'one scan per launch')"
grep -q 'prepare) .*cyder_check_components_wait' <<<"$phase_case" || { echo 'prepare must wait for its scan' >&2; exit 1; }
grep -q '^ *final) ;;' <<<"$phase_case" || { echo 'final phase must not scan again' >&2; exit 1; }
grep -q '\*) .*cyder_check_components all quick "$prefix"' <<<"$phase_case" || { echo 'non-phased launches keep the scan' >&2; exit 1; }

# Older/development payloads without a signed inventory are left alone.
rm "$CYDER_RESOURCES/component-manifests/index.json"
cyder_check_components all quick "$TEMP/bottle with spaces" 2>"$TEMP/absent"
test ! -s "$TEMP/absent"
echo 'PASS: read-only hook scope, budgets, unknown does not repair/block, one background scan per launch, old bundle compatibility'
