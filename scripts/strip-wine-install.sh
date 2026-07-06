#!/usr/bin/env bash
# Remove non-runtime files from a Wine install tree (zero-risk strip only).
# Does not prune PE DLLs — see prune-wine-pefiles.sh (future).
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] WINE_ROOT

Zero-risk removals:
  - include/
  - share/man/
  - bin/ dev tools (keeps wine, wine64, wineserver)
  - lib/**/*.a under lib/wine/*-windows/ (import libraries)

Environment:
  CYDER_SKIP_ENGINE_STRIP=1   no-op (for debugging)

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
  printf '==> stripped ~%s MB (%d paths touched)\n' "$saved_mb" "$removed"
else
  echo "==> done ($removed paths touched)"
fi
