#!/usr/bin/env bash
# Install selected bundled Winetricks verbs into Cyder's shared Wine prefix.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cyder-common.sh
source "$SCRIPT_DIR/cyder-common.sh"

if cyder_resources_has_bundled_engine "$(dirname "$SCRIPT_DIR")"; then
  cyder_init_paths "$(dirname "$SCRIPT_DIR")"
else
  cyder_init_paths "$SCRIPT_DIR"
fi

engine="$CYDER_ENGINES/$CYDER_ENGINE_NAME"
wine="$engine/bin/wine"
wineserver="$engine/bin/wineserver"
prefix="$CYDER_SHARED_PREFIX"
winetricks="$CYDER_SCRIPTS/winetricks"
cache="$CYDER_DOWNLOADS/winetricks"

[[ -x "$wine" ]] || {
  echo "Cyder Wine engine is not ready: $wine" >&2
  exit 2
}
[[ -x "$wineserver" ]] || {
  echo "Cyder wineserver is not ready: $wineserver" >&2
  exit 2
}
[[ -x "$winetricks" ]] || {
  echo "Bundled Winetricks is missing: $winetricks" >&2
  exit 2
}
[[ -f "$prefix/system.reg" ]] || {
  echo "Cyder shared prefix is not initialized: $prefix" >&2
  exit 2
}

# Winetricks edits the prefix registry and DLLs. Never attach it to a live
# wineserver; doing so can leave a half-applied component behind.
if cyder_has_running_prefix "$prefix"; then
  echo "Cannot open Winetricks while the shared prefix is running: $prefix" >&2
  echo "Close all Cyder games and try again." >&2
  exit 75
fi

mkdir -p "$cache"
cyder_wine_locale_exports
export WINEPREFIX="$prefix"
export WINE="$wine"
export WINESERVER="$wineserver"
export W_CACHE="$cache"
export CYDER_WINETRICKS="$winetricks"
unset WINEARCH WINEDLLOVERRIDES

extra_bin=""
if cabextract_bin="$(cyder_find_cabextract 2>/dev/null || true)" && [[ -n "$cabextract_bin" ]]; then
  extra_bin="$(dirname "$cabextract_bin")"
fi
if zstd_bin="$(cyder_find_zstd 2>/dev/null || true)" && [[ -n "$zstd_bin" ]]; then
  if [[ -n "$extra_bin" ]]; then
    extra_bin="$extra_bin:$(dirname "$zstd_bin")"
  else
    extra_bin="$(dirname "$zstd_bin")"
  fi
fi

export PATH="${extra_bin:+$extra_bin:}/opt/homebrew/bin:/usr/local/bin:$PATH"


[[ "${1:-}" == install ]] || {
  echo "Winetricks is controlled by Cyder's native component picker." >&2
  echo "Usage: $(basename "$0") install VERB [...]" >&2
  exit 64
}
shift
[[ $# -gt 0 ]] || {
  echo "At least one Winetricks component is required." >&2
  exit 64
}

for verb in "$@"; do
  case "$verb" in
    vcrun2005|vcrun2008|vcrun2010|vcrun2012|vcrun2013|vcrun2015|vcrun2019|vcrun2022|dotnet20|dotnet35|dotnet40|dotnet452|dotnet48|dotnetdesktop6|dotnetdesktop7|dotnetdesktop8|dotnetdesktop9|wmp9|quartz|devenum|vb6run|steam)
      ;;
    *)
      echo "Unsupported Winetricks component: $verb" >&2
      exit 64
      ;;
  esac
done

echo "Installing Winetricks components into shared prefix: $prefix" >&2
exec /usr/bin/arch -x86_64 /bin/sh "$winetricks" --unattended "$@"
