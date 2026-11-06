import Darwin
import Foundation
import OverlayCore

private func rpcListener(path: String = "/tmp/hso-\(UUID().uuidString).sock") -> (Int32, String)? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let result = withUnsafePointer(to: &address) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0, listen(fd, 8) == 0 else { close(fd); return nil }
    return (fd, path)
}

private func rpcRequest(_ fd: Int32) -> [String: Any]? {
    var data = Data(), byte: UInt8 = 0
    while data.count <= 4096 {
        guard recv(fd, &byte, 1, 0) == 1 else { return nil }
        if byte == 10 { return try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
        data.append(byte)
    }
    return nil
}

private func rpcSend(_ fd: Int32, _ data: Data) {
    var output = data; output.append(10)
    output.withUnsafeBytes { raw in
        var offset = 0
        while offset < output.count {
            let count = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), output.count - offset, 0)
            if count <= 0 { break }
            offset += count
        }
    }
}

private func rpcServe(_ fd: Int32, serverPID: Int = Int(getpid()), stopAfterStatus: Bool = false) {
    defer { close(fd) }
    while let request = rpcRequest(fd), let id = request["id"] {
        let result: [String: Any]
        switch request["method"] as? String {
        case "hello": result = ["generation": 1, "framed": false, "methods": []]
        case "server.status": result = ["pid": serverPID]
        case "terminal.list": result = ["terminals": [["address": "remote/t1", "state": "live", "reported": true,
                                                         "status": ["state": "working"]]], "machines": [], "hidden_finished": 0]
        default: return
        }
        guard let response = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]) else { return }
        rpcSend(fd, response)
        if request["method"] as? String == "terminal.list" { return }
        if stopAfterStatus && request["method"] as? String == "server.status" { return }
    }
}

private func clientFor(_ path: String) -> CoreRPCClient? {
    CoreRPCClient(environment: ["HOME": "/tmp", "HERDR_OVERLAY_SOCKET_PATH": path])
}

func checkCoreRPCRecovery() {
    do {
        guard let (listener, path) = rpcListener() else { check(false, "creates reconnect socket"); return }
        defer { close(listener); unlink(path) }
        DispatchQueue.global().async {
            let first = accept(listener, nil, nil)
            if first >= 0 { _ = rpcRequest(first); close(first) }
            let second = accept(listener, nil, nil)
            if second >= 0 { rpcServe(second) }
        }
        guard let client = clientFor(path) else { check(false, "connects before fake disconnect"); return }
        let firstFailed: Bool
        do { _ = try client.snapshot(); firstFailed = false } catch { firstFailed = true }
        let recovered = (try? client.snapshot()).flatMap { try? AgentListParser.parse($0) }
        check(firstFailed && recovered?.first?.key.paneID == "remote/t1", "disconnect resets transport and reconnects to the same core PID")
    }

    do {
        guard let (listener, path) = rpcListener() else { check(false, "creates delayed reconnect socket"); return }
        defer { unlink(path) }
        DispatchQueue.global().async {
            let first = accept(listener, nil, nil)
            close(listener); unlink(path)
            if first >= 0 { _ = rpcRequest(first); close(first) }
        }
        guard let client = clientFor(path) else { check(false, "connects before listener disappears"); return }
        check((try? client.snapshot()) == nil, "EOF invalidates the old transport")
        check((try? client.snapshot()) == nil, "reconnect fails while listener is absent")
        guard let (restored, _) = rpcListener(path: path) else { check(false, "restores same-PID listener"); return }
        defer { close(restored) }
        DispatchQueue.global().async {
            let connection = accept(restored, nil, nil)
            if connection >= 0 { rpcServe(connection) }
        }
        let recovered = (try? client.snapshot()).flatMap { try? AgentListParser.parse($0) }
        check(recovered?.count == 1, "later polls retry after an unsuccessful reconnect")
    }

    do {
        guard let (listener, path) = rpcListener() else { check(false, "creates timeout socket"); return }
        defer { close(listener); unlink(path) }
        DispatchQueue.global().async {
            let first = accept(listener, nil, nil)
            if first >= 0 { _ = rpcRequest(first); usleep(2_200_000); close(first) }
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

    do {
        guard let (listener, path) = rpcListener() else { check(false, "creates PID socket"); return }
        defer { close(listener); unlink(path) }
        DispatchQueue.global().async { let fd = accept(listener, nil, nil); if fd >= 0 { rpcServe(fd, serverPID: Int.max, stopAfterStatus: true) } }
        guard let client = clientFor(path) else { check(false, "connects to PID fixture"); return }
        var rejected = false
        do { _ = try client.snapshot() } catch CoreRPCError.identityChanged { rejected = true } catch {}
        check(rejected, "server.status rejects a mismatched or overflowing PID without integer traps")
    }

    for (label, payload) in [("malformed", Data("not-json".utf8)), ("oversized", Data(repeating: 65, count: (1 << 20) + 1))] {
        guard let (listener, path) = rpcListener() else { check(false, "creates \(label) socket"); continue }
        defer { close(listener); unlink(path) }
        DispatchQueue.global().async {
            let fd = accept(listener, nil, nil)
            if fd >= 0 { _ = rpcRequest(fd); rpcSend(fd, payload); close(fd) }
        }
        guard let client = clientFor(path) else { check(false, "connects to \(label) fixture"); continue }
        var rejected = false
        do { _ = try client.snapshot() } catch CoreRPCError.malformed { rejected = label == "malformed" }
        catch CoreRPCError.oversized { rejected = label == "oversized" } catch {}
        check(rejected, "\(label) JSON-RPC frames fail closed")
    }

    do {
        guard let (listener, path) = rpcListener() else { check(false, "creates cancellation socket"); return }
        defer { close(listener); unlink(path) }
        DispatchQueue.global().async { let fd = accept(listener, nil, nil); if fd >= 0 { _ = rpcRequest(fd); var byte: UInt8 = 0; _ = recv(fd, &byte, 1, 0); close(fd) } }
        guard let client = clientFor(path) else { check(false, "connects before cancellation"); return }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = try? client.snapshot(); finished.signal() }
        usleep(50_000); let start = Date(); client.cancel()
        check(finished.wait(timeout: .now() + 0.5) == .success && Date().timeIntervalSince(start) < 0.5,
              "socket cancellation bounds poller shutdown")
    }
}
