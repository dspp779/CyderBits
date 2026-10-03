#!/usr/bin/env bash
# Exercise the release gate with real Mach-O slices; no signing or network.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/cyder-release-contract.XXXXXX")"
trap 'rm -rf "$work"' EXIT
APP="$work/Cyder.app"
CYDER_APP_VERSION=0.14.0
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>0.14.0</string>
</dict></plist>
PLIST
printf 'int main(void) { return 0; }\n' > "$work/main.c"
for arch in arm64 x86_64; do
  xcrun clang -target "$arch-apple-macos11" "$work/main.c" -o "$work/$arch"
done
/usr/bin/lipo -create "$work/arm64" "$work/x86_64" -output "$work/universal"
# Load only the production contract, without executing the release workflow.
eval "$(sed -n '/^verify_release_app_contract() {$/,/^}$/p' "$ROOT/scripts/release-cyder.sh")"
cp "$work/universal" "$APP/Contents/MacOS/CyderSwift"
verify_release_app_contract
for arch in arm64 x86_64; do
  cp "$work/$arch" "$APP/Contents/MacOS/CyderSwift"
  if (verify_release_app_contract) > "$work/rejection.log" 2>&1; then
    echo "ASSERT failed: release accepted thin $arch binary" >&2
    exit 1
  fi
  assert_contains "$(cat "$work/rejection.log")" 'missing required architecture' \
    "thin binaries must fail the architecture gate"
done
cp "$work/universal" "$APP/Contents/MacOS/CyderSwift"
if (CYDER_APP_VERSION=0.14.1; verify_release_app_contract) > "$work/rejection.log" 2>&1; then
  echo "ASSERT failed: release accepted mismatched version" >&2
  exit 1
fi
assert_contains "$(cat "$work/rejection.log")" 'version mismatch' "version mismatch must fail"
printf '#!/bin/sh\nexit 0\n' > "$APP/Contents/MacOS/CyderSwift"
if (verify_release_app_contract) > "$work/rejection.log" 2>&1; then
  echo "ASSERT failed: release accepted shell fallback" >&2
  exit 1
fi
assert_contains "$(cat "$work/rejection.log")" 'shell fallback' "shell fallback must fail"
echo "PASS test-release-cyder-contract"
