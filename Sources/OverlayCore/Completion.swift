/// Status shown by the overlay; `done` reverts to idle after `SourceConfig.finishedTTL`.
public enum DisplayStatus: String, CaseIterable {
    case working, blocked, done, idle, unknown
}

/// Completion markers are not task counters. Recovery re-establishes their baseline;
/// explicit server done is still shown, including on the first snapshot.
public struct CompletionTracker {
    struct Track {
        var seq: UInt64?
        var sawWorking: Bool
        var finishedAt: UInt64?
        var serverDone: Bool
    }

    private(set) var tracks: [AgentKey: Track] = [:]
    private var baselined = false

    public init() {}

    public mutating func rebaseline() { baselined = false }

    public mutating func clear() {
        tracks = [:]
        baselined = false
    }

    public mutating func apply(_ agents: [AgentRecord], now: UInt64) {
        var next: [AgentKey: Track] = [:]
        for agent in agents {
            let previous = tracks[agent.key]
            let working = agent.status == .working
            let serverDone = agent.status == .done
            let regressed = isRegression(agent.completionSeq, previous?.seq)
            var track = previous ?? Track(seq: nil, sawWorking: false, finishedAt: nil, serverDone: false)
            if regressed { track.finishedAt = nil }
            if baselined && previous != nil && !regressed, let seq = agent.completionSeq,
               track.seq.map({ seq > $0 }) ?? track.sawWorking {
                track.finishedAt = now
            }
            if serverDone && (previous?.serverDone != true || regressed) { track.finishedAt = now }
            if working { track.finishedAt = nil }
            track.sawWorking = working || (baselined && !regressed && track.sawWorking)
            track.seq = agent.completionSeq ?? (regressed ? nil : track.seq)
            track.serverDone = serverDone
            next[agent.key] = track
        }
        tracks = next
        baselined = true
    }

    public func isPending(_ key: AgentKey, now: UInt64) -> Bool {
        guard let finishedAt = tracks[key]?.finishedAt else { return false }
        return elapsed(since: finishedAt, now: now) < SourceConfig.finishedTTL
    }

    public func display(_ agent: AgentRecord, now: UInt64) -> DisplayStatus {
        switch agent.status {
        case .working: return .working
        case .blocked: return .blocked
        case .unknown: return .unknown
        case .idle, .done: return isPending(agent.key, now: now) ? .done : .idle
        }
    }

    private func isRegression(_ seq: UInt64?, _ known: UInt64?) -> Bool {
        guard let seq, let known else { return false }
        return seq < known
    }
}
