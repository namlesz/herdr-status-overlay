import Darwin
import Foundation

public enum CoreRPCError: Error { case unavailable, malformed, timeout, oversized, identityChanged }

/// Read-only line-delimited JSON-RPC client pinned to the first same-user core PID.
public final class CoreRPCClient {
    /// Event snapshots and notifications carry retained finished history (hc keeps at most 500 per core), so they get a larger, still bounded limit.
    public static let eventStreamMaxBytes = 16 << 20
    public let socketPath: String
    public let pid: pid_t
    private let stateLock = NSLock()
    private var fd: Int32
    private var cancelled = false
    private var handshaken = false
    private var requestID = 1
    private var deadline: UInt64 = 0
    private let deadlineSeconds: Double = 2
    private var readBuffer = Data()

    public init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let path: String?
        if let override = environment["HERDR_OVERLAY_SOCKET_PATH"], !override.isEmpty {
            path = override
        } else {
            let home = environment["HOME"] ?? NSHomeDirectory()
            let state = environment["XDG_STATE_HOME"] ?? URL(fileURLWithPath: home).appendingPathComponent(".local/state").path
            let session = environment["HC_SESSION"] ?? "default"
            let lockFile = URL(fileURLWithPath: state).appendingPathComponent("herdr-core/\(session)/core.lock")
            if let contents = try? String(contentsOf: lockFile, encoding: .utf8) { path = contents.trimmingCharacters(in: .whitespacesAndNewlines) }
            else { path = nil }
        }
        guard let path, path.utf8.count < 104, let connection = Self.connect(path) else { return nil }
        socketPath = path; pid = connection.pid; fd = connection.fd
    }

    deinit { closeTransport() }

    public func cancel() {
        stateLock.lock(); defer { stateLock.unlock() }
        cancelled = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    public func interrupt() {
        stateLock.lock(); defer { stateLock.unlock() }
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    public func reconnect() {
        closeTransport()
        handshaken = false
        requestID = 1
    }

    public func snapshot() throws -> Data {
        do {
            try prepareConnection()
            return try JSONSerialization.data(withJSONObject: call(method: "terminal.list", params: [:]))
        } catch {
            reconnect()
            throw error
        }
    }

    public func subscribeEvents() throws -> CoreEventReducer {
        try prepareConnection()
        let response = try call(method: "events.subscribe", params: [:], maxBytes: Self.eventStreamMaxBytes)
        guard let result = response["result"] as? [String: Any] else { throw CoreRPCError.malformed }
        return try CoreEventReducer(snapshot: result)
    }

    public func nextNotification(timeout: Double = 1) throws -> [String: Any]? {
        guard !isCancelled, currentFD >= 0 else { throw CoreRPCError.unavailable }
        deadline = MonotonicClock.now() + seconds(timeout)
        do {
            let line = try readLine(maxBytes: Self.eventStreamMaxBytes)
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CoreRPCError.malformed }
            return object
        } catch CoreRPCError.timeout { return nil }
        catch { closeTransport(); throw error }
    }

    public func machineList() throws -> MachineAvailability {
        do {
            try prepareConnection()
            let response = try call(method: "machine.list", params: [:])
            guard let result = response["result"] as? [String: Any], let machines = result["machines"] as? [[String: Any]] else { throw CoreRPCError.malformed }
            var known = Set<String>(), connected = Set<String>()
            for machine in machines {
                guard let name = machine["name"] as? String, Text.isIdentifier(name), !name.contains("/"),
                      known.insert(name).inserted, let state = machine["state"] as? String else { throw CoreRPCError.malformed }
                if state == "connected" { connected.insert(name) }
            }
            return MachineAvailability(known: known, connected: connected)
        } catch {
            reconnect()
            throw error
        }
    }

    /// Hello and the PID check run once per connection: the kernel pins the peer PID for that socket.
    private func prepareConnection() throws {
        guard !isCancelled else { throw CoreRPCError.unavailable }
        if currentFD < 0 { resetAndReconnect() }
        guard currentFD >= 0 else { throw CoreRPCError.unavailable }
        deadline = MonotonicClock.now() + seconds(deadlineSeconds)
        if !handshaken {
            let hello = try call(method: "hello", params: ["generation": 1, "framed": false])
            guard let result = hello["result"] as? [String: Any], result["generation"] as? Int == 1 else { throw CoreRPCError.malformed }
            let status = try call(method: "server.status", params: [:])
            guard let server = status["result"] as? [String: Any], Self.matchesPID(server["pid"], pid) else { throw CoreRPCError.identityChanged }
            handshaken = true
        }
    }

    private var currentFD: Int32 { stateLock.lock(); defer { stateLock.unlock() }; return fd }
    private var isCancelled: Bool { stateLock.lock(); defer { stateLock.unlock() }; return cancelled }

    private func call(method: String, params: [String: Any], maxBytes: Int = AgentListParser.maxBytes) throws -> [String: Any] {
        let id = requestID; requestID += 1
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        var bytes = try JSONSerialization.data(withJSONObject: request); bytes.append(10)
        try writeAll(bytes)
        let response = try readLine(maxBytes: maxBytes)
        guard let object = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any],
              object["id"] as? Int == id, object["error"] == nil else { throw CoreRPCError.malformed }
        return object
    }

    private func writeAll(_ data: Data) throws {
        let socket = currentFD
        var offset = 0
        while offset < data.count {
            try wait(fd: socket, events: Int16(POLLOUT))
            let count = data.withUnsafeBytes { send(socket, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw CoreRPCError.unavailable }
            offset += count
        }
    }

    private func readLine(maxBytes: Int = AgentListParser.maxBytes) throws -> Data {
        let socket = currentFD
        var chunk = [UInt8](repeating: 0, count: 8192)
        var scanned = readBuffer.startIndex // Only bytes read since the last scan can hold the newline: keeps large lines linear.
        while true {
            if let newline = readBuffer[scanned...].firstIndex(of: 10) {
                let line = Data(readBuffer[..<newline])
                readBuffer.removeSubrange(...newline)
                guard line.count <= maxBytes else { throw CoreRPCError.oversized }
                return line
            }
            guard readBuffer.count <= maxBytes else { throw CoreRPCError.oversized }
            scanned = readBuffer.endIndex
            try wait(fd: socket, events: Int16(POLLIN))
            let count = recv(socket, &chunk, chunk.count, 0)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw CoreRPCError.unavailable }
            readBuffer.append(contentsOf: chunk[..<count])
        }
    }

    private func wait(fd: Int32, events: Int16) throws {
        let now = MonotonicClock.now()
        guard now < deadline else { throw CoreRPCError.timeout }
        var item = pollfd(fd: fd, events: events, revents: 0)
        let milliseconds = Int32(max(1, min(Int64(Int32.max), Int64((deadline - now) / 1_000_000))))
        let result = poll(&item, 1, milliseconds)
        guard result > 0 else { throw result == 0 ? CoreRPCError.timeout : CoreRPCError.unavailable }
        if isCancelled { throw CoreRPCError.unavailable }
    }

    private func resetAndReconnect() {
        closeTransport()
        guard !isCancelled, let connection = Self.connect(socketPath) else { return }
        guard connection.pid == pid else { close(connection.fd); return }
        stateLock.lock()
        if cancelled { stateLock.unlock(); close(connection.fd); return }
        fd = connection.fd; handshaken = false; requestID = 1
        readBuffer.removeAll(keepingCapacity: false)
        stateLock.unlock()
    }

    private func closeTransport() {
        stateLock.lock(); let old = fd; fd = -1; stateLock.unlock()
        if old >= 0 { close(old) }
        readBuffer.removeAll(keepingCapacity: false)
    }

    private static func matchesPID(_ value: Any?, _ pid: pid_t) -> Bool {
        guard let number = value as? NSNumber else { return false }
        let kind = String(cString: number.objCType)
        return ["q", "Q", "i", "I", "l", "L", "s", "S"].contains(kind) && number.stringValue == String(pid)
    }

    private static func connect(_ path: String) -> (fd: Int32, pid: pid_t)? {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) { setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size)) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { close(socket); return nil }
            var descriptor = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, 500) > 0 else { close(socket); return nil }
            var error: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { close(socket); return nil }
        }
        guard let peer = peerPID(socket), peer > 1 else { close(socket); return nil }
        var credentials = xucred(); var size = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(socket, 0, LOCAL_PEERCRED, &credentials, &size) == 0, credentials.cr_uid == getuid() else {
            close(socket); return nil
        }
        return (socket, peer)
    }

    private static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0; var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, 0, LOCAL_PEERPID, &pid, &size) == 0 else { return nil }
        return pid
    }
}
