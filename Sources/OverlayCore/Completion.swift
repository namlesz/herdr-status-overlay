/// Explicit server `done` is retained for 30 seconds; turn counters never imply completion.
public enum DisplayStatus: String, CaseIterable { case working, blocked, done, idle, unknown }

public struct CompletionTracker {
    struct Track {
        var finishedAt: UInt64?
        var serverDone: Bool
        var completionEventAt: UInt64?
    }
    private(set) var tracks: [AgentKey: Track] = [:]
    private var baselined = false
    public init() {}

    public mutating func rebaseline() {
        baselined = false
        for key in Array(tracks.keys) { tracks[key]?.completionEventAt = nil }
    }
    public mutating func clear() { tracks = [:]; baselined = false }

    public mutating func apply(_ agents: [AgentRecord], now: UInt64) {
        var next: [AgentKey: Track] = [:]
        for agent in agents {
            let previous = tracks[agent.key]
            var track = previous ?? Track(finishedAt: nil, serverDone: false, completionEventAt: nil)
            let isDone = agent.status == .done
            if isDone && !track.serverDone {
                track.finishedAt = now
                if baselined && previous != nil { track.completionEventAt = now }
            }
            if agent.status == .working { track.finishedAt = nil }
            track.serverDone = isDone
            next[agent.key] = track
        }
        tracks = next
        baselined = true
    }

    public func isPending(_ key: AgentKey, now: UInt64) -> Bool {
        guard let finishedAt = tracks[key]?.finishedAt else { return false }
        return elapsed(since: finishedAt, now: now) < SourceConfig.finishedTTL
    }
    public func completionEventAt(_ key: AgentKey) -> UInt64? { tracks[key]?.completionEventAt }

    public func display(_ agent: AgentRecord, now: UInt64) -> DisplayStatus {
        switch agent.status {
        case .working: return .working
        case .blocked: return .blocked
        case .unknown: return .unknown
        case .idle, .done: return isPending(agent.key, now: now) ? .done : .idle
        }
    }
}
