#!/usr/bin/env bash
# Provision engine-owned native DXVK DLLs into a Wine prefix.
set -euo pipefail

PREFIX="${WINEPREFIX:-}"
ENGINE="${WINE_INSTALL:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    -h | --help)
      echo "Usage: $(basename "$0") --prefix PATH --engine PATH"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ "$PREFIX" == /* && -d "$PREFIX/drive_c/windows" ]] ||
  { echo "Invalid or uninitialized Wine prefix: $PREFIX" >&2; exit 1; }
[[ "$ENGINE" == /* ]] || { echo "Engine path must be absolute: $ENGINE" >&2; exit 1; }

MOLTENVK="$ENGINE/lib/wine/x86_64-unix/libMoltenVK.dylib"
if [[ ! -f "$MOLTENVK" ]]; then
  MOLTENVK="$ENGINE/lib64/libMoltenVK.dylib"
fi
[[ -f "$MOLTENVK" ]] || {
  echo "DXVK payload skipped: engine has no MoltenVK" >&2
  exit 0
}

installed=0
install_arch() {
  local machine="$1" windows_dir="$2"
  local source="$ENGINE/lib/dxvk/$machine"
  local module target temp
  [[ -d "$source" ]] || return 0
  mkdir -p "$windows_dir"
  for module in d3d11 dxgi; do
    [[ -f "$source/$module.dll" ]] || {
      echo "Incomplete DXVK payload: missing $source/$module.dll" >&2
      return 1
    }
    target="$windows_dir/$module.dll"
    temp="$windows_dir/.$module.dll.cyder-new-$$"
    cp "$source/$module.dll" "$temp"
    chmod 0644 "$temp"
    mv -f "$temp" "$target"
    installed=$((installed + 1))
  done
}

install_arch x86_64-windows "$PREFIX/drive_c/windows/system32"
install_arch i386-windows "$PREFIX/drive_c/windows/syswow64"

if (( installed )); then
  mkdir -p "$PREFIX/.cyder-runtime"
  {
    echo "backend=dxvk"
    echo "engine=$ENGINE"
    find "$ENGINE/lib/dxvk" -type f -name '*.dll' -exec shasum -a 256 {} \; |
      LC_ALL=C sort
  } >"$PREFIX/.cyder-runtime/dxvk-payload"
  echo "Provisioned $installed DXVK DLLs into $PREFIX" >&2
fi
