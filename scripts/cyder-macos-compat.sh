#!/usr/bin/env bash
# macOS version checks and optional MoltenVK/Vulkan floor handling.
# shellcheck shell=bash

cyder_macos_product_version() {
  /usr/bin/sw_vers -productVersion 2>/dev/null || echo "0.0"
}

# Compare host macOS version to major.minor. Returns 0 when host >= required.
cyder_macos_at_least() {
  local need_major="${1:?}" need_minor="${2:?}"
  local version major minor
  version="$(cyder_macos_product_version)"
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  if ((major > need_major)); then
    return 0
  fi
  if ((major == need_major && minor >= need_minor)); then
    return 0
  fi
  return 1
}

# Current CX26 Cyder engine binaries (wine/ntdll/MoltenVK) are built with
# MACOSX_DEPLOYMENT_TARGET=10.15. This gate also protects a future lower-floor
# non-Vulkan runtime from loading MoltenVK on an unsupported host.
cyder_apply_moltenvk_os_floor() {
  if cyder_macos_at_least 10 15; then
    return 0
  fi
  export CYDER_DISABLE_MOLTENVK=1
  if [[ -z "${WINEDLLOVERRIDES:-}" ]]; then
    export WINEDLLOVERRIDES="winevulkan=d"
  elif [[ "$WINEDLLOVERRIDES" != *winevulkan=* ]]; then
    export WINEDLLOVERRIDES="${WINEDLLOVERRIDES};winevulkan=d"
  fi
  echo "MoltenVK disabled: macOS $(cyder_macos_product_version) is below 10.15" >&2
}
