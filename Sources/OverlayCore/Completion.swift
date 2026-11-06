/// Projects explicit completion and core read receipts without inferring completion from turn growth.
public enum DisplayStatus: String, CaseIterable { case working, blocked, done, idle, unknown }

public struct CompletionTracker {
    struct Track {
        var serverDone: Bool
        var pendingWithoutReceipt: Bool
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
            var track = previous ?? Track(serverDone: false, pendingWithoutReceipt: false, completionEventAt: nil)
            let isDone = agent.status == .done
            if isDone && !track.serverDone && baselined && previous != nil {
                track.completionEventAt = now
            }
            if agent.status == .working {
                track.pendingWithoutReceipt = false
            } else if let turn = agent.turn, let seenTurn = agent.seenTurn {
                track.pendingWithoutReceipt = turn > seenTurn
            } else if isDone {
                track.pendingWithoutReceipt = true
            }
            track.serverDone = isDone
            next[agent.key] = track
        }
        tracks = next
        baselined = true
    }

    public func completionEventAt(_ key: AgentKey) -> UInt64? { tracks[key]?.completionEventAt }

    public func display(_ agent: AgentRecord) -> DisplayStatus {
        switch agent.status {
        case .working: return .working
        case .blocked: return .blocked
        case .unknown: return .unknown
        case .idle, .done:
            if let turn = agent.turn, let seenTurn = agent.seenTurn { return turn > seenTurn ? .done : .idle }
            return tracks[agent.key]?.pendingWithoutReceipt == true || agent.status == .done ? .done : .idle
        }
    }
}
