#!/usr/bin/env bash
# Helpers for pre-macOS-12 Cyder hosts: version checks, osascript progress,
# and optional MoltenVK/Vulkan disable when the OS is below MoltenVK's floor.
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
# MACOSX_DEPLOYMENT_TARGET=10.15. Skipping MoltenVK alone does not unlock
# older hosts for that artifact; this gate is for a future lower Wine build
# and for keeping non-Vulkan games from dlopening MoltenVK on older OS.
cyder_apply_moltenvk_os_floor() {
  if cyder_macos_at_least 10 15; then
    return 0
  fi
  export CYDER_DISABLE_MOLTENVK=1
  # Prevent winevulkan from loading libMoltenVK.dylib (minos 10.15).
  if [[ -z "${WINEDLLOVERRIDES:-}" ]]; then
    export WINEDLLOVERRIDES="winevulkan=d"
  elif [[ "$WINEDLLOVERRIDES" != *winevulkan=* ]]; then
    export WINEDLLOVERRIDES="${WINEDLLOVERRIDES};winevulkan=d"
  fi
  echo "MoltenVK disabled: macOS $(cyder_macos_product_version) is below 10.15" >&2
}

# Start an osascript progress owner that polls CYDER_PROGRESS_FILE.
# Prefer exec'ing cyder-legacy-progress.applescript as the app main process so
# AppleScript progress UI attaches to Cyder.app; this helper is for cases where
# bash must stay the parent.
cyder_osascript_progress_start() {
  local progress_file="${1:?}"
  local script_dir="${2:-${CYDER_SCRIPTS:-}}"
  local applescript="$script_dir/cyder-legacy-progress.applescript"
  CYDER_OSASCRIPT_PROGRESS_PID=""
  [[ -f "$applescript" ]] || return 0
  mkdir -p "$(dirname "$progress_file")"
  : >"$progress_file"
  rm -f "${progress_file}.done"
  /usr/bin/osascript "$applescript" "$progress_file" >/dev/null 2>&1 &
  CYDER_OSASCRIPT_PROGRESS_PID=$!
  export CYDER_OSASCRIPT_PROGRESS_PID
}

cyder_osascript_progress_stop() {
  local progress_file="${1:-${CYDER_PROGRESS_FILE:-}}"
  if [[ -n "$progress_file" ]]; then
    : >"${progress_file}.done"
  fi
  if [[ -n "${CYDER_OSASCRIPT_PROGRESS_PID:-}" ]]; then
    kill "$CYDER_OSASCRIPT_PROGRESS_PID" 2>/dev/null || true
    wait "$CYDER_OSASCRIPT_PROGRESS_PID" 2>/dev/null || true
    CYDER_OSASCRIPT_PROGRESS_PID=""
  fi
  if [[ -n "$progress_file" ]]; then
    rm -f "${progress_file}.done" "$progress_file"
  fi
}
