import Darwin
import Foundation
import OverlayCore

func checkCoreEventRPC() {
    let path = "/tmp/hso-events-\(UUID().uuidString).sock"
    guard let listener = fakeCoreListener(path: path) else { check(false, "creates event stream socket"); return }
    defer { close(listener); unlink(path) }

    let live: [String: Any] = ["address": "remote/a", "state": "live", "reported": true, "status": ["state": "working"]]
    // Connections 0-2 each serve one events.subscribe and then close; connection 3 serves machine.list.
    func serve(_ fd: Int32, connection: Int) {
        defer { close(fd) }
        var machineChecks = 0
        while let request = readJSONLine(fd), let id = request["id"] {
            switch request["method"] as? String {
            case "hello": sendAll(fd, jsonLine(["jsonrpc": "2.0", "id": id, "result": ["generation": 1, "framed": false]]))
            case "server.status": sendAll(fd, jsonLine(["jsonrpc": "2.0", "id": id, "result": ["pid": getpid()]]))
            case "machine.list":
                let state = machineChecks == 0 ? "connected" : "unreachable"
                machineChecks += 1
                let machines: [[String: Any]] = [["name": "host", "target": "ssh", "id": "core", "host": "example", "version": "0.1.18", "state": state]]
                sendAll(fd, jsonLine(["jsonrpc": "2.0", "id": id, "result": ["machines": machines]]))
            case "events.subscribe":
                switch connection {
                case 0:
                    // A fragmented response followed by a coalesced heartbeat.
                    let response = jsonLine(["jsonrpc": "2.0", "id": id, "result": ["seq": 5, "terminals": [live], "channel": NSNull()]])
                    let heartbeat = jsonLine(["jsonrpc": "2.0", "method": "heartbeat", "params": ["seq": 6]])
                    let combined = response + heartbeat
                    sendAll(fd, combined.prefix(17))
                    usleep(10_000)
                    sendAll(fd, combined.dropFirst(17))
                case 1:
                    // Retained finished history pushes the snapshot past the ordinary 1 MiB line limit.
                    sendAll(fd, jsonLine(["jsonrpc": "2.0", "id": id, "result": ["seq": 7, "terminals": archivedHistoryFixture() + [live], "channel": NSNull()]]))
                default:
                    // An unterminated line beyond the event limit must fail closed, not grow without bound.
                    sendAll(fd, Data(repeating: 65, count: CoreRPCClient.eventStreamMaxBytes + 1))
                }
                return
            default: return
            }
        }
    }
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        defer { finished.signal() }
        for connection in 0..<4 {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            serve(fd, connection: connection)
        }
    }

    var env = ProcessInfo.processInfo.environment; env["HERDR_OVERLAY_SOCKET_PATH"] = path
    guard let client = CoreRPCClient(environment: env) else { check(false, "connects to event stream socket"); return }
    do {
        let first = try client.subscribeEvents()
        let heartbeat = try client.nextNotification(timeout: 1)
        let baseline = try first.currentRecords()
        check(first.sequence == 5 && baseline.count == 1, "subscribe result is a full baseline snapshot")
        check(heartbeat?["params"] != nil, "fragmented response and coalesced notification are preserved in line buffer")
        var eof = false
        do { _ = try client.nextNotification(timeout: 1) } catch { eof = true }
        check(eof, "EOF invalidates event subscription")
        client.reconnect()
        let recovered = try client.subscribeEvents()
        check(recovered.sequence == 7, "same-PID reconnect performs a fresh event subscription snapshot")
        let liveAfterHistory = try recovered.currentRecords().map(\.key.paneID)
        check(liveAfterHistory == ["remote/a"], "over 1 MiB of finished history still yields the live agent")
    } catch { check(false, "event subscription round-trip: \(error)") }

    client.reconnect()
    var oversized = false
    do { _ = try client.subscribeEvents() } catch CoreRPCError.oversized { oversized = true } catch {}
    check(oversized, "event snapshot beyond the bounded event limit fails closed")
    client.reconnect()

    if let machineClient = CoreRPCClient(environment: env) {
        let connected = try? machineClient.machineList()
        let disconnected = try? machineClient.machineList()
        check(connected?.connected == ["host"] && connected?.known == ["host"] && disconnected?.connected == [] && disconnected?.known == ["host"], "machine.list fails remote closed when state changes from connected to unreachable")
        machineClient.cancel()
    } else { check(false, "connects to machine monitor socket") }
    check(finished.wait(timeout: .now() + 2) == .success, "event fake server exits")
}
