#!/usr/bin/env bash
# Prepare a Wine install tree for release packaging.
# Removes development-only files and DWARF sections from PE runtime modules.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] WINE_ROOT

Release cleanup:
  - include/
  - share/man/
  - bin/ dev tools (keeps wine, wine64, wineserver)
  - lib/**/*.a under lib/wine/*-windows/ (import libraries)
  - DWARF debug sections from PE modules (runtime data is preserved)

Environment:
  CYDER_SKIP_ENGINE_STRIP=1   no-op (for debugging)
  CYDER_KEEP_DEBUG_SYMBOLS=1  remove development files but retain DWARF
  CYDER_LLVM_STRIP=/path      explicitly select llvm-strip

Does not modify sources/ or the caller's WINE_INSTALL unless WINE_ROOT points there.
EOF
}

DRY_RUN=0
WINE_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      WINE_ROOT="$1"
      shift
      ;;
  esac
done

[[ -n "$WINE_ROOT" ]] || {
  usage >&2
  exit 1
}

WINE_ROOT="$(cd "$WINE_ROOT" && pwd)"

[[ -x "$WINE_ROOT/bin/wine" ]] || {
  echo "Not a Wine prefix root (missing bin/wine): $WINE_ROOT" >&2
  exit 1
}

if [[ "${CYDER_SKIP_ENGINE_STRIP:-}" == "1" ]]; then
  echo "CYDER_SKIP_ENGINE_STRIP=1 — skipping strip"
  exit 0
fi

# Runtime launchers only; everything else in bin/ is build/dev tooling.
STRIP_BIN_NAMES=(
  function_grep.pl
  widl
  winebuild
  winecpp
  winedump
  wineg++
  winegcc
  winemaker
  wmc
  wrc
)

bytes_before=0
if command -v du >/dev/null 2>&1; then
  bytes_before="$(du -sk "$WINE_ROOT" | awk '{print $1}')"
fi

removed=0
debug_stripped=0

rm_path() {
  local p="$1"
  [[ -e "$p" ]] || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if command -v du >/dev/null 2>&1; then
      du -sh "$p" 2>/dev/null || echo "would remove: $p"
    else
      echo "would remove: $p"
    fi
  else
    rm -rf "$p"
  fi
  removed=$((removed + 1))
}

echo "==> strip-wine-install ($([[ "$DRY_RUN" -eq 1 ]] && echo dry-run || echo apply)) -> $WINE_ROOT"

rm_path "$WINE_ROOT/include"
rm_path "$WINE_ROOT/share/man"

for name in "${STRIP_BIN_NAMES[@]}"; do
  rm_path "$WINE_ROOT/bin/$name"
done

# PE-tree import libraries (*.a) — never loaded at runtime.
while IFS= read -r -d '' f; do
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "would remove: $f"
  else
    rm -f "$f"
  fi
  removed=$((removed + 1))
done < <(find "$WINE_ROOT/lib" -name '*.a' -print0 2>/dev/null)

# Wine's PE modules are built with -g.  They work at runtime with DWARF present,
# but a single DLL may carry tens of MiB of compressible debug information.
# wineboot then copies those modules into every bottle, doubling the installed
# cost.  --strip-debug removes only .debug_* sections; PE resources, unwind
# tables, relocations and exports remain intact.  Packaging signs after this
# script runs, so changing the file here cannot invalidate the final signature.
find_llvm_tool() {
  local name="$1" candidate strip_dir
  if [[ -n "${CYDER_LLVM_STRIP:-}" ]]; then
    strip_dir="$(dirname "$CYDER_LLVM_STRIP")"
    candidate="$strip_dir/$name"
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  fi
  candidate="$(command -v "$name" 2>/dev/null || true)"
  [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  for candidate in "$SCRIPT_DIR"/../build/llvm-mingw-*/bin/"$name"; do
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

if [[ "${CYDER_KEEP_DEBUG_SYMBOLS:-}" != "1" ]]; then
  llvm_strip="$(find_llvm_tool llvm-strip 2>/dev/null || true)"
  llvm_objdump="$(find_llvm_tool llvm-objdump 2>/dev/null || true)"
  if [[ -n "$llvm_strip" && -n "$llvm_objdump" ]]; then
    while IFS= read -r -d '' f; do
      # Inspect before modifying so an already stripped OEM engine remains
      # byte-for-byte untouched (and keeps any existing code signature).
      if "$llvm_objdump" -h "$f" 2>/dev/null | grep -qE '[[:space:]]\.debug_'; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
          echo "would strip DWARF: $f"
        else
          "$llvm_strip" --strip-debug "$f"
        fi
        debug_stripped=$((debug_stripped + 1))
      fi
    # Do not filter by extension: Wine also ships PE .sys, .drv, .ocx, .cpl,
    # .acm, .ax and legacy .exe16 modules with the same DWARF sections.
    done < <(find "$WINE_ROOT/lib/wine" -path '*-windows/*' -type f -print0 2>/dev/null)
  else
    echo "Warning: llvm-strip/llvm-objdump unavailable; retaining PE debug symbols" >&2
  fi
fi

for keep in wine wine64 wineserver; do
  [[ -e "$WINE_ROOT/bin/$keep" ]] || continue
  if [[ ! -x "$WINE_ROOT/bin/$keep" ]]; then
    echo "Warning: expected runtime binary not executable: $WINE_ROOT/bin/$keep" >&2
  fi
done

if [[ "$DRY_RUN" -eq 0 ]]; then
  [[ -x "$WINE_ROOT/bin/wine" ]] || {
    echo "strip-wine-install: bin/wine missing after strip" >&2
    exit 1
  }
fi

if command -v du >/dev/null 2>&1 && [[ "$bytes_before" -gt 0 ]]; then
  bytes_after="$(du -sk "$WINE_ROOT" | awk '{print $1}')"
  saved_kb=$((bytes_before - bytes_after))
  saved_mb="$(awk -v k="$saved_kb" 'BEGIN { printf "%.1f", k / 1024 }')"
  printf '==> stripped ~%s MB (%d paths removed, %d PE modules debug-stripped)\n' \
    "$saved_mb" "$removed" "$debug_stripped"
else
  echo "==> done ($removed paths removed, $debug_stripped PE modules debug-stripped)"
fi
