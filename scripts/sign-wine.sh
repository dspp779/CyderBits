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

has_developer_id_authority() {
  local path="$1"
  local output=""
  # Prefer bash matching over PATH grep (env-x86_64 may put non-system tools first).
  output="$("$CODESIGN_CMD" -dv --verbose=4 "$path" 2>&1)" || true
  [[ "$output" == *"Authority=Developer ID Application:"* ]]
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

# Resolve verification entry early so ad-hoc mode can preserve Developer ID.
verify_target="$TARGET_ROOT/bin/wine"
if [[ ! -f "$verify_target" ]] || ! "$FILE_CMD" -b "$verify_target" | grep -q 'Mach-O'; then
  # CodeWeavers OEM runtimes use a Perl/shell `bin/wine` frontend and keep the
  # signed native entry point in `bin/wineloader`.
  verify_target="$TARGET_ROOT/bin/wineloader"
fi

# Clear quarantine only on regular files. Do not follow symlinks into .brew-x86
# (runtime lib links); xattr -cr would try to mutate those and fail with EACCES.
while IFS= read -r -d '' path; do
  run "$XATTR_CMD" -c "$path" || true
done < <(find "$TARGET_ROOT" -type f -print0)

# Ad-hoc default must not overwrite an already Developer ID–signed engine.
if [[ "$SIGN_IDENTITY" == "-" ]] && [[ -f "$verify_target" ]] && has_developer_id_authority "$verify_target"; then
  echo "Preserving Developer ID signatures under $TARGET_ROOT (skipping ad-hoc re-sign)"
  run "$CODESIGN_CMD" --verify --deep --strict --verbose=2 "$verify_target"
  exit 0
fi

# Sign only regular Mach-O files (skip symlinks to Homebrew dylibs).
macho_files=()
while IFS= read -r -d '' path; do
  if "$FILE_CMD" -b "$path" | grep -q 'Mach-O'; then
    macho_files+=("$path")
    run "$CODESIGN_CMD" --force --sign "$SIGN_IDENTITY" "$TIMESTAMP_FLAG" \
      --entitlements "$ENTITLEMENTS" \
      --options runtime \
      "$path"
  fi
done < <(find "$TARGET_ROOT" -type f -print0)

# Replacing some pre-existing Wine/CrossOver Mach-O signature slots can yield a
# CMS blob that verifies in the staging tree but is unusable after archival.
# A second Developer ID pass stabilizes the embedded signature before packing.
if [[ "$DRY_RUN" -eq 0 && "$SIGN_IDENTITY" != "-" ]]; then
  for path in "${macho_files[@]}"; do
    "$CODESIGN_CMD" --force --sign "$SIGN_IDENTITY" "$TIMESTAMP_FLAG" \
      --entitlements "$ENTITLEMENTS" \
      --options runtime \
      "$path"
  done
fi

# Verify every signed Mach-O, not only the Wine entry point. Developer ID
# timestamping can occasionally leave an individual file with an unusable CMS
# signature even though codesign returned success. Retry that file once, then
# fail closed if strict verification still does not pass.
if [[ "$DRY_RUN" -eq 0 ]]; then
  for path in "${macho_files[@]}"; do
    if ! "$CODESIGN_CMD" --verify --strict "$path"; then
      echo "Retrying invalid signature: $path" >&2
      "$CODESIGN_CMD" --force --sign "$SIGN_IDENTITY" "$TIMESTAMP_FLAG" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        "$path"
    fi
    "$CODESIGN_CMD" --verify --strict "$path"
  done
fi

[[ -f "$verify_target" ]] || {
  echo "No Mach-O Wine entry point available for signature verification" >&2
  exit 1
}
run "$CODESIGN_CMD" --verify --deep --strict --verbose=2 "$verify_target"
