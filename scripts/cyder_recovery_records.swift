import Foundation

/// Converts a native executor ticket into the history record the menu uses to
/// attach a running game's process proof, in this session or after a restart.
/// Tickets are the only launch state that survives Cyder; requests are not
/// persisted, so a ticket's correlation is the request identity.
extension CyderRecoveryObserver.Record {
    /// `currentEpoch` is this Cyder process's executor epoch: its own tickets
    /// describe launches it is still observing; tickets from an earlier process
    /// have an unknown outcome, which is what makes them recoverable.
    init?(ticket: CyderExecutionOwner.Ticket, currentEpoch: UUID) {
        guard let correlation = ticket.correlation else { return nil }
        var proof: CyderLaunchObserver.NativeRoot?
        if let spawn = ticket.nativeSpawn, let process = spawn.process {
            proof = .init(authority: .init(request: correlation.requestID, launch: correlation.launchID,
                digest: correlation.digest, epoch: ticket.issuer), ticket: ticket.id, phase: spawn.phase,
                pid: process.pid, boot: process.boot, started: process.started,
                status: spawn.status, signalled: spawn.signalled, prefixScope: ticket.scope)
        }
        // A ticket's own outcome, never a guess about the game: only a native
        // exit or a revocation is final; anything else is unconfirmed.
        let phase: CyderLifecycle.RequestPhase
        switch (ticket.phase, ticket.nativeSpawn?.phase) {
        case (.revoked, _), (_, .failed): phase = .failed
        case (.finished, .exited?), (.finished, nil): phase = .completed
        default:
            // Swift applies a `where` only to the last pattern, so decide explicitly.
            let live = ticket.issuer == currentEpoch
            if live && (ticket.phase == .prepared || ticket.phase == .active) { phase = .dispatching }
            else if live && ticket.phase == .handedOff { phase = .observing }
            else { phase = .uncertain }
        }
        // Strictly increases as a ticket advances, so the menu replaces an
        // older proof and ignores a repeated one.
        let spawnRank = ticket.nativeSpawn.map { $0.phase.rank + 1 } ?? 0
        let name = (ticket.displayName ?? "").unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        self.init(version: UInt64(ticket.phase.rank * 8 + spawnRank + 1),
            request: .init(id: correlation.requestID, digest: correlation.digest, environment: nil,
                           phase: phase, launch: correlation.launchID),
            name: name.isEmpty ? "Windows 程式" : String(name.prefix(100)), root: proof)
    }
}
