import Foundation

extension CyderRecoveryObserver.Record {
    init?(_ record: CyderRequestJournal.Record) {
        guard let phase = CyderLifecycle.RequestPhase(rawValue: record.phase.rawValue),
              !record.id.isEmpty, !record.digest.isEmpty else { return nil }
        var proof: CyderLaunchObserver.NativeRoot?
        if let receipt = record.executionReceipt, receipt.requestID == record.id, receipt.digest == record.digest,
           receipt.launchID == record.launchID, receipt.epoch == record.executorEpoch,
           let root = receipt.nativeSpawn, let pid = root.processPID, let boot = root.processBoot, let started = root.processStarted {
            proof = .init(authority: .init(request: receipt.requestID, launch: receipt.launchID,
                digest: receipt.digest, epoch: receipt.epoch), ticket: receipt.ticketID, phase: root.phase,
                pid: pid, boot: boot, started: started, status: root.status, signalled: root.signalled, prefixScope: receipt.prefixScope)
        }
        let name = record.displayName ?? record.payload?.displayName ?? "Windows 程式"
        let clean = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        self.init(version: record.version,
            request: .init(id: record.id, digest: record.digest, environment: nil, phase: phase, launch: record.launchID),
            name: clean.isEmpty ? "Windows 程式" : String(clean.prefix(100)), root: proof)
    }
}
