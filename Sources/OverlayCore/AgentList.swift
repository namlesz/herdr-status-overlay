import Foundation

/// Raw status reported by the Herdr server for one agent.
public enum ServerStatus: String {
    case working, blocked, done, idle, unknown
}

/// Identity of an agent inside one source. `terminal_id` changes when the pane gets a new terminal.
public struct AgentKey: Hashable, Comparable {
    public let paneID: String
    public let terminalID: String?

    public init(paneID: String, terminalID: String?) {
        self.paneID = paneID
        self.terminalID = terminalID
    }

    public static func < (a: AgentKey, b: AgentKey) -> Bool {
        (a.paneID, a.terminalID ?? "") < (b.paneID, b.terminalID ?? "")
    }
}

/// Allowlisted projection of one `agent list` entry. Everything else in the response is dropped.
public struct AgentRecord {
    public let key: AgentKey
    public let label: String
    /// Final `cwd` component, else `workspace_id`.
    public let place: String?
    public let activity: String?
    public let status: ServerStatus
    public let completionSeq: UInt64?
}

public enum ParseError: Error, Equatable {
    case oversized, malformed, tooManyAgents, duplicate
    case invalidField(String)
}

public enum AgentListParser {
    public static let maxBytes = 1 << 20
    public static let maxAgents = 4096

    /// Parses `{"result":{"agents":[...]}}` as printed by `herdr agent list`.
    public static func parse(_ data: Data) throws -> [AgentRecord] {
        guard data.count <= maxBytes else { throw ParseError.oversized }
        guard String(data: data, encoding: .utf8) != nil,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let agents = result["agents"] as? [Any] else { throw ParseError.malformed }
        guard agents.count <= maxAgents else { throw ParseError.tooManyAgents }

        var seen = Set<AgentKey>()
        return try agents.map { item in
            guard let object = item as? [String: Any] else { throw ParseError.malformed }
            let paneID = try identifier(object, "pane_id")
            guard let paneID else { throw ParseError.invalidField("pane_id") }
            let terminalID = try identifier(object, "terminal_id")
            let workspaceID = try identifier(object, "workspace_id")
            guard let rawStatus = object["agent_status"] as? String,
                  let status = ServerStatus(rawValue: rawStatus) else {
                throw ParseError.invalidField("agent_status")
            }
            let key = AgentKey(paneID: paneID, terminalID: terminalID)
            guard seen.insert(key).inserted else { throw ParseError.duplicate }

            let name = try optionalString(object, "name").map(Text.label)
            let kind = try optionalString(object, "agent").map(Text.label)
            let label = [kind, name].compactMap { $0 }.first { !$0.isEmpty } ?? paneID
            let cwd = try optionalString(object, "cwd").map { Text.label(($0 as NSString).lastPathComponent) }
            let activity = try optionalString(object, "terminal_title_stripped").map(Text.label)
            return AgentRecord(key: key, label: label,
                               place: cwd.flatMap { $0.isEmpty ? nil : $0 } ?? workspaceID,
                               activity: activity.flatMap { $0.isEmpty ? nil : $0 },
                               status: status, completionSeq: try sequence(object, "completion_seq"))
        }
    }

    private static func optionalString(_ object: [String: Any], _ field: String) throws -> String? {
        switch object[field] {
        case nil, is NSNull: return nil
        case let value as String: return value
        default: throw ParseError.invalidField(field)
        }
    }

    /// IDs are never rewritten: an ID the UI could not show safely rejects the whole snapshot.
    private static func identifier(_ object: [String: Any], _ field: String) throws -> String? {
        guard let value = try optionalString(object, field) else { return nil }
        guard Text.isIdentifier(value) else { throw ParseError.invalidField(field) }
        return value
    }

    private static func sequence(_ object: [String: Any], _ field: String) throws -> UInt64? {
        switch object[field] {
        case nil, is NSNull: return nil
        case let number as NSNumber:
            // JSONSerialization uses 'c' for booleans and 'd'/'f' for fractions.
            let type = String(cString: number.objCType)
            guard ["q", "Q", "i", "I", "l", "L", "s", "S"].contains(type), number.int64Value >= 0 else {
                throw ParseError.invalidField(field)
            }
            return number.uint64Value
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

    /// Replaces control and line separators with spaces, collapses whitespace and cuts to
    /// `maxBytes` of UTF-8 on a character boundary.
    public static func label(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            if isUnsafe(scalar) || scalar.properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if pendingSpace { scalars.append(" ") }
            pendingSpace = false
            scalars.append(scalar)
        }
        let text = String(scalars)
        guard text.utf8.count > maxBytes else { return text }
        var result = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > maxBytes { break }
            result.append(character)
            bytes += size
        }
        while result.last == " " { result.removeLast() }
        return result
    }
}
