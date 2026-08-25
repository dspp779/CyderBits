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

rosetta_swift="$(cat "$ROOT/scripts/cyder_rosetta.swift")"
assert_contains "$rosetta_swift" '/usr/sbin/softwareupdate' \
  "Swift Rosetta helper must invoke softwareupdate"
assert_contains "$rosetta_swift" '--agree-to-license' \
  "Swift consented install must pass --agree-to-license"
assert_contains "$rosetta_swift" 'static var isInstalled' \
  "Swift must expose Rosetta installed check"

diag="$(cat "$ROOT/scripts/cyder_diagnostics.swift")"
assert_contains "$diag" 'case rosettaCheck = "rosetta-check"' \
  "diagnostics must define rosetta-check stage"

build="$(cat "$ROOT/scripts/create-cyder-app.sh")"
assert_contains "$build" 'cyder_rosetta.swift' \
  "app build must compile cyder_rosetta.swift"

app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
assert_contains "$app" 'CYD-ROS-001' \
  "app must surface CYD-ROS-001"
assert_contains "$app" '需要安裝 Rosetta 2' \
  "app must show consent title"
assert_contains "$app" 'ensureRosettaForEnvironment' \
  "ensureEnvironment must call Rosetta gate"
assert_contains "$app" 'installWithAgreedLicense' \
  "app must install only after consent path"

echo "PASS test-cyder-rosetta"
