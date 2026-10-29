#!/usr/bin/env bash
# No Wine/Rosetta: verify accurate claim diagnostics under actual host policy.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /private/tmp/cy-identity.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/main.swift" <<'SWIFT'
import Foundation
import Darwin
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
DispatchQueue.global().async {
    do {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let prefix = root.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let ledger = root.appendingPathComponent("owners")
        let target = root.appendingPathComponent("spawned")
        let id = try CyderExecutionOwner.prepare(root: ledger, issuer: UUID(), scope: prefix.path)
        let log = root.appendingPathComponent("claim.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        let saved = dup(STDERR_FILENO)
        dup2(output.fileDescriptor, STDERR_FILENO)
        let status = CyderExecutionOwner.execute(root: ledger, id: id, command: ["/usr/bin/touch", target.path])
        fflush(stderr); dup2(saved, STDERR_FILENO); close(saved); output.closeFile()
        let receipt = try JSONDecoder().decode(CyderExecutionOwner.Ticket.self,
            from: Data(contentsOf: ledger.appendingPathComponent(id.uuidString + ".json")))
        if CyderExecutionOwner.Birth.current() == nil {
            let diagnostic = try String(contentsOf: log, encoding: .utf8)
            check(status == 75 && receipt.phase == "prepared", "unreadable identity changed ticket or allowed an effect")
            check(!FileManager.default.fileExists(atPath: target.path), "unconfirmed identity spawned a child")
            check(diagnostic.contains("processIdentityUnavailable") && !diagnostic.contains(": revoked"), "permission failure mislabeled as revoked")
            print("PASS denied host identity: accurate diagnostic, prepared ticket preserved, no child spawned")
        } else {
            check(status == 0 && receipt.phase == "finished", "valid host identity could not claim")
            check(FileManager.default.fileExists(atPath: target.path), "valid host claim lost its child")
            print("PASS available host identity: actual claim, effect and finished receipt")
        }
        // Actual revocation remains distinct even when identity is unreadable.
        let revoked = try CyderExecutionOwner.prepare(root: ledger, issuer: UUID(), scope: prefix.path)
        try CyderExecutionOwner.recover(root: ledger)
        let revokedTarget = root.appendingPathComponent("revoked-spawned")
        let refused = CyderExecutionOwner.execute(root: ledger, id: revoked, command: ["/usr/bin/touch", revokedTarget.path])
        check(refused == 75 && !FileManager.default.fileExists(atPath: revokedTarget.path), "revoked ticket was replayed")
        print("PASS genuinely revoked ticket still refuses execution")
        exit(0)
    } catch { fputs("Identity regression failed: \(error)\n", stderr); exit(1) }
}
dispatchMain()
SWIFT
swiftc -module-cache-path "$TMP/cache" "$ROOT/scripts/cyder_execution_owner.swift" "$TMP/main.swift" -o "$TMP/test"
"$TMP/test" "$TMP/state"
