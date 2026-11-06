import Darwin
import Foundation

// Plumbing for fake core servers on Unix sockets. Each fake keeps its own protocol logic.

/// Listening socket at `path`; the caller closes it.
func fakeCoreListener(path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, listen(fd, 8) == 0 else { close(fd); return nil }
    return fd
}

/// Writes every byte. SO_NOSIGPIPE turns a closed peer into a short write, not a process-killing SIGPIPE.
func sendAll(_ fd: Int32, _ data: Data) {
    var noSignal: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < data.count {
            let count = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), data.count - offset, 0)
            if count <= 0 { return }
            offset += count
        }
    }
}

/// One newline-terminated JSON-RPC line.
func jsonLine(_ object: [String: Any]) -> Data {
    var data = try! JSONSerialization.data(withJSONObject: object)
    data.append(10)
    return data
}

/// Reads one request object byte by byte, so a request never consumes the next one. nil on EOF, bad JSON or overlong lines.
func readJSONLine(_ fd: Int32, maxBytes: Int = 4096) -> [String: Any]? {
    var data = Data(), byte: UInt8 = 0
    while data.count <= maxBytes {
        guard recv(fd, &byte, 1, 0) == 1 else { return nil }
        if byte == 10 { return try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
        data.append(byte)
    }
    return nil
}
