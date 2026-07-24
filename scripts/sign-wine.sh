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

# Default stays ad-hoc: this script also re-signs the installed engine on end-user
# machines (cyder_sign_installed_engine), where no Developer ID cert exists.
# Release builds export SIGN_IDENTITY="Developer ID Application: ..." instead.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
# Ad-hoc signatures cannot carry a secure timestamp; Developer ID ones must
# (notarization rejects unstamped signatures).
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  TIMESTAMP_FLAG="--timestamp=none"
else
  TIMESTAMP_FLAG="--timestamp"
fi

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
    run "$CODESIGN_CMD" --force --sign "$SIGN_IDENTITY" "$TIMESTAMP_FLAG" \
      --entitlements "$ENTITLEMENTS" \
      --options runtime \
      "$path"
  fi
done < <(find "$TARGET_ROOT" -type f -print0)

verify_target="$TARGET_ROOT/bin/wine"
if ! "$FILE_CMD" -b "$verify_target" | grep -q 'Mach-O'; then
  # CodeWeavers OEM runtimes use a Perl/shell `bin/wine` frontend and keep the
  # signed native entry point in `bin/wineloader`.
  verify_target="$TARGET_ROOT/bin/wineloader"
fi
[[ -f "$verify_target" ]] || {
  echo "No Mach-O Wine entry point available for signature verification" >&2
  exit 1
}
run "$CODESIGN_CMD" --verify --deep --strict --verbose=2 "$verify_target"
