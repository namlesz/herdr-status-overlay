import Foundation

/// Thread-safe owner of the `Store`. `onChange` fires on the model queue only when the view changes,
/// so an unchanged heartbeat never reaches the UI.
public final class OverlayModel {
    private let queue = DispatchQueue(label: "overlay.model")
    private var store: Store
    private var published: [SectionView]?
    private let clock: () -> UInt64
    public var onChange: (([SectionView]) -> Void)?

    public init(sources: [SourceConfig], clock: @escaping () -> UInt64 = MonotonicClock.now) {
        store = Store(sources: sources)
        self.clock = clock
    }

    public func begin(_ id: String) -> UInt64 { queue.sync { store.begin(id) } }

    /// Returns whether the read itself succeeded (drives backoff), even if its result was discarded.
    @discardableResult
    public func finish(_ id: String, generation: UInt64, outcome: RunOutcome) -> Bool {
        queue.sync {
            let succeeded: Bool
            switch Self.interpret(outcome) {
            case .agents(let agents):
                store.succeed(id, generation: generation, agents: agents, now: clock())
                succeeded = true
            case .failure(let failure):
                store.fail(id, generation: generation, failure: failure)
                succeeded = false
            }
            publish()
            return succeeded
        }
    }

    public func tick() { queue.async { self.store.expire(now: self.clock()); self.publish() } }
    public func wake() { queue.async { self.store.wake(); self.publish() } }

    public func snapshot() -> [SectionView] { queue.sync { store.view(now: clock()) } }

    private func publish() {
        let view = store.view(now: clock())
        guard view != published else { return }
        published = view
        onChange?(view)
    }

    enum Interpreted { case agents([AgentRecord]), failure(ReadFailure) }

    static func interpret(_ outcome: RunOutcome) -> Interpreted {
        switch outcome {
        case .exited(0, let stdout, _):
            do { return .agents(try AgentListParser.parse(stdout)) } catch ParseError.oversized {
                return .failure(.oversized)
            } catch { return .failure(.malformed) }
        case .exited(let code, _, _): return .failure(.exit(code))
        case .signaled(let signal): return .failure(.signal(signal))
        case .timedOut, .cancelled: return .failure(.timeout)
        case .oversized: return .failure(.oversized)
        case .spawnFailed(let code): return .failure(.spawn(code))
        }
    }
}

/// One serial loop per source: at most one read in flight, the next one scheduled only after the
/// previous finished. No queue of reads ever builds up.
public final class SourcePoller {
    public static let backoff: [Double] = [5, 10, 30]

    private let source: SourceConfig
    private let model: OverlayModel
    private let read: ([String]) -> RunOutcome
    private let cancelRead: () -> Void
    private let queue: DispatchQueue
    private let backoff: [Double]
    private let lock = NSLock()
    private var stopped = false
    private var failures = 0
    private var scheduled: DispatchWorkItem?

    public convenience init(source: SourceConfig, model: OverlayModel, limits: RunLimits = RunLimits()) {
        let runner = ProcessRunner(limits: limits)
        self.init(source: source, model: model, read: runner.run, cancel: runner.cancel)
    }

    public init(source: SourceConfig, model: OverlayModel, read: @escaping ([String]) -> RunOutcome,
                cancel: @escaping () -> Void = {}, backoff: [Double] = SourcePoller.backoff) {
        self.source = source
        self.model = model
        self.read = read
        self.cancelRead = cancel
        self.backoff = backoff
        queue = DispatchQueue(label: "overlay.poll." + source.id)
    }

    public func start() { queue.async { self.cycle() } }

    /// Skip an old interval/backoff after wake; an in-flight read finishes before the new one.
    public func refresh() {
        queue.async {
            guard !self.isStopped else { return }
            self.failures = 0
            self.schedule(after: 0)
        }
    }

    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        cancelRead()
    }

    /// Waits for an in-flight read to finish after `stop()`; false if it did not within `timeout`.
    public func drain(timeout: Double) -> Bool {
        let group = DispatchGroup()
        group.enter()
        queue.async { group.leave() }
        return group.wait(timeout: .now() + timeout) == .success
    }

    public static func delay(afterFailures failures: Int, interval: Double, backoff: [Double]) -> Double {
        failures == 0 ? interval : backoff[min(failures, backoff.count) - 1]
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func schedule(after delay: Double) {
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.cycle() }
        scheduled = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cycle() {
        guard !isStopped else { return }
        let generation = model.begin(source.id)
        let outcome = read(source.listArguments)
        guard !isStopped else { return }
        failures = model.finish(source.id, generation: generation, outcome: outcome) ? 0 : failures + 1
        let delay = Self.delay(afterFailures: failures, interval: source.interval, backoff: backoff)
        schedule(after: delay)
    }
}
