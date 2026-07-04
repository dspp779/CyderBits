#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

TARGET_ROOT="$WINE_INSTALL"
ENTITLEMENTS="$ENTITLEMENTS_PLIST"
DRY_RUN=0
FILE_CMD="${FILE_CMD:-file}"
CODESIGN_CMD="${CODESIGN_CMD:-codesign}"
XATTR_CMD="${XATTR_CMD:-xattr}"

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      TARGET_ROOT="$2"
      shift
      ;;
    --entitlements)
      ENTITLEMENTS="$2"
      shift
      ;;
    --dry-run) DRY_RUN=1 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

[[ -d "$TARGET_ROOT" ]] || { echo "Missing install root: $TARGET_ROOT" >&2; exit 1; }
[[ -f "$ENTITLEMENTS" ]] || { echo "Missing entitlements file: $ENTITLEMENTS" >&2; exit 1; }

# Clear quarantine only on regular files. Do not follow symlinks into .brew-x86
# (runtime lib links); xattr -cr would try to mutate those and fail with EACCES.
while IFS= read -r -d '' path; do
  run "$XATTR_CMD" -c "$path" || true
done < <(find "$TARGET_ROOT" -type f -print0)

# Sign only regular Mach-O files (skip symlinks to Homebrew dylibs).
while IFS= read -r -d '' path; do
  if "$FILE_CMD" -b "$path" | grep -q 'Mach-O'; then
    run "$CODESIGN_CMD" --force --sign - \
      --entitlements "$ENTITLEMENTS" \
      --options runtime \
      "$path"
  fi
done < <(find "$TARGET_ROOT" -type f -print0)

run "$CODESIGN_CMD" --verify --deep --strict --verbose=2 "$TARGET_ROOT/bin/wine"
