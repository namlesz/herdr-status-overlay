import Foundation

public struct MachineAvailability: Equatable {
    public let known: Set<String>
    public let connected: Set<String>
    public init(known: Set<String>, connected: Set<String>) { self.known = known; self.connected = connected }
}

/// Connectivity can lag an authoritative `missed` snapshot by one machine poll.
public struct CoreRemoteState {
    public private(set) var machines: MachineAvailability?
    private var synchronized = Set<String>()
    public init() {}

    public mutating func update(_ result: MachineAvailability?) {
        if let result {
            if machines == nil { synchronized.formUnion(result.connected) }
            // A name absent from the previous poll was added since then; its first subscription already sent missed.
            if let previous = machines { synchronized.formUnion(result.connected.subtracting(previous.known)) }
            synchronized.subtract(result.known.subtracting(result.connected))
            synchronized.formIntersection(result.known)
            machines = result
        } else if let previous = machines {
            // A failed health RPC hides remotes but does not discard an otherwise healthy stream's sync.
            machines = MachineAvailability(known: previous.known, connected: [])
        }
    }

    public mutating func didSubscribe() {
        // A fresh subscription replaces a missed notification that may have arrived during the gap.
        synchronized.formUnion(machines?.connected ?? [])
    }

    public mutating func didSynchronize(_ records: [AgentRecord]) {
        synchronized.formUnion(machines?.known ?? [])
        synchronized.formUnion(records.compactMap { Self.remoteName($0.key.paneID) })
    }

    public func visible(_ records: [AgentRecord]) -> [AgentRecord] {
        records.filter {
            guard let machine = Self.remoteName($0.key.paneID) else { return true }
            return machines?.connected.contains(machine) == true && synchronized.contains(machine)
        }
    }

    private static func remoteName(_ address: String) -> String? {
        address.firstIndex(of: "/").map { String(address[..<$0]) }
    }
}

/// Owns two read-only, PID-pinned sockets: agent events and lightweight machine health.
public final class CoreEventSource {
    private let environment: [String: String]
    private let expectedPID: Int32
    private let model: OverlayModel
    private let clock: () -> UInt64
    private let queue = DispatchQueue(label: "overlay.core-events")
    private let runGroup = DispatchGroup()
    private let lock = NSLock()
    private var stopped = false
    private var refreshRequested = false
    private var eventsClient: CoreRPCClient?
    private var machineClient: CoreRPCClient?
    private static let machineRefresh = seconds(15)
    private static let silenceTimeout = seconds(45)

    public init(environment: [String: String], expectedPID: Int32, model: OverlayModel,
                clock: @escaping () -> UInt64 = MonotonicClock.now) {
        self.environment = environment; self.expectedPID = expectedPID; self.model = model; self.clock = clock
    }

    public func start() {
        runGroup.enter()
        queue.async { defer { self.runGroup.leave() }; self.run() }
    }

    public func drain(timeout: Double) -> Bool { runGroup.wait(timeout: .now() + timeout) == .success }

    public func refresh() {
        lock.lock(); refreshRequested = true; let events = eventsClient, monitor = machineClient; lock.unlock()
        events?.interrupt(); monitor?.interrupt()
    }

    public func stop() {
        lock.lock(); stopped = true; let events = eventsClient, monitor = machineClient; lock.unlock()
        events?.cancel(); monitor?.cancel()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private var hasRefresh: Bool { lock.lock(); defer { lock.unlock() }; return refreshRequested }

    private func takeRefresh() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let requested = refreshRequested; refreshRequested = false
        return requested
    }

    private func run() {
        var failures = 0
        var remote = CoreRemoteState()
        var lastMachineCheck: UInt64?
        defer { eventsClient?.reconnect(); machineClient?.reconnect() }
        while !isStopped {
            let events = connection(events: true)
            let monitor = connection(events: false)
            if takeRefresh() {
                events?.reconnect(); monitor?.reconnect()
                lastMachineCheck = nil
                failures = 0
            }
            let generation = model.begin("local")
            if lastMachineCheck == nil || elapsed(since: lastMachineCheck!, now: clock()) >= Self.machineRefresh {
                remote.update(try? monitor?.machineList())
                lastMachineCheck = clock()
            }
            do {
                guard let client = events else { throw CoreRPCError.unavailable }
                var reducer = try client.subscribeEvents()
                guard !hasRefresh, !isStopped else { throw CoreRPCError.unavailable }
                var lastNotification = clock()
                remote.didSubscribe()
                model.streamUpdate("local", generation: generation, agents: remote.visible(try reducer.currentRecords()), baseline: true)
                failures = 0
                while !isStopped {
                    guard !hasRefresh else { throw CoreRPCError.unavailable }
                    guard elapsed(since: lastNotification, now: clock()) < Self.silenceTimeout else { throw CoreRPCError.timeout }
                    if let lastCheck = lastMachineCheck, elapsed(since: lastCheck, now: clock()) >= Self.machineRefresh {
                        let previous = remote.machines
                        remote.update(try? monitor?.machineList())
                        lastMachineCheck = clock()
                        guard !hasRefresh, !isStopped else { throw CoreRPCError.unavailable }
                        if remote.machines != previous {
                            model.streamUpdate("local", generation: generation, agents: remote.visible(try reducer.currentRecords()), refresh: false)
                        }
                    }
                    // A short read also bounds health checks; refresh/stop interrupt the socket immediately.
                    guard let message = try client.nextNotification(timeout: 1) else { continue }
                    guard !hasRefresh, !isStopped else { throw CoreRPCError.unavailable }
                    // The read or the health RPC may have crossed the silence deadline; such a message must not renew it.
                    guard elapsed(since: lastNotification, now: clock()) < Self.silenceTimeout else { throw CoreRPCError.timeout }
                    let records = try reducer.apply(message)
                    lastNotification = clock()
                    if let records {
                        let baseline = message["method"] as? String == "missed"
                        if baseline { remote.didSynchronize(records) }
                        model.streamUpdate("local", generation: generation, agents: remote.visible(records), baseline: baseline)
                    } else {
                        model.streamHeartbeat("local", generation: generation)
                    }
                }
            } catch {
                events?.reconnect()
                if isStopped { break }
                if hasRefresh { continue }
                let failure: ReadFailure
                switch error {
                case CoreRPCError.timeout: failure = .timeout
                case CoreRPCError.oversized, ParseError.oversized, CoreEventError.tooManyTerminals: failure = .oversized
                default: failure = .malformed
                }
                model.streamFailure("local", generation: generation, failure: failure)
                failures += 1
                let until = MonotonicClock.now() + seconds(SourcePoller.delay(afterFailures: failures, interval: 0, backoff: SourcePoller.backoff))
                while !isStopped && !hasRefresh && MonotonicClock.now() < until { Thread.sleep(forTimeInterval: 0.05) }
                lastMachineCheck = nil
            }
        }
    }

    private func connection(events: Bool) -> CoreRPCClient? {
        lock.lock(); defer { lock.unlock() }
        if events {
            if eventsClient == nil { eventsClient = makeClient() }
            return eventsClient
        }
        if machineClient == nil { machineClient = makeClient() }
        return machineClient
    }

    private func makeClient() -> CoreRPCClient? {
        guard let client = CoreRPCClient(environment: environment), client.pid == expectedPID else { return nil }
        return client
    }
}
