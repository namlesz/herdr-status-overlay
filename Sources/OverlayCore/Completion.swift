/// Status shown by the overlay. `done` here means "pending completion in the overlay's own list",
/// not Herdr's client-side done/seen.
public enum DisplayStatus: String, CaseIterable {
    case working, blocked, done, idle, unknown
}

/// Overlay-owned completion list derived from `completion_seq`.
///
/// `completion_seq` is a marker in Herdr's sequence domain, not a task counter: 135 → 141 is one
/// completion. The first snapshot after start or recovery is a baseline and never creates completions.
/// Without a boot/epoch id in `agent list`, a server restart between two successful reads is only
/// noticed when the marker goes backwards or the terminal identity changes.
public struct CompletionTracker {
    struct Track: Equatable {
        var seq: UInt64?
        var sawWorking: Bool
        var pending: Bool
    }

    private(set) var tracks: [AgentKey: Track] = [:]
    private var baselined = false

    public init() {}

    /// Next snapshot re-establishes the baseline. Unacknowledged completions survive unless
    /// the marker regresses or the agent disappears.
    public mutating func rebaseline() { baselined = false }

    public mutating func clear() {
        tracks = [:]
        baselined = false
    }

    public mutating func apply(_ agents: [AgentRecord]) {
        var next: [AgentKey: Track] = [:]
        for agent in agents {
            let working = agent.status == .working
            let previous = tracks[agent.key]
            guard baselined, var track = previous else {
                let regressed = isRegression(agent.completionSeq, previous?.seq)
                next[agent.key] = Track(seq: agent.completionSeq ?? (regressed ? nil : previous?.seq),
                                        sawWorking: working,
                                        pending: !regressed && previous?.pending == true)
                continue
            }
            // A missing marker while working keeps the last known one.
            if let seq = agent.completionSeq {
                if let known = track.seq, seq < known {
                    track = Track(seq: seq, sawWorking: working, pending: false)
                } else if track.seq.map({ seq > $0 }) ?? track.sawWorking {
                    track = Track(seq: seq, sawWorking: working, pending: true)
                } else {
                    track.seq = seq
                }
            }
            if working { track.sawWorking = true }
            next[agent.key] = track
        }
        tracks = next
        baselined = true
    }

    public mutating func acknowledge(_ key: AgentKey) {
        tracks[key]?.pending = false
    }

    public func isPending(_ key: AgentKey) -> Bool { tracks[key]?.pending == true }

    public func display(_ agent: AgentRecord) -> DisplayStatus {
        switch agent.status {
        case .working: return .working
        case .blocked: return .blocked
        case .unknown: return .unknown
        case .idle, .done: return isPending(agent.key) ? .done : .idle
        }
    }

    private func isRegression(_ seq: UInt64?, _ known: UInt64?) -> Bool {
        guard let seq, let known else { return false }
        return seq < known
    }
}
