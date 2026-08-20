#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DOWNLOADS="$TMP/downloads"
mkdir -p "$DOWNLOADS"

for addon in \
  wine-mono-10.4.1-x86.msi \
  wine-gecko-2.47.4-x86.msi \
  wine-gecko-2.47.4-x86_64.msi; do
  [[ -f "$ROOT/downloads/$addon" ]] || {
    echo "SKIP: missing downloads/$addon (run prefetch once on a networked machine)" >&2
    exit 0
  }
  cp "$ROOT/downloads/$addon" "$DOWNLOADS/"
done

set +e
prefetch_out="$(
  CYDER_DOWNLOADS="$DOWNLOADS" \
    bash "$ROOT/scripts/cyder-prefetch-bootstrap-msi.sh" 2>&1
)"
prefetch_status=$?
set -e
assert_eq "$prefetch_status" "0" "prefetch script should succeed with cached MSIs"
assert_contains "$prefetch_out" "Wine Mono" \
  "prefetch should report Mono status"
assert_contains "$prefetch_out" "Wine Gecko" \
  "prefetch should report Gecko status"

mono_sha="$(shasum -a 256 "$DOWNLOADS/wine-mono-10.4.1-x86.msi" | awk '{print $1}')"
assert_eq "$mono_sha" "071f4b2887e1c97a11d791ff3d65be9429eed6dec4c2708888bfd546ba358e23" \
  "prefetch must keep the pinned Wine Mono checksum"

set +e
mono_only_out="$(
  CYDER_DOWNLOADS="$DOWNLOADS" \
    bash "$ROOT/scripts/install-wine-mono.sh" --download-only 2>&1
)"
mono_only_status=$?
set -e
assert_eq "$mono_only_status" "0" "Mono download-only must succeed when MSI is cached"
assert_not_contains "$mono_only_out" "msiexec" \
  "Mono download-only must not invoke Wine"

set +e
gecko_only_out="$(
  CYDER_DOWNLOADS="$DOWNLOADS" \
    bash "$ROOT/scripts/install-wine-gecko.sh" --download-only 2>&1
)"
gecko_only_status=$?
set -e
assert_eq "$gecko_only_status" "0" "Gecko download-only must succeed when MSIs are cached"
assert_not_contains "$gecko_only_out" "msiexec" \
  "Gecko download-only must not invoke Wine"

echo "PASS test-cyder-prefetch-bootstrap-msi"
