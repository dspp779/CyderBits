#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/assert.sh"

script="$(<"$ROOT/scripts/build-media-stack.sh")"
assert_contains "$script" "-Dbase=enabled" "minimal stack needs gst-plugins-base libraries"
assert_contains "$script" "-Dgood=disabled" "minimal stack must omit good plugins"
assert_contains "$script" "-Dbad=disabled" "minimal stack must omit bad plugins"
assert_contains "$script" "-Dlibav=disabled" "minimal stack must omit FFmpeg/libav"
assert_contains "$script" "-Dbuild-tools-source=system" "minimal stack must not download opaque build binaries"
assert_contains "$script" "gstreamer-audio-1.0" "minimal stack must validate audio headers"

bundle="$(<"$ROOT/scripts/bundle-wine-dylibs.sh")"
assert_contains "$bundle" "MEDIA_LIB" "dylib bundler must allow the isolated media prefix"
assert_contains "$bundle" "for dep in otool_deps(p)" "dylib bundler must seed dependencies from Wine Unix modules"

echo "PASS test-build-media-stack"
