#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/cy-native-handoff.XXXXXX)"
cleanup() {
  local status=$?
  for name in delayed late independent; do
    if [[ -d "$TEST_DIR/state/$name" ]]; then
      touch "$TEST_DIR/state/$name/log.release" "$TEST_DIR/state/$name/native.release" "$TEST_DIR/state/$name/bridge.release"
    fi
  done
  if [[ -n "${CYDER_TEST_EVIDENCE:-}" && -d "$TEST_DIR/state" ]]; then
    mkdir -p "$CYDER_TEST_EVIDENCE"; cp -R "$TEST_DIR/state" "$CYDER_TEST_EVIDENCE/"
  fi
  if [[ -f "$TEST_DIR/state/fixture-safe-to-remove" || ! -d "$TEST_DIR/state" ]]; then
    rm -rf "$TEST_DIR"
  else
    echo "Preserving unconfirmed fixture: $TEST_DIR" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
cat > "$TEST_DIR/main.swift" <<'SWIFT'
import Foundation
import Darwin
if [4, 6].contains(CommandLine.arguments.count), ["--prepare", "--prepare-global"].contains(CommandLine.arguments[1]) {
    DispatchQueue.global().async {
        do {
            let handoff: CyderExecutionOwner.Handoff? = CommandLine.arguments.count == 6
                ? .init(executable: CommandLine.arguments[4], pidFile: CommandLine.arguments[5]) : nil
            let id = try CyderExecutionOwner.prepare(root: URL(fileURLWithPath: CommandLine.arguments[2]),
                issuer: UUID(), scope: CommandLine.arguments[3], handoff: handoff,
                requiresGlobalScope: CommandLine.arguments[1] == "--prepare-global")
            print(id.uuidString); exit(0)
        } catch { fputs("Prepare failed: \(error)\n", stderr); exit(1) }
    }
    dispatchMain()
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--recover" {
    DispatchQueue.global().async {
        do { try CyderExecutionOwner.recover(root: URL(fileURLWithPath: CommandLine.arguments[2])); exit(0) }
        catch { fputs("Recovery failed: \(error)\n", stderr); exit(1) }
    }
    dispatchMain()
}
exit(CyderExecutionOwner.run(arguments: CommandLine.arguments))
SWIFT
swiftc -module-cache-path "$TEST_DIR/cache" "$ROOT/scripts/cyder_execution_owner.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/helper"
clang -arch x86_64 "$ROOT/tests/fixtures/cyder_native_handoff.c" -o "$TEST_DIR/native"
python3 "$ROOT/tests/fixtures/cyder_native_handoff.py" "$TEST_DIR/state" "$TEST_DIR/helper" "${CYDER_TEST_SOURCE_SCRIPTS:-$ROOT/scripts}" "$TEST_DIR/native"
