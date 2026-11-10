/// Phases of a native executor ticket, shared by the owner ledger and the
/// observers. Raw values are the on-disk strings, so existing tickets decode
/// unchanged; an unknown value now fails
/// decoding instead of being silently ignored by a string comparison.
enum CyderTicketPhase: String, Codable, CaseIterable {
    /// Issued by the app, revocable until a helper claims it.
    case prepared
    /// Claimed by the helper; Bash is preparing the prefix.
    case active
    /// The real Wine process was spawned; the scope is no longer mutated.
    case handedOff
    case finished
    case revoked
    /// The helper ended without proving whether a native spawn happened.
    case uncertain

    /// Monotonic order for reconciling receipts; equal ranks are alternatives.
    var rank: Int {
        switch self {
        case .prepared: return 0
        case .active: return 1
        case .uncertain, .handedOff: return 2
        case .finished, .revoked: return 3
        }
    }
    var isTerminal: Bool { rank == 3 }
    /// Phases that still block another operation on an overlapping scope.
    var holdsScope: Bool { self == .active || self == .uncertain }
}

/// Phases of the one-use native Wine spawn inside a ticket.
enum CyderSpawnPhase: String, Codable, CaseIterable {
    case claiming, spawned, exited, failed
    var rank: Int {
        switch self {
        case .claiming: return 0
        case .spawned: return 1
        case .exited, .failed: return 2
        }
    }
    var isTerminal: Bool { rank == 2 }
    /// A native process birth was recorded.
    var hasProcess: Bool { self == .spawned || self == .exited }
}
