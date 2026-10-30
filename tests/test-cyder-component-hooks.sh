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
puts JSON.generate('fixtureArguments' => ARGV)
exit 3
RUBY
source "$ROOT/scripts/cyder-component-check.sh"
cyder_check_components all quick 2>"$TEMP/quick"
cyder_check_components engine full 2>"$TEMP/full"
/usr/bin/ruby -r json - "$TEMP" <<'RUBY'
root = ARGV.fetch(0)
{'quick' => ['all','quick','5'], 'full' => ['engine','full','60']}.each do |name, expected|
  args = JSON.parse(File.readlines(File.join(root,name)).first).fetch('fixtureArguments')
  values = %w[--component --depth --budget].map { |key| args[args.index(key)+1] }
  raise 'wrong diagnostic scope/budget' unless values == expected && args.include?('--summary')
end
RUBY
# Older/development payloads without a signed inventory are left alone.
rm "$CYDER_RESOURCES/component-manifests/index.json"
cyder_check_components all quick 2>"$TEMP/absent"
test ! -s "$TEMP/absent"
echo 'PASS: read-only hook scope, budgets, unknown does not repair/block, old bundle compatibility'
