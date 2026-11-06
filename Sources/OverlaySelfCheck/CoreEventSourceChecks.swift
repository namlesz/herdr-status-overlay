import Darwin
import Foundation
import OverlayCore

/// Stateful fake core: sequence, subscribers, machine health, fake clock and joined shutdown.
private final class EventSourceFixture {
    let path = "/tmp/hso-source-\(UUID().uuidString).sock"
    private let listener: Int32
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var clients = Set<Int32>()
    private var subscribers = Set<Int32>()
    private var stopped = false
    private var time: UInt64 = 0
    private var health: String? = nil
    private var subscriptionCount = 0
    private var methods = [String]()
    private var seq = 1
    private var armedHealthHeartbeat: UInt64? = nil
    private var terminals: [[String: Any]] = [
        ["address": "t1", "state": "live", "reported": true, "status": ["state": "working"]],
        ["address": "host/t2", "state": "live", "reported": true, "status": ["state": "working"]]
    ]

    init?() {
        guard let listener = fakeCoreListener(path: path) else { return nil }
        self.listener = listener
        group.enter()
        DispatchQueue.global().async {
            defer { self.group.leave() }
            while true {
                let fd = accept(self.listener, nil, nil)
                guard fd >= 0 else { return }
                self.lock.lock()
                if self.stopped { self.lock.unlock(); close(fd); return }
                self.clients.insert(fd)
                self.group.enter()
                self.lock.unlock()
                DispatchQueue.global().async { self.serve(fd); self.group.leave() }
            }
        }
    }

    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return time }
    func setTime(_ secondsValue: Double) { lock.lock(); time = seconds(secondsValue); lock.unlock() }
    func setHealth(_ value: String?) { lock.lock(); health = value; lock.unlock() }

    /// The next machine.list first moves the clock to `secondsValue`, then a real heartbeat is delivered on the event socket:
    /// a message that lands while the source is between its silence check and its read.
    func armHeartbeatDuringHealthCheck(atSeconds secondsValue: Double) { lock.lock(); armedHealthHeartbeat = seconds(secondsValue); lock.unlock() }
    func subscriptions() -> Int { lock.lock(); defer { lock.unlock() }; return subscriptionCount }
    func usedTerminalList() -> Bool { lock.lock(); defer { lock.unlock() }; return methods.contains("terminal.list") }

    func disconnectEvents() {
        lock.lock(); defer { lock.unlock() }
        for fd in subscribers { shutdown(fd, SHUT_RDWR) }
    }

    func heartbeatAndTitle(_ title: String) {
        lock.lock(); defer { lock.unlock() }
        var data = jsonLine(["jsonrpc": "2.0", "method": "heartbeat", "params": ["seq": seq]])
        seq += 1
        terminals[0]["title"] = title
        data.append(jsonLine(["jsonrpc": "2.0", "method": "event", "params": ["seq": seq, "type": "title", "terminal": "t1", "data": ["title": title]]]))
        for fd in subscribers { sendAll(fd, data) }
    }

    func doneThenIdle() {
        lock.lock(); defer { lock.unlock() }
        var data = Data()
        for state in ["done", "idle"] {
            seq += 1
            terminals[0]["status"] = ["state": state]
            data.append(jsonLine(["jsonrpc": "2.0", "method": "event", "params": ["seq": seq, "type": "status", "terminal": "t1",
                "data": ["status": ["state": state], "records": [String: Any](), "reported": true]]]))
        }
        for fd in subscribers { sendAll(fd, data) }
    }

    func missed() {
        lock.lock(); defer { lock.unlock() }
        terminals[1]["status"] = ["state": "done"]
        let data = jsonLine(["jsonrpc": "2.0", "method": "missed", "params": ["seq": seq, "terminals": terminals]])
        for fd in subscribers { sendAll(fd, data) }
    }

    func stop() -> Bool {
        lock.lock(); stopped = true
        for fd in clients { shutdown(fd, SHUT_RDWR) }
        shutdown(listener, SHUT_RDWR); close(listener)
        lock.unlock()
        let finished = group.wait(timeout: .now() + 2) == .success
        unlink(path)
        return finished
    }

    private func serve(_ fd: Int32) {
        defer {
            lock.lock(); clients.remove(fd); subscribers.remove(fd); close(fd); lock.unlock()
        }
        while let request = readJSONLine(fd), let method = request["method"] as? String, let id = request["id"] {
            lock.lock()
            methods.append(method)
            let result: [String: Any]
            switch method {
            case "hello": result = ["generation": 1, "framed": false]
            case "server.status": result = ["pid": getpid()]
            case "events.subscribe":
                result = ["seq": seq, "terminals": terminals, "channel": NSNull()]
                subscribers.insert(fd); subscriptionCount += 1
            case "machine.list":
                if let advanced = armedHealthHeartbeat {
                    armedHealthHeartbeat = nil
                    time = advanced
                    let heartbeat = jsonLine(["jsonrpc": "2.0", "method": "heartbeat", "params": ["seq": seq]])
                    for subscriber in subscribers { sendAll(subscriber, heartbeat) }
                }
                if let health { result = ["machines": [["name": "host", "state": health]]] }
                else {
                    sendAll(fd, jsonLine(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "unavailable"]]))
                    lock.unlock(); continue
                }
            default: lock.unlock(); return
            }
            sendAll(fd, jsonLine(["jsonrpc": "2.0", "id": id, "result": result]))
            lock.unlock()
        }
    }
}

func checkCoreEventSource() {
    guard let fixture = EventSourceFixture() else { check(false, "creates event source fixture"); return }
    let model = OverlayModel(sources: [.local(executable: "/fake")], clock: fixture.now)
    let source = CoreEventSource(environment: ["HERDR_OVERLAY_SOCKET_PATH": fixture.path], expectedPID: getpid(), model: model, clock: fixture.now)
    func waitFor(_ name: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        check(condition(), name)
    }
    func view() -> SectionView { model.snapshot()[0] }
    source.start()
    waitFor("failed initial machine query still subscribes and displays local", { !view().stale && view().rows.map(\.key.paneID) == ["t1"] })
    fixture.setHealth("connected"); fixture.setTime(15)
    waitFor("machine monitor reconnects without blocking local stream", { view().rows.count == 2 })
    fixture.setTime(16); fixture.doneThenIdle()
    waitFor("source consumes coalesced done/idle without losing completion", { view().rows.contains { $0.key.paneID == "t1" && $0.status == .done && $0.completionEventAt != nil } })
    for time in [30.0, 45, 60, 75, 90] {
        fixture.setTime(time)
        let title = "step-\(time)"
        fixture.heartbeatAndTitle(title)
        waitFor("source accepts real heartbeat before next event at \(time)", { !view().stale && view().rows.contains { $0.key.paneID == "t1" && $0.activity == title } })
    }
    check(fixture.subscriptions() == 1, "healthy heartbeat traffic never resubscribes")
    check(view().rows.first { $0.key.paneID == "t1" }?.status == .idle, "event source does not renew done TTL on heartbeats")
    fixture.setHealth("unreachable"); fixture.setTime(105)
    fixture.heartbeatAndTitle("offline")
    waitFor("remote is hidden on next 15-second health poll while local remains fresh", { !view().stale && view().rows.map(\.key.paneID) == ["t1"] && view().rows[0].activity == "offline" })
    fixture.setHealth("connected"); fixture.missed(); fixture.heartbeatAndTitle("synced")
    waitFor("actual missed at equal sequence is processed while health still says offline", { !view().stale && view().rows.map(\.key.paneID) == ["t1"] && view().rows[0].activity == "synced" })
    fixture.setTime(120); fixture.heartbeatAndTitle("online")
    waitFor("sync before connected poll restores remote without false celebration", { !view().stale && view().rows.count == 2 && view().rows.first { $0.key.paneID == "host/t2" }?.completionEventAt == nil })
    fixture.setHealth("unreachable"); fixture.setTime(135); fixture.heartbeatAndTitle("second-offline")
    waitFor("remote is offline before the local socket is lost", { !view().stale && view().rows.map(\.key.paneID) == ["t1"] && view().rows[0].activity == "second-offline" })
    fixture.disconnectEvents()
    waitFor("event EOF invalidates the source", { view().stale })
    fixture.setHealth("connected"); fixture.missed() // The sync happens while this subscriber is disconnected.
    source.refresh()
    waitFor("same-PID reconnect restores remote whose missed notification was lost", { !view().stale && view().rows.count == 2 && fixture.subscriptions() == 2 })
    fixture.setTime(181)
    waitFor("live machine monitor cannot keep silent event socket fresh", { view().stale && view().problem == .failed(.timeout) })
    source.refresh()
    waitFor("refresh interrupts backoff and immediately obtains a new baseline", { !view().stale && fixture.subscriptions() == 3 })
    // Armed while the clock still reads 181 s, so no health check can consume it early. The last notification was at 181 s,
    // and the heartbeat arrives during the health check at 225 s, which is 45.1 s after it.
    fixture.armHeartbeatDuringHealthCheck(atSeconds: 226.1)
    fixture.setTime(225)
    waitFor("heartbeat crossing the silence deadline during a health check fails the stream", { view().stale && view().problem == .failed(.timeout) })
    check(!fixture.usedTerminalList(), "active event source never polls terminal.list")
    let start = Date()
    source.stop()
    check(source.drain(timeout: 1) && Date().timeIntervalSince(start) < 1, "stop interrupts read and drains source promptly")
    check(fixture.stop(), "event source fixture reaps every connection")
}
