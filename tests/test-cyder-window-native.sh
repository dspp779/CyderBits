#!/usr/bin/env bash
# Opt-in desktop test: creates two windows belonging only to its native helper.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-window-native.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
cp "$ROOT/tests/fixtures/cyder_window_native_harness.swift" "$TEST_DIR/main.swift"
BUNDLE="$TEST_DIR/CyderC22Native.app"
mkdir -p "$BUNDLE/Contents/MacOS"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>NativeFixture</string><key>CFBundleIdentifier</key><string>local.cyder.c22-native-fixture</string><key>CFBundleName</key><string>Cyder C22 Native</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
swiftc -module-cache-path "$TEST_DIR/cache" "$ROOT/scripts/cyder_lifecycle.swift" "$ROOT/scripts/cyder_process_evidence.swift" "$ROOT/scripts/cyder_launch_observer.swift" "$ROOT/scripts/cyder_window_access.swift" "$ROOT/scripts/cyder_status_item.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
cp "$TEST_DIR/test" "$BUNDLE/Contents/MacOS/NativeFixture"
"$TEST_DIR/test" "$BUNDLE/Contents/MacOS/NativeFixture"
