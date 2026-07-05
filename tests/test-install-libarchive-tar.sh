#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/drive_c/windows/syswow64"
bash "$ROOT/scripts/install-libarchive-tar.sh" --prefix "$TMP"
assert test -f "$TMP/drive_c/windows/syswow64/tar.exe"
assert test -f "$TMP/drive_c/windows/syswow64/libarchive2.dll"
echo "PASS test-install-libarchive-tar"
