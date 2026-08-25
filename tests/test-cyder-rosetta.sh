#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
source "$ROOT/scripts/cyder-ensure-rosetta.sh"

rosetta_script="$(<"$ROOT/scripts/cyder-ensure-rosetta.sh")"
assert_contains "$rosetta_script" "/usr/sbin/softwareupdate --install-rosetta" \
  "Rosetta installation must use the macOS installer"
assert_contains "$rosetta_script" 'CYDER_GUI' \
  "Rosetta ensure must branch on CYDER_GUI"
# Bash must not pass --agree-to-license (Swift owns consented install).
if [[ "$rosetta_script" == *"--agree-to-license"* ]]; then
  echo "ASSERT failed: bash must not --agree-to-license; Swift owns consent install" >&2
  exit 1
fi

ensure_fn="$(sed -n '/^cyder_ensure_rosetta()/,/^}/p' "$ROOT/scripts/cyder-ensure-rosetta.sh")"
assert_contains "$ensure_fn" 'CYDER_GUI' \
  "ensure must treat GUI differently from CLI"
assert_contains "$ensure_fn" 'return 1' \
  "GUI missing-Rosetta path must fail without installing"

can_run_runtime=1
if cyder_is_apple_silicon && ! cyder_rosetta_is_installed; then
  can_run_runtime=0
  echo "SKIP: Rosetta 2 not installed (cannot run runtime ensure tests)"
fi

if [[ "$can_run_runtime" == 1 ]]; then
  if cyder_is_apple_silicon; then
    cyder_ensure_rosetta
    echo "Rosetta check OK on Apple Silicon"
  else
    cyder_ensure_rosetta
    echo "Rosetta check skipped on $(uname -m)"
  fi

  set +e
  status="$(
    CYDER_GUI=1 bash "$ROOT/scripts/cyder_launcher.sh" --ensure-rosetta-only >/dev/null 2>&1
    echo $?
  )"
  set -e
  assert_eq "$status" "0" "--ensure-rosetta-only should succeed when Rosetta is available"
fi

echo "PASS test-cyder-rosetta"
