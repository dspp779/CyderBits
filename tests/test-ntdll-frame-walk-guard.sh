#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/ntdll-frame-walk-guard.c"
LLVM_MINGW="${FRAME_WALK_LLVM_MINGW:-$ROOT/build/llvm-mingw-20260616-ucrt-macos-universal}"
WINE_RUNTIME="${FRAME_WALK_WINE_RUNTIME:-$ROOT/install/wine-cx26-x86_64}"
CC="$LLVM_MINGW/bin/x86_64-w64-mingw32-clang"
WINE="$WINE_RUNTIME/bin/wine"

if [[ ! -x "$CC" ]]; then
  echo "SKIP ntdll frame-walk guard: compiler not found at $CC"
  exit 0
fi
if [[ ! -x "$WINE" ]]; then
  echo "SKIP ntdll frame-walk guard: Wine runtime not found at $WINE"
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cyder-frame-walk.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

"$CC" -O2 -Wall -Wextra -Werror \
  "$FIXTURE" -o "$TMP_DIR/ntdll-frame-walk-guard.exe"

env \
  WINEPREFIX="$TMP_DIR/prefix" \
  WINEDEBUG=-all \
  WINEDLLOVERRIDES=mscoree,mshtml= \
  arch -x86_64 "$WINE" "$TMP_DIR/ntdll-frame-walk-guard.exe"
