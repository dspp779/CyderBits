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

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/cyder-mvk-wait-poll-test.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/engine/lib/wine/x86_64-unix"

# Minimal fake "real" MoltenVK: empty dynamic lib is enough for layout tests of
# backup/.real detection; skip clang link if no SDK (CI without Xcode).
if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  echo "SKIP install round-trip (no macOS SDK); content checks OK"
  echo "PASS moltenvk wait-poll wiring"
  exit 0
fi

REAL_CANDIDATE=""
if [[ -f "$HOME/.cyder/runtime/Engines/wine-x86_64/lib/wine/x86_64-unix/libMoltenVK.real.dylib" ]]; then
  REAL_CANDIDATE="$HOME/.cyder/runtime/Engines/wine-x86_64/lib/wine/x86_64-unix/libMoltenVK.real.dylib"
elif [[ -f "$HOME/.cyder/runtime/Engines/wine-x86_64/lib/wine/x86_64-unix/libMoltenVK.dylib" ]] &&
     ! otool -L "$HOME/.cyder/runtime/Engines/wine-x86_64/lib/wine/x86_64-unix/libMoltenVK.dylib" |
       tail -n +3 | grep -q 'libMoltenVK.real.dylib'; then
  REAL_CANDIDATE="$HOME/.cyder/runtime/Engines/wine-x86_64/lib/wine/x86_64-unix/libMoltenVK.dylib"
fi

if [[ -z "$REAL_CANDIDATE" ]]; then
  echo "SKIP install round-trip (no local MoltenVK); content checks OK"
  echo "PASS moltenvk wait-poll wiring"
  exit 0
fi

cp -p "$REAL_CANDIDATE" "$STAGE/engine/lib/wine/x86_64-unix/libMoltenVK.dylib"
bash "$HELPER" --engine "$STAGE/engine"
[[ -f "$STAGE/engine/lib/wine/x86_64-unix/libMoltenVK.real.dylib" ]]
strings -a "$STAGE/engine/lib/wine/x86_64-unix/libMoltenVK.dylib" |
  grep -q 'cyder-moltenvk-timeline-wait-poll'
# Idempotent
bash "$HELPER" --engine "$STAGE/engine"
# Undo
bash "$HELPER" --engine "$STAGE/engine" --undo
[[ ! -f "$STAGE/engine/lib/wine/x86_64-unix/libMoltenVK.real.dylib" ]]
[[ -f "$STAGE/engine/lib/wine/x86_64-unix/libMoltenVK.dylib" ]]

echo "PASS moltenvk wait-poll install round-trip"
