#!/usr/bin/env bash
# Restore Wine built-in graphics DLLs after legacy Cyder prefix provisioning.
set -euo pipefail

cyder_graphics_sha256() {
  /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
}

cyder_prefix_has_legacy_graphics_payload() {
  local prefix="$1" engine="$2"
  local prefix_d3d11 candidate prefix_sha

  [[ -e "$prefix/.cyder-runtime/dxvk-payload" ||
     -e "$prefix/.cyder-runtime/dxmt-payload" ]] && return 0

  prefix_d3d11="$prefix/drive_c/windows/system32/d3d11.dll"
  [[ -f "$prefix_d3d11" ]] || return 1
  prefix_sha="$(cyder_graphics_sha256 "$prefix_d3d11")"
  for candidate in \
    "$engine/lib/dxvk/x86_64-windows/d3d11.dll" \
    "$engine/lib/dxmt/x86_64-windows/d3d11.dll"; do
    [[ -f "$candidate" ]] || continue
    [[ "$prefix_sha" == "$(cyder_graphics_sha256 "$candidate")" ]] && return 0
  done
  return 1
}

cyder_restore_wine_graphics_module() {
  local source="$1" destination="$2"
  local temporary

  [[ -f "$source" ]] || {
    echo "Skipping missing Wine built-in graphics module: $source" >&2
    return 0
  }
  mkdir -p "$(dirname "$destination")"
  temporary="$(mktemp "$(dirname "$destination")/.${destination##*/}.XXXXXX")"
  cp "$source" "$temporary"
  mv -f "$temporary" "$destination"
}

cyder_migrate_graphics_prefix() {
  local wine_bin="$1" engine="$2" prefix="$3"
  local arch prefix_dir module
  local -a modules=(d3d9 d3d10 d3d10_1 d3d10core d3d11 dxgi)
  local -a arches=(x86_64 i386)

  # wine_bin is part of the public interface and identifies the selected engine.
  [[ -n "$wine_bin" && -d "$engine" && -d "$prefix" ]] || return 0
  cyder_prefix_has_legacy_graphics_payload "$prefix" "$engine" || return 0

  for arch in "${arches[@]}"; do
    if [[ "$arch" == x86_64 ]]; then
      prefix_dir="$prefix/drive_c/windows/system32"
    else
      prefix_dir="$prefix/drive_c/windows/syswow64"
    fi
    for module in "${modules[@]}"; do
      cyder_restore_wine_graphics_module \
        "$engine/lib/wine/$arch-windows/$module.dll" \
        "$prefix_dir/$module.dll"
    done
  done
  rm -f \
    "$prefix/.cyder-runtime/dxvk-payload" \
    "$prefix/.cyder-runtime/dxmt-payload"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  wine_bin="${1:-${WINE_INSTALL:-}/bin/wine}"
  engine="${2:-${WINE_INSTALL:-}}"
  prefix="${3:-${WINEPREFIX:-}}"
  cyder_migrate_graphics_prefix "$wine_bin" "$engine" "$prefix"
fi
