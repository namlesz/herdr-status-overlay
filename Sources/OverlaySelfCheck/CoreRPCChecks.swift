import Darwin
import Foundation
import OverlayCore

func checkCoreRPC() {
    let path = "/tmp/hso-\(UUID().uuidString).sock"
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { check(false, "creates fake RPC socket"); return }
    defer { close(listener); unlink(path) }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let bound = withUnsafePointer(to: &address) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, listen(listener, 1) == 0 else { check(false, "binds fake RPC socket"); return }
    let server = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { server.signal(); return }
        defer { close(client); server.signal() }
        var pending = Data(), chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            pending.append(contentsOf: chunk[..<count])
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = request["id"] else { return }
                let result: [String: Any]
                switch request["method"] as? String {
                case "hello": result = ["generation": 1, "framed": false, "methods": []]
                case "server.status": result = ["pid": getpid()]
                case "terminal.list": result = ["terminals": [["address": "remote/t1", "state": "live", "reported": true,
                                                                  "status": ["state": "working"]]], "machines": [], "hidden_finished": 0]
                default: return
                }
                var response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
                guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
                var output = data; output.append(10)
                output.withUnsafeBytes { raw in _ = Darwin.send(client, raw.baseAddress!, output.count, 0) }
                response.removeAll()
            }
        }
    }
    var environment = ProcessInfo.processInfo.environment
    environment["HERDR_OVERLAY_SOCKET_PATH"] = path
    guard let rpc = CoreRPCClient(environment: environment) else { check(false, "connects only to same-user fake core socket"); return }
    let snapshot = try? rpc.snapshot()
    let rows = snapshot.flatMap { try? AgentListParser.parse($0) }
    check(rows?.count == 1 && rows?.first?.key.paneID == "remote/t1", "read-only hello, PID check and terminal.list share connection")
    _ = server.wait(timeout: .now() + 1)
}
