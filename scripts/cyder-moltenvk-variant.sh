#!/usr/bin/env bash
# Resolve and apply dual-variant MoltenVK (.real symlink) for Cyder012+.
# shellcheck shell=bash
set -euo pipefail

_CYDER_MVK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_CYDER_MVK_DIR/cyder-macos-compat.sh" ]]; then
  # shellcheck source=cyder-macos-compat.sh
  source "$_CYDER_MVK_DIR/cyder-macos-compat.sh"
fi
unset _CYDER_MVK_DIR

# Prints a candidate only; version names never prove host compatibility.
cyder_resolve_moltenvk_variant() {
  local pref="${1:?}"
  case "$pref" in
    1.4.2 | 1.2.10) ;;
    *)
      echo "invalid moltenvk variant: $pref" >&2
      return 2
      ;;
  esac
  if ! cyder_macos_at_least 12 0; then
    printf '1.2.10\n'
    return 0
  fi
  printf '%s\n' "$pref"
}

cyder_moltenvk_unix_lib() {
  local engine="${1:?}"
  printf '%s\n' "$engine/lib/wine/x86_64-unix"
}

# True when the engine ships the Cyder012+ dual layout.
cyder_engine_has_moltenvk_dual_variant() {
  local unix
  unix="$(cyder_moltenvk_unix_lib "${1:?}")"
  [[ -f "$unix/libMoltenVK-1.4.2.dylib" && -f "$unix/libMoltenVK-1.2.10.dylib" && -f "$unix/libMoltenVK.dylib" ]]
}

# sets lib/wine/x86_64-unix/libMoltenVK.real.dylib -> libMoltenVK-$resolved.dylib
cyder_apply_moltenvk_variant() {
  local engine="${1:?}" pref="${2:?}" unix resolved target
  unix="$(cyder_moltenvk_unix_lib "$engine")"
  resolved="$(cyder_resolve_moltenvk_variant "$pref")"
  target="libMoltenVK-${resolved}.dylib"
  [[ -f "$unix/$target" ]] || {
    echo "missing $unix/$target" >&2
    return 1
  }
  [[ -f "$unix/libMoltenVK.dylib" ]] || {
    echo "missing $unix/libMoltenVK.dylib" >&2
    return 1
  }
  strings "$unix/libMoltenVK.dylib" | grep -Fq 'cyder-moltenvk-timeline-wait-poll' || {
    echo "libMoltenVK.dylib is not the wait-poll shim" >&2
    return 1
  }
  if ! otool -L "$unix/libMoltenVK.dylib" | grep -Fq '@loader_path/libMoltenVK.real.dylib'; then
    echo "libMoltenVK.dylib does not re-export libMoltenVK.real.dylib" >&2
    return 1
  fi
  # Refuse double-shim: non-symlink .real must not itself re-export .real.
  if [[ -f "$unix/libMoltenVK.real.dylib" ]] && ! [[ -L "$unix/libMoltenVK.real.dylib" ]]; then
    if otool -L "$unix/libMoltenVK.real.dylib" | grep -Fq '@loader_path/libMoltenVK.real.dylib'; then
      echo "libMoltenVK.real.dylib looks like a shim (double-shim)" >&2
      return 1
    fi
  fi
  if [[ -L "$unix/libMoltenVK.real.dylib" && "$(readlink "$unix/libMoltenVK.real.dylib")" == "$target" ]]; then
    return 0
  fi
  if [[ -n "${CYDER_EXECUTION_RUNTIME_MUTATION:-}${CYDER_EXECUTION_OWNER_TICKET:-}" && "${CYDER_EXECUTION_RUNTIME_MUTATION:-0}" != 1 ]]; then
    echo "Shared MoltenVK configuration changed; retry the launch to acquire its global operation scope." >&2
    return 75
  fi
  ln -sfn "$target" "$unix/libMoltenVK.real.dylib"
}

# Soft apply: no-op on single-dylib engines (Cyder011 and earlier).
cyder_apply_moltenvk_variant_if_present() {
  local engine="${1:?}" pref="${2:?}"
  if ! cyder_engine_has_moltenvk_dual_variant "$engine"; then
    return 0
  fi
  cyder_apply_moltenvk_variant "$engine" "$pref"
}

cyder_default_moltenvk_variant_preference() {
  if cyder_macos_at_least 12 0; then
    printf '1.4.2\n'
  else
    printf '1.2.10\n'
  fi
}

# Inspect the Wine process slice, including older LC_VERSION_MIN_MACOSX dylibs.
# Fail closed when the file/slice/load command cannot be inspected.
cyder_moltenvk_check_minos() {
  local dylib="${1:?}" headers required host
  headers="$(otool -arch x86_64 -l "$dylib" 2>/dev/null)" || headers=""
  required="$(printf '%s\n' "$headers" | awk '
    $1 == "cmd" { legacy = ($2 == "LC_VERSION_MIN_MACOSX") }
    $1 == "minos" || (legacy && $1 == "version") { print $2; exit }
  ')"
  if [[ ! "$required" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "DXVK/Vulkan blocked: cannot determine x86_64 Mach-O minOS: $dylib" >&2
    return 1
  fi
  host="$(cyder_macos_product_version)"
  if ! awk -v host="$host" -v need="$required" 'BEGIN {
    split(host,h,"."); split(need,n,".");
    for (i=1;i<=3;i++) { if (h[i]+0 > n[i]+0) exit 0; if (h[i]+0 < n[i]+0) exit 1 }
    exit 0
  }'; then
    echo "DXVK/Vulkan blocked: macOS $host; $dylib requires macOS $required. Choose a compatible engine or another graphics backend." >&2
    return 1
  fi
}

# Call after backend resolution, before spawning Wine. Installation/preference
# maintenance may still select a real on a host using WineD3D or D3DMetal.
cyder_validate_moltenvk_for_backend() {
  local engine="${1:?}" backend="${2:-default}" unix shim real
  [[ "$backend" == dxvk ]] || return 0
  unix="$(cyder_moltenvk_unix_lib "$engine")"
  shim="$unix/libMoltenVK.dylib"
  if [[ ! -e "$shim" && ! -L "$shim" ]]; then
    shim="$engine/lib64/libMoltenVK.dylib"
  fi
  cyder_moltenvk_check_minos "$shim" || return $?
  real="${shim%/*}/libMoltenVK.real.dylib"
  # Old single-dylib engines have no .real. A shim must have a readable real.
  if [[ -e "$real" || -L "$real" ]] ||
     otool -L "$shim" 2>/dev/null | grep -Fq '@loader_path/libMoltenVK.real.dylib'; then
    cyder_moltenvk_check_minos "$real" || return $?
  fi
}

# CLI for Swift / manual use.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    resolve)
      cyder_resolve_moltenvk_variant "${2:?}"
      ;;
    apply)
      cyder_apply_moltenvk_variant "${2:?}" "${3:?}"
      ;;
    apply-if-present)
      cyder_apply_moltenvk_variant_if_present "${2:?}" "${3:?}"
      ;;
    *)
      echo "Usage: $0 resolve|apply|apply-if-present …" >&2
      exit 2
      ;;
  esac
fi
