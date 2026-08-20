#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

script="$(cat "$ROOT/scripts/cyder-measure-startup.sh")"
assert_contains "$script" "--first-prefix" "measure script must isolate first-prefix bootstrap"
assert_contains "$script" "--ensure-engine-only" "measure script must time ensure-engine"
assert_contains "$script" "--scan-uri-handlers" "measure script must time URI precheck"
assert_contains "$script" "bootstrap-timing.jsonl" \
  "measure script must summarize bootstrap substage timing"
assert_contains "$script" "cyder-prefetch-bootstrap-msi.sh" \
  "measure script must time MSI prefetch on first prefix"
assert_not_contains "$script" "--templates-ready" "measure script must stop timing the removed templates-ready probe"
assert_not_contains "$script" "--rebuild-prefix" "measure script must not rebuild the live bottle"

diag="$(cat "$ROOT/scripts/cyder_diagnostics.swift")"
assert_contains "$diag" "previous_ms=" "stage enter must record previous_ms"
assert_contains "$diag" "func noteElapsed" "operations must record elapsed_ms"

app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
assert_contains "$app" 'operation: "exe-precheck"' "Finder EXE path must time prechecks"
assert_contains "$app" 'operation: "uri-precheck"' "URI path must time handler validation"

echo "PASS test-cyder-measure-startup"
