#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

export CX_VERSION=26
source "$ROOT/scripts/env-x86_64.sh"

assert_eq "$OGOM" "$ROOT" "OGOM should point to the repository root"
assert_eq "$HOMEBREW_PREFIX" "$ROOT/.brew-x86" "Homebrew prefix should stay inside the repo"
assert_eq "$LLVM_MINGW" "$ROOT/build/llvm-mingw-20260616-ucrt-macos-universal" "llvm-mingw path should point at build/"
assert_eq "$WINE_INSTALL" "$ROOT/install/wine-cx26-x86_64" "Wine install prefix should match CX26 default"
assert_eq "$WINE_SRC" "$ROOT/build/cx26/sources/wine" "Wine source tree should point at build/cx26/sources/wine"
assert_eq "$CYDER_ENGINE_CX_PREFIX" "CX26" "CX26 build should set engine prefix label"
assert_eq "$BLUECG_PREFIX" "$ROOT/BlueCrossgateNew" "Game prefix should point at BlueCrossgateNew"
assert_eq "$ENTITLEMENTS_PLIST" "$ROOT/config/entitlements.plist" "entitlements path should use tracked config copy"
assert_contains "$PATH" "$ROOT/.brew-x86/bin" "PATH should include isolated Homebrew"
assert_contains "$PATH" "$ROOT/build/llvm-mingw-20260616-ucrt-macos-universal/bin" "PATH should include llvm-mingw"

type brew_x86_install_runtime >/dev/null 2>&1 \
  || { echo "ASSERT failed: brew_x86_install_runtime must be defined" >&2; exit 1; }
type brew_x86_ensure_local_tap >/dev/null 2>&1 \
  || { echo "ASSERT failed: brew_x86_ensure_local_tap must be defined" >&2; exit 1; }
type brew_x86_runtime_formula >/dev/null 2>&1 \
  || { echo "ASSERT failed: brew_x86_runtime_formula must be defined" >&2; exit 1; }
assert_eq "$MACOSX_DEPLOYMENT_TARGET" "10.15" "product floor deployment target defaults to 10.15"
[[ -f "$ROOT/homebrew/ogom-local/Formula/gnutls.rb" ]] \
  || { echo "ASSERT failed: vendored ogom/local gnutls formula must live in the repo" >&2; exit 1; }
assert_eq "$(brew_x86_runtime_formula gnutls)" "ogom/local/gnutls" \
  "runtime install must map gnutls to the vendored tap"
assert_contains "$(head -5 "$ROOT/homebrew/ogom-local/Formula/gnutls.rb")" "older clang" \
  "vendored gnutls formula should document GitLab older-clang patch skip"

# Sync into a fake prefix without requiring a full Homebrew install.
fake_prefix="$(mktemp -d "${TMPDIR:-/tmp}/ogom-brew-tap-XXXXXX")"
cleanup_fake() { rm -rf "$fake_prefix"; }
trap cleanup_fake EXIT
HOMEBREW_PREFIX="$fake_prefix" brew_x86_ensure_local_tap
[[ -f "$fake_prefix/Library/Taps/ogom/homebrew-local/Formula/gnutls.rb" ]] \
  || { echo "ASSERT failed: ensure_local_tap should copy Formula/gnutls.rb into the brew taps tree" >&2; exit 1; }

export CX_VERSION=25
unset WINE_SRC WINE_INSTALL CYDER_ENGINE_CX_PREFIX
# shellcheck disable=SC1091
source "$ROOT/scripts/env-x86_64.sh"
assert_eq "$WINE_INSTALL" "$ROOT/install/wine-cx25-x86_64" "CX25 should use separate install prefix"
assert_eq "$WINE_SRC" "$ROOT/build/cx25/sources/wine" "CX25 source tree should be isolated"
assert_eq "$CYDER_ENGINE_CX_PREFIX" "CX25" "CX25 build should set engine prefix label"

export HOMEBREW_PREFIX=/opt/homebrew
unset WINE_SRC WINE_INSTALL CYDER_ENGINE_CX_PREFIX
# shellcheck disable=SC1091
source "$ROOT/scripts/env-x86_64.sh"
assert_eq "$HOMEBREW_PREFIX" "$ROOT/.brew-x86" "shell /opt/homebrew must not leak into build env"

echo "PASS test-env-x86_64"
