#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-compatdb-integration.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd)"

mkdir -p \
  "$TMP/runtime/CompatDB" \
  "$TMP/repo/compatdb/compiled" \
  "$TMP/repo/scripts" \
  "$TMP/support/bottles/shared"
cp "$ROOT/compatdb/compiled/compatdb.cdb" "$TMP/repo/compatdb/compiled/compatdb.cdb"

bundled="$(
  CYDER_RUNTIME_ROOT="$TMP/runtime" CYDER_SUPPORT="$TMP/support" bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_init_paths "$2"
    printf "%s\n" "${CYDER_COMPATDB_PATH:-}"
  ' _ "$ROOT" "$TMP/repo/scripts"
)"
assert_eq "$bundled" "$TMP/repo/compatdb/compiled/compatdb.cdb" \
  "development launches should select the bundled compiled CompatDB"

hash="$(shasum -a 256 "$ROOT/compatdb/compiled/compatdb.cdb" | awk '{print $1}')"
mkdir -p "$TMP/runtime/CompatDB/$hash"
cp "$ROOT/compatdb/compiled/compatdb.cdb" "$TMP/runtime/CompatDB/$hash/compatdb.cdb"
printf '%s\n' "$hash" >"$TMP/runtime/CompatDB/current"

active_pinned="$(
  CYDER_COMPATDB_ALLOW_UNSIGNED=1 \
  CYDER_RUNTIME_ROOT="$TMP/runtime" CYDER_SUPPORT="$TMP/support" bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_has_running_prefix() { return 0; }
    cyder_init_paths "$2"
    printf "%s\n" "${CYDER_COMPATDB_PATH:-}"
  ' _ "$ROOT" "$TMP/repo/scripts"
)"
assert_eq "$active_pinned" "$TMP/repo/compatdb/compiled/compatdb.cdb" \
  "an active Wine session should retain its pinned database"

updated="$(
  CYDER_COMPATDB_ALLOW_UNSIGNED=1 \
  CYDER_RUNTIME_ROOT="$TMP/runtime" CYDER_SUPPORT="$TMP/support" bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_init_paths "$2"
    printf "%s\n" "${CYDER_COMPATDB_PATH:-}"
  ' _ "$ROOT" "$TMP/repo/scripts"
)"
assert_eq "$updated" "$TMP/runtime/CompatDB/$hash/compatdb.cdb" \
  "a valid content-addressed update should take precedence"

disabled="$(
  CYDER_COMPATDB=0 CYDER_RUNTIME_ROOT="$TMP/runtime" CYDER_SUPPORT="$TMP/support" bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_init_paths "$2"
    printf "%s\n" "${CYDER_COMPATDB_PATH:-}"
  ' _ "$ROOT" "$TMP/repo/scripts"
)"
assert_eq "$disabled" "" "CYDER_COMPATDB=0 should disable runtime rule selection"

printf '../unsafe\n' >"$TMP/runtime/CompatDB/current"
fallback="$(
  CYDER_COMPATDB_ALLOW_UNSIGNED=1 \
  CYDER_RUNTIME_ROOT="$TMP/runtime" CYDER_SUPPORT="$TMP/support" bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_init_paths "$2"
    printf "%s\n" "${CYDER_COMPATDB_PATH:-}"
  ' _ "$ROOT" "$TMP/repo/scripts"
)"
assert_eq "$fallback" "$TMP/repo/compatdb/compiled/compatdb.cdb" \
  "an invalid update pointer should fail open to the bundled database"

wrong_hash="$(printf '0%.0s' {1..64})"
mkdir -p "$TMP/runtime/CompatDB/$wrong_hash"
cp "$ROOT/compatdb/compiled/compatdb.cdb" "$TMP/runtime/CompatDB/$wrong_hash/compatdb.cdb"
printf '%s\n' "$wrong_hash" >"$TMP/runtime/CompatDB/current"
hash_fallback="$(
  CYDER_COMPATDB_ALLOW_UNSIGNED=1 \
  CYDER_RUNTIME_ROOT="$TMP/runtime" CYDER_SUPPORT="$TMP/support" bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_init_paths "$2"
    printf "%s\n" "${CYDER_COMPATDB_PATH:-}"
  ' _ "$ROOT" "$TMP/repo/scripts"
)"
assert_eq "$hash_fallback" "$TMP/repo/compatdb/compiled/compatdb.cdb" \
  "a content-address mismatch should fail open to the bundled database"

ungated="$(
  CYDER_COMPATDB_PATH="$TMP/runtime/CompatDB/$hash/compatdb.cdb" \
  CYDER_RUNTIME_ROOT="$TMP/runtime" CYDER_SUPPORT="$TMP/support" bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_init_paths "$2"
    printf "%s\n" "${CYDER_COMPATDB_PATH:-}"
  ' _ "$ROOT" "$TMP/repo/scripts"
)"
assert_eq "$ungated" "$TMP/repo/compatdb/compiled/compatdb.cdb" \
  "an explicit unsigned database should require developer mode"

explicit="$(
  CYDER_COMPATDB_ALLOW_UNSIGNED=1 \
  CYDER_COMPATDB_SHA256="$hash" \
  CYDER_COMPATDB_PATH="$TMP/runtime/CompatDB/$hash/compatdb.cdb" \
  CYDER_RUNTIME_ROOT="$TMP/runtime" CYDER_SUPPORT="$TMP/support" bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_init_paths "$2"
    printf "%s\n" "${CYDER_COMPATDB_PATH:-}"
  ' _ "$ROOT" "$TMP/repo/scripts"
)"
assert_eq "$explicit" "$TMP/runtime/CompatDB/$hash/compatdb.cdb" \
  "an explicit unsigned database should require and verify its expected hash"

mkdir -p "$TMP/fresh-support"
fresh_pin="$(
  CYDER_RUNTIME_ROOT="$TMP/runtime" CYDER_SUPPORT="$TMP/fresh-support" bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_init_paths "$2"
    mkdir -p "$CYDER_PREFIX"
    cyder_configure_compatdb "$CYDER_PREFIX"
    cat "$CYDER_PREFIX/.cyder-runtime/compatdb.path"
  ' _ "$ROOT" "$TMP/repo/scripts"
)"
assert_contains "$fresh_pin" "kind=bundled" \
  "a prefix created after initialization should be pinned before its first launch"
assert_contains "$fresh_pin" "path=$TMP/repo/compatdb/compiled/compatdb.cdb" \
  "the fresh-prefix pin should retain the selected bundled database"

cat >"$TMP/support/bottles/shared/.cyder-runtime/compatdb.path" <<EOF
kind=unsigned
sha256=$hash
path=$TMP/runtime/CompatDB/$hash/compatdb.cdb
EOF
pin_without_gate="$(
  CYDER_RUNTIME_ROOT="$TMP/runtime" CYDER_SUPPORT="$TMP/support" bash -c '
    source "$1/scripts/cyder-common.sh"
    cyder_has_running_prefix() { return 0; }
    cyder_init_paths "$2"
    printf "%s\n" "${CYDER_COMPATDB_PATH:-}"
  ' _ "$ROOT" "$TMP/repo/scripts"
)"
assert_eq "$pin_without_gate" "$TMP/repo/compatdb/compiled/compatdb.cdb" \
  "an active unsigned pin should still require developer mode"

app="$(cat "$ROOT/scripts/cyder_app_main.swift")"
assert_contains "$app" 'configureCompatDBEnvironment(&environment' \
  "native launches should select the same CompatDB"
assert_contains "$app" 'appendingPathComponent("CompatDB", isDirectory: true)' \
  "native launches should support content-addressed updates and bundle fallback"
assert_contains "$app" 'compatDBSHA256(candidate) == digest' \
  "native session pins should be revalidated against their recorded digest"
assert_contains "$app" '.typeSocket' \
  "native wineserver detection should require a real Unix socket"

echo "PASS test-cyder-compatdb-integration"
