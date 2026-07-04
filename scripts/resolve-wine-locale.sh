#!/usr/bin/env bash
# Resolve a Unix locale for Wine: explicit env > macOS AppleLocale > LANG > zh_TW.UTF-8
set -euo pipefail

FALLBACK="${CYDER_WINE_LOCALE_FALLBACK:-zh_TW.UTF-8}"

valid_locale() {
  [[ -n "${1:-}" && "$1" != "C" && "$1" != "POSIX" && "$1" != "C.UTF-8" ]]
}

if valid_locale "${LC_ALL:-}"; then
  printf '%s\n' "$LC_ALL"
  exit 0
fi

apple="$(defaults read -g AppleLocale 2>/dev/null || true)"
case "$apple" in
  zh-Hant_TW|zh_TW) printf '%s\n' "zh_TW.UTF-8" ;;
  zh-Hant_HK|zh_HK) printf '%s\n' "zh_HK.UTF-8" ;;
  zh-Hans_CN|zh-Hant_CN|zh_CN) printf '%s\n' "zh_CN.UTF-8" ;;
  ja_JP|ja) printf '%s\n' "ja_JP.UTF-8" ;;
  ko_KR|ko) printf '%s\n' "ko_KR.UTF-8" ;;
  en_*|en-*) printf '%s\n' "en_US.UTF-8" ;;
  "")
    :
    ;;
  *)
    if [[ "$apple" == *.* ]]; then
      printf '%s\n' "${apple//-/_}"
    else
      printf '%s\n' "${apple//-/_}.UTF-8"
    fi
    exit 0
    ;;
esac

if [[ -n "$apple" ]]; then
  exit 0
fi

if valid_locale "${LANG:-}"; then
  printf '%s\n' "$LANG"
  exit 0
fi

printf '%s\n' "$FALLBACK"
