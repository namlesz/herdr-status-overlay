/// Why a read did not produce a usable snapshot. Never carries output content.
public enum ReadFailure: Equatable {
    case exit(Int32), signal(Int32), timeout, oversized, malformed, spawn(Int32)
}

public struct RowView: Equatable {
    public let sourceID: String
    public let key: AgentKey
    public let status: DisplayStatus
    public let workspace: String
    public let label: String
    public let place: String?
    public let activity: String?
}

public struct SectionView: Equatable {
    public enum Problem: Equatable {
        case waiting, failed(ReadFailure), outdated, afterWake
    }

    public let id: String
    public let label: String
    /// nil while the source is stale: the UI shows "—", never zeros.
    public let counts: [DisplayStatus: Int]?
    public let staleAgents: Int
    public let stale: Bool
    public let problem: Problem?
    /// Blocked, working and finished rows, sorted by place, name and key.
    public let rows: [RowView]
}

/// Per-source state. Not thread-safe; `OverlayModel` serializes access.
public struct Store {
    private enum Invalidation: Equatable { case failure(ReadFailure), wake }

    private struct Source {
        let config: SourceConfig
        var agents: [AgentRecord] = []
        var lastSuccess: UInt64?
        var invalidation: Invalidation?
        var generation: UInt64 = 0
        var tracker = CompletionTracker()
    }

    private var sources: [Source]

    public init(sources: [SourceConfig]) {
        self.sources = sources.map { Source(config: $0) }
    }

    /// Token for a read that is about to start. Results carrying an older token are discarded.
    public func begin(_ id: String) -> UInt64 {
        sources.first { $0.config.id == id }?.generation ?? 0
    }

    /// Full replacement of the source snapshot; returns false when the read was invalidated.
    @discardableResult
    public mutating func succeed(_ id: String, generation: UInt64, agents: [AgentRecord], now: UInt64) -> Bool {
        guard let index = index(id), sources[index].generation == generation else { return false }
        if isStale(sources[index], now: now) { sources[index].tracker.rebaseline() }
        sources[index].agents = agents
        sources[index].lastSuccess = now
        sources[index].invalidation = nil
        sources[index].tracker.apply(agents, now: now)
        return true
    }

    public mutating func fail(_ id: String, generation: UInt64, failure: ReadFailure) {
        guard let index = index(id), sources[index].generation == generation else { return }
        sources[index].invalidation = .failure(failure)
        sources[index].tracker.rebaseline()
    }

    /// Everything read before sleep is outdated, including reads still in flight.
    public mutating func wake() {
        for index in sources.indices {
            sources[index].generation += 1
            sources[index].invalidation = .wake
            sources[index].tracker.rebaseline()
        }
    }

    /// Drops cached agents 60 s after the last successful read; the section itself stays.
    public mutating func expire(now: UInt64) {
        for index in sources.indices {
            guard let last = sources[index].lastSuccess,
                  elapsed(since: last, now: now) >= SourceConfig.retention else { continue }
            sources[index].agents = []
            sources[index].lastSuccess = nil
            sources[index].tracker.clear()
        }
    }

    public func view(now: UInt64) -> [SectionView] {
        sources.map { source in
            let stale = isStale(source, now: now)
            var counts = Dictionary(uniqueKeysWithValues: DisplayStatus.allCases.map { ($0, 0) })
            var rows: [RowView] = []
            for agent in source.agents {
                let status = source.tracker.display(agent, now: now)
                counts[status, default: 0] += 1
                if status == .blocked || status == .working || status == .done {
                    rows.append(RowView(sourceID: source.config.id, key: agent.key, status: status,
                                        workspace: agent.workspace, label: agent.label,
                                        place: agent.place, activity: agent.activity))
                }
            }
            rows.sort {
                let order: [DisplayStatus] = [.blocked, .working, .done]
                if $0.status != $1.status { return order.firstIndex(of: $0.status)! < order.firstIndex(of: $1.status)! }
                if $0.place != $1.place { return ($0.place ?? "") < ($1.place ?? "") }
                if $0.label != $1.label { return $0.label < $1.label }
                return $0.key < $1.key
            }
            return SectionView(id: source.config.id, label: source.config.label,
                               counts: stale ? nil : counts,
                               staleAgents: stale ? source.agents.count : 0,
                               stale: stale, problem: problem(source, stale: stale), rows: rows)
        }
    }

    private func index(_ id: String) -> Int? { sources.firstIndex { $0.config.id == id } }

    private func isStale(_ source: Source, now: UInt64) -> Bool {
        guard source.invalidation == nil, let last = source.lastSuccess else { return true }
        return elapsed(since: last, now: now) > source.config.staleAfter
    }

    private func problem(_ source: Source, stale: Bool) -> SectionView.Problem? {
        switch source.invalidation {
        case .failure(let failure): return .failed(failure)
        case .wake: return .afterWake
        case nil: return source.lastSuccess == nil ? .waiting : (stale ? .outdated : nil)
        }
    }
}
