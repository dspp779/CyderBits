#!/usr/bin/env bash
# Contract tests for Finder-openable Windows documents (.bat/.cmd/.lnk/.reg).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

launcher="$(cat "$ROOT/scripts/cyder_launcher.sh")"
common="$(cat "$ROOT/scripts/cyder-common.sh")"
support="$(cat "$ROOT/scripts/cyder_launch_support.swift")"
app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
pack="$(cat "$ROOT/scripts/create-cyder-app.sh")"
wrapper="$(cat "$ROOT/scripts/cyder-macos-wrapper.sh")"

assert_contains "$launcher" '--launch-script' \
  "launcher must expose --launch-script for .bat/.cmd"
assert_contains "$launcher" '--launch-lnk' \
  "launcher must expose --launch-lnk for Shell Link files"
assert_contains "$launcher" '--launch-reg' \
  "launcher must expose --launch-reg for registry files"
assert_contains "$launcher" 'Missing or invalid .bat/.cmd' \
  "script launch validation must name bat/cmd"
assert_contains "$launcher" 'Missing or invalid .lnk' \
  "lnk launch validation must name lnk"
assert_contains "$launcher" 'Missing or invalid .reg' \
  "reg launch validation must name reg"
assert_contains "$launcher" 'Cannot import registry while the shared prefix is running' \
  "reg import must refuse a busy shared prefix"

assert_contains "$common" 'CYDER_LAUNCH_TARGET_KIND' \
  "Wine spawn must branch on launch target kind"
assert_contains "$common" 'cmd /c' \
  "script launches must invoke cmd /c"
assert_contains "$common" 'start /wait /unix' \
  "lnk launches must use Wine start /unix"
assert_contains "$common" 'regedit /s' \
  "reg launches must use quiet regedit /s"

assert_contains "$support" 'ext == "bat"' \
  "Swift path filter must accept .bat"
assert_contains "$support" 'ext == "cmd"' \
  "Swift path filter must accept .cmd"
assert_contains "$support" 'ext == "lnk"' \
  "Swift path filter must accept .lnk"
assert_contains "$support" 'ext == "reg"' \
  "Swift path filter must accept .reg"
assert_contains "$support" 'case script' \
  "CyderWineLaunchTarget must include script"
assert_contains "$support" 'case link' \
  "CyderWineLaunchTarget must include link"
assert_contains "$support" 'case reg' \
  "CyderWineLaunchTarget must include reg"

assert_contains "$app" '--launch-script' \
  "AppKit must relay script documents to Bash"
assert_contains "$app" '--launch-lnk' \
  "AppKit must relay lnk documents to Bash"
assert_contains "$app" '--launch-reg' \
  "AppKit must relay reg documents to Bash"
assert_contains "$app" 'CYD-REG-001' \
  "busy-prefix reg failures must use a dedicated error code"

assert_contains "$pack" '<string>bat</string>' \
  "Info.plist must declare .bat"
assert_contains "$pack" '<string>cmd</string>' \
  "Info.plist must declare .cmd"
assert_contains "$pack" '<string>lnk</string>' \
  "Info.plist must declare .lnk"
assert_contains "$pack" '<string>reg</string>' \
  "Info.plist must declare .reg"

assert_contains "$wrapper" '*.bat' \
  "macOS wrapper must detect .bat arguments"
assert_contains "$wrapper" '--launch-script' \
  "wrapper must route scripts to --launch-script"
assert_contains "$wrapper" '--launch-lnk' \
  "wrapper must route shortcuts to --launch-lnk"
assert_contains "$wrapper" '--launch-reg' \
  "wrapper must route registry files to --launch-reg"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-win-docs.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
touch "$TMP/sample.bat" "$TMP/sample.cmd" "$TMP/sample.lnk" "$TMP/sample.reg"

set +e
bat_out="$(bash "$ROOT/scripts/cyder_launcher.sh" --launch-script /nonexistent/missing.bat 2>&1)"
bat_status=$?
set -e
assert_eq "$bat_status" 1 "launch-script with missing file should fail"
assert_contains "$bat_out" "Missing or invalid .bat/.cmd" "launch-script should validate extension"

set +e
bat_nr="$(CYDER_SUPPORT="$TMP/not-ready" bash "$ROOT/scripts/cyder_launcher.sh" --launch-script "$TMP/sample.bat" 2>&1)"
bat_nr_status=$?
set -e
assert_eq "$bat_nr_status" "2" "launch-script must not create a missing environment"
assert_contains "$bat_nr" "open Cyder.app" "launch-script should direct the user to setup"

set +e
lnk_out="$(bash "$ROOT/scripts/cyder_launcher.sh" --launch-lnk /nonexistent/missing.lnk 2>&1)"
lnk_status=$?
set -e
assert_eq "$lnk_status" 1 "launch-lnk with missing file should fail"

set +e
reg_out="$(bash "$ROOT/scripts/cyder_launcher.sh" --launch-reg /nonexistent/missing.reg 2>&1)"
reg_status=$?
set -e
assert_eq "$reg_status" 1 "launch-reg with missing file should fail"

set +e
reg_nr="$(CYDER_SUPPORT="$TMP/not-ready" bash "$ROOT/scripts/cyder_launcher.sh" --launch-reg "$TMP/sample.reg" 2>&1)"
reg_nr_status=$?
set -e
assert_eq "$reg_nr_status" "2" "launch-reg must not create a missing environment"

echo "PASS test-cyder-windows-documents"
