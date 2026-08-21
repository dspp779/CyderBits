#!/usr/bin/env bash
# Install the pinned Wine Gecko runtime into one WINEPREFIX.
set -Eeuo pipefail

DOWNLOAD_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --download-only)
      DOWNLOAD_ONLY=1
      shift
      ;;
    -h | --help)
      cat <<'EOF'
Usage: install-wine-gecko.sh [--download-only]

Downloads and verifies the pinned Wine Gecko MSIs. Without --download-only,
installs them into WINEPREFIX via msiexec.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cyder-download-locked.sh
source "$SCRIPT_DIR/cyder-download-locked.sh"

GECKO_VER="${WINE_GECKO_VERSION:-2.47.4}"
DOWNLOADS="${CYDER_DOWNLOADS:-$HOME/Library/Application Support/Cyder/downloads}"

case "$GECKO_VER" in
  2.47.4)
    X86_SHA256="26cecc47706b091908f7f814bddb074c61beb8063318e9efc5a7f789857793d6"
    X64_SHA256="e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f"
    ;;
  *)
    echo "Unsupported Wine Gecko version: $GECKO_VER" >&2
    exit 2
    ;;
esac

download_and_verify() {
  local arch_name="$1" expected="$2"
  local filename="wine-gecko-${GECKO_VER}-${arch_name}.msi"
  local destination="$DOWNLOADS/$filename"
  local url="https://dl.winehq.org/wine/wine-gecko/${GECKO_VER}/$filename"
  cyder_download_locked "$destination" "$url" "$expected" || return $?
  printf '%s\n' "$destination"
}

mkdir -p "$DOWNLOADS"
x86_msi="$(download_and_verify x86 "$X86_SHA256")"
x64_msi="$(download_and_verify x86_64 "$X64_SHA256")"

if [[ "$DOWNLOAD_ONLY" -eq 1 ]]; then
  echo "Wine Gecko ${GECKO_VER} downloads ready:"
  echo "  $x86_msi"
  echo "  $x64_msi"
  exit 0
fi

WINE_INSTALL="${WINE_INSTALL:?WINE_INSTALL not set}"
WINEPREFIX="${WINEPREFIX:?WINEPREFIX not set}"

export WINEPREFIX
for installer in "$x86_msi" "$x64_msi"; do
  echo "Installing $installer into WINEPREFIX=$WINEPREFIX" >&2
  /usr/bin/arch -x86_64 "$WINE_INSTALL/bin/wine" msiexec /i "$installer" /qn
done
printf 'version=%s\nx86_sha256=%s\nx86_64_sha256=%s\n' \
  "$GECKO_VER" "$X86_SHA256" "$X64_SHA256" >"$WINEPREFIX/.cyder-gecko-$GECKO_VER"
echo "Wine Gecko $GECKO_VER installed." >&2
