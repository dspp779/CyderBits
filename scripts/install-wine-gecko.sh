#!/usr/bin/env bash
# Install the pinned Wine Gecko runtime into one WINEPREFIX.
set -Eeuo pipefail

WINE_INSTALL="${WINE_INSTALL:?WINE_INSTALL not set}"
WINEPREFIX="${WINEPREFIX:?WINEPREFIX not set}"
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

verify_file() {
  local path="$1" expected="$2" actual
  [[ -f "$path" ]] || return 1
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]]
}

download_and_verify() {
  local arch_name="$1" expected="$2"
  local filename="wine-gecko-${GECKO_VER}-${arch_name}.msi"
  local destination="$DOWNLOADS/$filename"
  local url="https://dl.winehq.org/wine/wine-gecko/${GECKO_VER}/$filename"
  if ! verify_file "$destination" "$expected"; then
    rm -f "$destination"
    echo "Downloading $url" >&2
    curl -fL --progress-bar -o "$destination.part" "$url"
    mv -f "$destination.part" "$destination"
  fi
  verify_file "$destination" "$expected" || {
    echo "Wine Gecko checksum verification failed: $destination" >&2
    rm -f "$destination"
    return 1
  }
  printf '%s\n' "$destination"
}

mkdir -p "$DOWNLOADS"
x86_msi="$(download_and_verify x86 "$X86_SHA256")"
x64_msi="$(download_and_verify x86_64 "$X64_SHA256")"

export WINEPREFIX
for installer in "$x86_msi" "$x64_msi"; do
  echo "Installing $installer into WINEPREFIX=$WINEPREFIX" >&2
  /usr/bin/arch -x86_64 "$WINE_INSTALL/bin/wine" msiexec /i "$installer" /qn
done
printf 'version=%s\nx86_sha256=%s\nx86_64_sha256=%s\n' \
  "$GECKO_VER" "$X86_SHA256" "$X64_SHA256" >"$WINEPREFIX/.cyder-gecko-$GECKO_VER"
echo "Wine Gecko $GECKO_VER installed." >&2
