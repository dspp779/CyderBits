#!/usr/bin/env bash
# Ensure Rosetta 2 is available on Apple Silicon before running x86_64 Wine.
set -euo pipefail

cyder_is_apple_silicon() {
  [[ "$(uname -m)" == "arm64" ]]
}

cyder_rosetta_is_installed() {
  if /usr/sbin/pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1; then
    return 0
  fi
  arch -x86_64 /usr/bin/true >/dev/null 2>&1
}

cyder_rosetta_install_interactive() {
  # CLI / non-GUI only. Do not auto-accept the license; Swift owns consented GUI install.
  /usr/sbin/softwareupdate --install-rosetta
}

cyder_rosetta_error() {
  local message="$1"
  if [[ "${CYDER_GUI:-0}" == 1 ]]; then
    osascript -e "display alert \"Cyder 需要 Rosetta 2\" message \"$message\" as warning" 2>/dev/null || true
  else
    echo "$message" >&2
  fi
}

cyder_ensure_rosetta() {
  if ! cyder_is_apple_silicon; then
    return 0
  fi
  if cyder_rosetta_is_installed; then
    return 0
  fi

  # AppKit path installs Rosetta after informed consent. Never run softwareupdate
  # from GUI bash (no TTY for license; would hang or mis-report as engine errors).
  if [[ "${CYDER_GUI:-0}" == 1 ]]; then
    cyder_rosetta_error "請先在 Cyder 對話框同意並完成 Rosetta 2 安裝。"
    return 1
  fi

  echo "Rosetta 2 is required; installing it with softwareupdate..." >&2
  if ! cyder_rosetta_install_interactive; then
    cyder_rosetta_error "請先安裝 Rosetta 2，Cyder 才能執行 x86_64 Wine 引擎。"
    return 1
  fi

  if ! cyder_rosetta_is_installed; then
    cyder_rosetta_error "Rosetta 2 安裝未完成，請重新啟動 Cyder。"
    return 1
  fi
  return 0
}
