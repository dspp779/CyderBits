#!/usr/bin/env bash
# Provision engine-owned DXMT PE DLLs into a Wine prefix.
#
# Wine only loads builtins from prepended dll paths after a matching file exists
# in the prefix (find_builtin_without_file is bootstrap/16-bit only). DXMT's
# d3d11/dxgi import winemetal.dll, which wineboot never places in system32 —
# without this provisioner, DXMT activates then exits STATUS_DLL_NOT_FOUND (53).
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

[[ -f "$ENGINE/lib/dxmt/x86_64-unix/winemetal.so" ]] || {
  echo "DXMT payload skipped: engine has no lib/dxmt/x86_64-unix/winemetal.so" >&2
  exit 0
}

installed=0
install_arch() {
  local machine="$1" windows_dir="$2"
  local source="$ENGINE/lib/dxmt/$machine"
  local module target temp
  # Core DXMT stack (+ winemetal, which has no wineboot placeholder).
  local modules=(d3d10core d3d11 dxgi winemetal)
  [[ -d "$source" ]] || return 0
  mkdir -p "$windows_dir"
  for module in "${modules[@]}"; do
    [[ -f "$source/$module.dll" ]] || {
      echo "Incomplete DXMT payload: missing $source/$module.dll" >&2
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
    echo "backend=dxmt"
    echo "engine=$ENGINE"
    find "$ENGINE/lib/dxmt" -type f \( -name '*.dll' -o -name 'winemetal.so' \) \
      -exec shasum -a 256 {} \; | LC_ALL=C sort
  } >"$PREFIX/.cyder-runtime/dxmt-payload"
  echo "Provisioned $installed DXMT DLLs into $PREFIX" >&2
fi
