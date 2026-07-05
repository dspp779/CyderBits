#!/usr/bin/env bash
set -euo pipefail

assert() {
  "$@" || { echo "ASSERT failed: $*" >&2; exit 1; }
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [[ "$actual" != "$expected" ]]; then
    echo "ASSERT_EQ failed: $message" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  if [[ "$haystack" != *"$needle"* ]]; then
    echo "ASSERT_CONTAINS failed: $message" >&2
    echo "  missing: $needle" >&2
    exit 1
  fi
}
