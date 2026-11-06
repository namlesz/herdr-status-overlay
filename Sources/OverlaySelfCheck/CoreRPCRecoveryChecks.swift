import Darwin
import Foundation
import OverlayCore

private func socketPath() -> String { "/tmp/hso-\(UUID().uuidString).sock" }

private func clientFor(_ path: String) -> CoreRPCClient? {
    CoreRPCClient(environment: ["HOME": "/tmp", "HERDR_OVERLAY_SOCKET_PATH": path])
}

/// Answers hello, server.status and terminal.list on one connection, then stops.
private func rpcServe(_ fd: Int32, serverPID: Int = Int(getpid()), stopAfterStatus: Bool = false) {
    defer { close(fd) }
    while let request = readJSONLine(fd), let id = request["id"] {
        let result: [String: Any]
        switch request["method"] as? String {
        case "hello": result = ["generation": 1, "framed": false, "methods": []]
        case "server.status": result = ["pid": serverPID]
        case "terminal.list": result = ["terminals": [["address": "remote/t1", "state": "live", "reported": true,
                                                         "status": ["state": "working"]]], "machines": [], "hidden_finished": 0]
        default: return
        }
        sendAll(fd, jsonLine(["jsonrpc": "2.0", "id": id, "result": result]))
        if request["method"] as? String == "terminal.list" { return }
        if stopAfterStatus && request["method"] as? String == "server.status" { return }
    }
}

func checkCoreRPCRecovery() {
    do {
        let path = socketPath()
        guard let listener = fakeCoreListener(path: path) else { check(false, "creates delayed reconnect socket"); return }
        defer { unlink(path) }
        DispatchQueue.global().async {
            let first = accept(listener, nil, nil)
            close(listener); unlink(path)
            if first >= 0 { _ = readJSONLine(first); close(first) }
        }
        guard let client = clientFor(path) else { check(false, "connects before listener disappears"); return }
        check((try? client.snapshot()) == nil, "EOF invalidates the old transport")
        check((try? client.snapshot()) == nil, "reconnect fails while listener is absent")
        guard let restored = fakeCoreListener(path: path) else { check(false, "restores same-PID listener"); return }
        defer { close(restored) }
        DispatchQueue.global().async {
            let connection = accept(restored, nil, nil)
            if connection >= 0 { rpcServe(connection) }
        }
        let recovered = (try? client.snapshot()).flatMap { try? AgentListParser.parse($0) }
        check(recovered?.count == 1, "after EOF and a failed retry, a later poll reconnects to the same core PID")
    }

    do {
        let path = socketPath()
        guard let listener = fakeCoreListener(path: path) else { check(false, "creates timeout socket"); return }
        defer { close(listener); unlink(path) }
        DispatchQueue.global().async {
            let first = accept(listener, nil, nil)
            if first >= 0 { _ = readJSONLine(first); usleep(2_200_000); close(first) }
            let second = accept(listener, nil, nil)
            if second >= 0 { rpcServe(second) }
        }
        guard let client = clientFor(path) else { check(false, "connects before delayed response"); return }
        let start = Date(); var timedOut = false
        do { _ = try client.snapshot() } catch CoreRPCError.timeout { timedOut = true } catch {}
        let elapsed = Date().timeIntervalSince(start)
        let recovered = (try? client.snapshot()).flatMap { try? AgentListParser.parse($0) }
        check(timedOut && elapsed < 2.8 && recovered?.count == 1, "delayed response times out boundedly and a fresh connection recovers")
    }

    // The live subscribe and machine paths run the same PID check as snapshot().
    for entry in ["snapshot", "subscribeEvents", "machineList"] {
        let path = socketPath()
        guard let listener = fakeCoreListener(path: path) else { check(false, "creates PID socket for \(entry)"); continue }
        defer { close(listener); unlink(path) }
        DispatchQueue.global().async { let fd = accept(listener, nil, nil); if fd >= 0 { rpcServe(fd, serverPID: Int.max, stopAfterStatus: true) } }
        guard let client = clientFor(path) else { check(false, "connects to PID fixture for \(entry)"); continue }
        var rejected = false
        do {
            switch entry {
            case "snapshot": _ = try client.snapshot()
            case "subscribeEvents": _ = try client.subscribeEvents()
            default: _ = try client.machineList()
            }
        } catch CoreRPCError.identityChanged { rejected = true } catch {}
        check(rejected, "\(entry) rejects a mismatched or overflowing server PID without integer traps")
    }

    for (label, payload) in [("malformed", Data("not-json".utf8)), ("oversized", Data(repeating: 65, count: (1 << 20) + 1))] {
        let path = socketPath()
        guard let listener = fakeCoreListener(path: path) else { check(false, "creates \(label) socket"); continue }
        defer { close(listener); unlink(path) }
        DispatchQueue.global().async {
            let fd = accept(listener, nil, nil)
            if fd >= 0 { _ = readJSONLine(fd); sendAll(fd, payload + Data([10])); close(fd) }
        }
        guard let client = clientFor(path) else { check(false, "connects to \(label) fixture"); continue }
        var rejected = false
        do { _ = try client.snapshot() } catch CoreRPCError.malformed { rejected = label == "malformed" }
        catch CoreRPCError.oversized { rejected = label == "oversized" } catch {}
        check(rejected, "\(label) JSON-RPC frames fail closed")
    }

    do {
        let path = socketPath()
        guard let listener = fakeCoreListener(path: path) else { check(false, "creates cancellation socket"); return }
        defer { close(listener); unlink(path) }
        DispatchQueue.global().async { let fd = accept(listener, nil, nil); if fd >= 0 { _ = readJSONLine(fd); var byte: UInt8 = 0; _ = recv(fd, &byte, 1, 0); close(fd) } }
        guard let client = clientFor(path) else { check(false, "connects before cancellation"); return }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = try? client.snapshot(); finished.signal() }
        usleep(50_000); let start = Date(); client.cancel()
        check(finished.wait(timeout: .now() + 0.5) == .success && Date().timeIntervalSince(start) < 0.5,
              "socket cancellation bounds poller shutdown")
    }
}
