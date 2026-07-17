#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-game-library-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/games/a" "$TMP/games/b"
touch "$TMP/games/a/測試遊戲.EXE" "$TMP/games/b/another.exe"

swiftc -parse-as-library \
  -module-cache-path "$TMP/module-cache" \
  -o "$TMP/harness" \
  "$ROOT/scripts/cyder_paths.swift" \
  "$ROOT/scripts/cyder_profiles.swift" \
  "$ROOT/scripts/cyder_game_library.swift" \
  "$ROOT/tests/fixtures/cyder_game_library_harness.swift"

"$TMP/harness" \
  "$TMP/support" \
  "$TMP/games/a/測試遊戲.EXE" \
  "$TMP/games/b/another.exe"
