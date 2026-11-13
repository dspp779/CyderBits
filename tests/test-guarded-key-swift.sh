#!/usr/bin/env bash
# guarded-key.swift: argument checks and key table. Runs offline: every case
# here must refuse or exit before any window lookup, activation or input.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/guarded-key"

swiftc -O -module-cache-path "$TMP/module-cache" \
  "$ROOT/.agents/skills/wine-game-compat-testing/scripts/guarded-key.swift" -o "$BIN"

# Key table: the keys the MapleStory scenes need (Command = jump, alone only).
keys="$("$BIN" --list-keys)"
for k in left right up down space command control alt shift z x a f1 pageup; do
  grep -qx -- "$k" <<<"$keys" || { echo "ASSERT failed: key '$k' missing from --list-keys" >&2; exit 1; }
done

expect_refusal() {
  local want="$1"; shift
  local out status=0
  out="$("$BIN" "$@" 2>&1)" || status=$?
  assert_eq "$status" "2" "exit status for: $*"
  assert_contains "$out" "REFUSED: $want" "refusal text for: $*"
}

expect_refusal "usage" 123 456
expect_refusal "usage" 0 456 Title left
expect_refusal "usage" 123 abc Title left
expect_refusal "unknown key 'cmd+q'" 123 456 Title cmd+q
expect_refusal "unknown key 'control+c'" 123 456 Title control+c
expect_refusal "--hold needs" 123 456 Title left --hold
expect_refusal "--hold needs" 123 456 Title left --hold -5
expect_refusal "--hold needs" 123 456 Title left --hold 10001
expect_refusal "--hold needs" 123 456 Title left --hold 1.5

echo "ok: guarded-key argument checks"
