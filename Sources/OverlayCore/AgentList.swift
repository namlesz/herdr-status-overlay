import Foundation
import CoreFoundation

public enum ServerStatus: String { case working, blocked, done, idle, unknown }

public struct AgentKey: Hashable, Comparable {
    public let paneID: String
    public let terminalID: String?
    public init(paneID: String, terminalID: String? = nil) { self.paneID = paneID; self.terminalID = terminalID }
    public static func == (a: AgentKey, b: AgentKey) -> Bool { a.paneID == b.paneID }
    public func hash(into hasher: inout Hasher) { hasher.combine(paneID) }
    public static func < (a: AgentKey, b: AgentKey) -> Bool { a.paneID < b.paneID }
}

public struct AgentRecord {
    public let key: AgentKey
    public let label: String
    public let place: String?
    public let activity: String?
    public let status: ServerStatus


}

public enum ParseError: Error, Equatable { case oversized, malformed, tooManyAgents, duplicate, invalidField(String) }

public enum AgentListParser {
    public static let maxBytes = 1 << 20
    public static let maxAgents = 4096

    /// Parses the aggregated `terminal.list` JSON-RPC result; historical finished terminals are ignored.
    public static func parse(_ data: Data) throws -> [AgentRecord] {
        guard data.count <= maxBytes else { throw ParseError.oversized }
        guard String(data: data, encoding: .utf8) != nil,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let terminals = result["terminals"] as? [[String: Any]] else { throw ParseError.malformed }
        guard terminals.count <= maxAgents else { throw ParseError.tooManyAgents }
        var seen = Set<String>()
        return try terminals.compactMap { terminal in
            guard let address = terminal["address"] as? String, Text.isIdentifier(address) else { throw ParseError.invalidField("address") }
            guard seen.insert(address).inserted else { throw ParseError.duplicate }
            guard let state = terminal["state"] as? String, ["live", "finished"].contains(state) else { throw ParseError.invalidField("state") }
            guard state == "live" else { return nil }
            let status: [String: Any]?
            switch terminal["status"] {
            case nil, is NSNull: status = nil
            case let value as [String: Any]: status = value
            default: throw ParseError.invalidField("status")
            }
            guard let reportedValue = terminal["reported"] as? NSNumber,
                  CFGetTypeID(reportedValue) == CFBooleanGetTypeID() else { throw ParseError.invalidField("reported") }
            let reported = reportedValue.boolValue
            if !reported { return nil }
            guard let status else { return nil }
            let rawStatus = status["state"] as? String
            if rawStatus == nil { throw ParseError.invalidField("status.state") }
            let mapped: ServerStatus
            switch rawStatus {
            case "working": mapped = .working
            case "blocked", "error": mapped = .blocked
            case "done": mapped = .done
            case "idle": mapped = .idle
            case .some: mapped = .unknown
            case nil: mapped = .unknown
            }
            let title = try optionalString(terminal, "title")
            let cwd = try optionalString(terminal, "cwd")
            let app = try optionalString(status, "app")
            let msg = try optionalString(status, "msg")
            let kind = try optionalString(status, "kind")
            let place = cwd.map { Text.label(($0 as NSString).lastPathComponent) }.flatMap { $0.isEmpty ? nil : $0 }
            let label = [app, kind].compactMap { $0 }.map(Text.label).first { !$0.isEmpty } ?? address
            let activity = [msg, title].compactMap { $0 }.map(Text.label).first { !$0.isEmpty }
            return AgentRecord(key: AgentKey(paneID: address), label: label, place: place,
                               activity: activity, status: mapped)
        }
    }

    private static func optionalString(_ object: [String: Any], _ field: String) throws -> String? {
        switch object[field] {
        case nil, is NSNull: return nil
        case let value as String: return value
        default: throw ParseError.invalidField(field)
        }
    }
}

public enum Text {
    public static let maxBytes = 1024
    static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return v <= 0x1f || (0x7f...0x9f).contains(v) || v == 0x2028 || v == 0x2029
    }
    public static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maxBytes && !value.unicodeScalars.contains(where: isUnsafe)
    }
    public static func label(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView(); var pendingSpace = false
        for scalar in raw.unicodeScalars {
            if isUnsafe(scalar) || scalar.properties.isWhitespace { pendingSpace = !scalars.isEmpty; continue }
            if pendingSpace { scalars.append(" ") }; pendingSpace = false; scalars.append(scalar)
        }
        let text = String(scalars)
        guard text.utf8.count > maxBytes else { return text }
        var result = "", bytes = 0
        for character in text { let size = String(character).utf8.count; if bytes + size > maxBytes { break }; result.append(character); bytes += size }
        while result.last == " " { result.removeLast() }
        return result
    }
}
