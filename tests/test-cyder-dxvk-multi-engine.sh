#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

E1="${CYDER_DXVK_ENGINE1:-/Users/jjc/ogom/install/wine-maplestory-oem25-source-x86_64}"
E2="${CYDER_DXVK_ENGINE2:-/Users/jjc/ogom/install/wine-cx26-x86_64}"

output="$(bash "$ROOT/scripts/build-dxvk.sh" \
  --engine "$E1" \
  --also-engine "$E2" \
  --dry-run 2>&1)"
assert_contains "$output" "$E2/lib/dxvk" \
  "dry-run should install DXVK into --also-engine target"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cyder-dxvk-multi.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PRIMARY="$TMP/primary-engine"
SECONDARY="$TMP/secondary-engine"

for engine in "$PRIMARY" "$SECONDARY"; do
  mkdir -p \
    "$engine/lib/dxvk/x86_64-windows" \
    "$engine/lib/dxvk/i386-windows"
done
for machine in x86_64-windows i386-windows; do
  for module in d3d11 dxgi; do
    printf 'shared-%s-%s\n' "$machine" "$module" \
      >"$PRIMARY/lib/dxvk/$machine/$module.dll"
  done
done
printf 'license\n' >"$PRIMARY/lib/dxvk/LICENSE"
printf 'conf\n' >"$PRIMARY/lib/dxvk/dxvk.conf"

bash "$ROOT/scripts/build-dxvk.sh" \
  --copy-only \
  --engine "$PRIMARY" \
  --also-engine "$SECONDARY"

for machine in x86_64-windows i386-windows; do
  for module in d3d11 dxgi; do
    assert test -f "$SECONDARY/lib/dxvk/$machine/$module.dll"
    h1="$(shasum -a 256 "$PRIMARY/lib/dxvk/$machine/$module.dll" | awk '{print $1}')"
    h2="$(shasum -a 256 "$SECONDARY/lib/dxvk/$machine/$module.dll" | awk '{print $1}')"
    assert_eq "$h1" "$h2" "$machine/$module.dll hashes must match after copy-only"
  done
done

if [[ -f "$E1/lib/dxvk/x86_64-windows/d3d11.dll" &&
      -f "$E2/lib/dxvk/x86_64-windows/d3d11.dll" ]]; then
  for machine in x86_64-windows i386-windows; do
    for module in d3d11 dxgi; do
      h1="$(shasum -a 256 "$E1/lib/dxvk/$machine/$module.dll" | awk '{print $1}')"
      h2="$(shasum -a 256 "$E2/lib/dxvk/$machine/$module.dll" | awk '{print $1}')"
      assert_eq "$h1" "$h2" "installed engines must share $machine/$module.dll"
    done
  done
else
  echo "SKIP hash check: one or both install engines lack lib/dxvk (run build-dxvk.sh first)"
fi

echo "PASS test-cyder-dxvk-multi-engine"
