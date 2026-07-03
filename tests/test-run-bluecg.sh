#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/BlueCrossgateNew/BlueLauncher_temp/BlueCG_updatelogin"
touch "$TMP/BlueCrossgateNew/BlueLauncher.exe"
touch "$TMP/BlueCrossgateNew/bluecg.exe"
printf 'official-ddraw' > "$TMP/BlueCrossgateNew/BlueLauncher_temp/BlueCG_updatelogin/DDRAW.dll"

output="$(bash "$ROOT/scripts/run-bluecg.sh" --prefix "$TMP/BlueCrossgateNew" --wine-install "$ROOT/install/wine-x86_64" --dry-run 2>&1 || true)"

assert_contains "$output" "cp" "dry-run should copy the official DDRAW.dll into the game root"
assert_contains "$output" "ddraw.dll" "copy target should be lowercase ddraw.dll"
assert_contains "$output" "BlueLauncher.exe" "launcher mode should start BlueLauncher.exe by default"
assert_contains "$output" "arch -x86_64" "launcher should run under Rosetta x86_64"

echo "PASS test-run-bluecg"
