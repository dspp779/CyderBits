#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CACHE="$TMP/module-cache"
BIN="$TMP/cyder-gptk-harness"
export CYDER_SUPPORT="$TMP/support"
export CYDER_TEST_VOLUMES_ROOT="$TMP/Volumes"

VALID_VOLUME="$CYDER_TEST_VOLUMES_ROOT/Evaluation environment for Windows games 3.0"
VALID_LIB="$VALID_VOLUME/redist/lib"
mkdir -p "$VALID_LIB/external/D3DMetal.framework"
printf 'shared library payload\n' >"$VALID_LIB/external/libd3dshared.dylib"
mkdir -p "$CYDER_TEST_VOLUMES_ROOT/Evaluation environment for Windows games invalid/redist/lib"
mkdir -p "$CYDER_TEST_VOLUMES_ROOT/Unrelated volume/redist/lib/external/D3DMetal.framework"
printf 'ignored\n' >"$CYDER_TEST_VOLUMES_ROOT/Unrelated volume/redist/lib/external/libd3dshared.dylib"

cat >"$TMP/cyder_gptk_harness.swift" <<'SWIFT'
import Foundation

@main
enum CyderGptkHarness {
    static func main() throws {
        let candidates = CyderGptk.scanEvaluationVolumes()
        precondition(candidates.count == 1)

        let candidate = try XCTUnwrap(candidates.first)
        precondition(candidate.displayName == "Evaluation environment for Windows games 3.0")
        precondition(candidate.libRoot.lastPathComponent == "lib")
        precondition(CyderGptk.isValidGptkRoot(candidate.libRoot))
        precondition(CyderPaths.appleGptkRuntime.path.hasSuffix("/runtime/apple_gptk"))

        try CyderGptk.install(from: candidate)
        let runtime = CyderPaths.appleGptkRuntime
        precondition(CyderGptk.isValidGptkRoot(runtime))
        let sharedLibrary = try String(
            contentsOf: runtime.appendingPathComponent("external/libd3dshared.dylib"),
            encoding: .utf8
        )
        precondition(
            sharedLibrary == "shared library payload\n"
        )

        let manifestData = try Data(contentsOf: CyderGptk.runtimeManifestURL())
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as! [String: String]
        precondition(manifest["sourceVolume"] == candidate.volumeRoot.path)
        precondition(manifest["displayName"] == candidate.displayName)
        precondition(manifest["installedAt"] != nil)

        switch CyderGptk.preferredSource() {
        case .crossOver(let source):
            precondition(source == CyderGptk.crossOverAppleGptk)
        case .runtime(let source):
            precondition(source == runtime)
        case nil:
            fatalError("Expected a GPTK source after installation")
        }

        try CyderGptk.removeRuntimeInstall()
        precondition(!FileManager.default.fileExists(atPath: runtime.path))
        precondition(!FileManager.default.fileExists(atPath: CyderGptk.runtimeManifestURL().path))
    }
}

func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw HarnessError.missingValue }
    return value
}

enum HarnessError: Error {
    case missingValue
}
SWIFT

swiftc -O -module-cache-path "$CACHE" \
  "$ROOT/scripts/cyder_paths.swift" \
  "$ROOT/scripts/cyder_gptk.swift" \
  "$TMP/cyder_gptk_harness.swift" \
  -o "$BIN"

"$BIN"
echo "PASS test-cyder-gptk-swift"
