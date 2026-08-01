#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/install-moltenvk-wait-poll-shim.sh"
SRC="$ROOT/tools/cyder-mvk-timeline-wait-poll/cyder_mvk_timeline_wait_poll.m"

[[ -f "$HELPER" ]] || {
  echo "FAIL missing $HELPER" >&2
  exit 1
}
[[ -f "$SRC" ]] || {
  echo "FAIL missing $SRC" >&2
  exit 1
}
rg -Fq 'cyder-moltenvk-timeline-wait-poll' "$SRC"
rg -Fq 'cyder_ensure_moltenvk_wait_poll_shim' "$ROOT/scripts/cyder-common.sh"
rg -Fq 'install-moltenvk-wait-poll-shim.sh' "$ROOT/scripts/create-cyder-app.sh"
rg -Fq 'moltenvk-wait-poll' "$ROOT/scripts/create-cyder-app.sh"
if rg -n 'xcrun|clang|otool|install_name_tool' "$HELPER"; then
  echo "FAIL runtime shim helper must not require Command Line Tools" >&2
  exit 1
fi
rg -Fq 'prebuilt shim missing' "$ROOT/scripts/cyder-common.sh"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/cyder-mvk-wait-poll-test.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/engine/lib/wine/x86_64-unix"

# Missing prebuilt shim must be a non-fatal no-op on an end-user machine.
printf 'fake-real-moltenvk\n' >"$STAGE/engine/lib/wine/x86_64-unix/libMoltenVK.dylib"
bash "$HELPER" --engine "$STAGE/engine"
[[ ! -f "$STAGE/engine/lib/wine/x86_64-unix/libMoltenVK.real.dylib" ]]

echo "PASS moltenvk wait-poll runtime wiring"

echo "PASS moltenvk wait-poll install round-trip"
