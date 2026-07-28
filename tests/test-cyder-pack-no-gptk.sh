#!/usr/bin/env bash
# pack-engine-artifact.sh must refuse redistributable GPTK trees.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

pack="$(cat "$ROOT/scripts/pack-engine-artifact.sh")"
assert_contains "$pack" "--exclude 'lib64/apple_gptk'" \
  "pack should rsync-exclude lib64/apple_gptk"
assert_contains "$pack" "Refusing to pack engine that contains apple_gptk" \
  "pack should fail closed if apple_gptk is still present after staging"

echo "PASS test-cyder-pack-no-gptk"
