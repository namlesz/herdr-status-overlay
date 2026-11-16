import CoreFoundation
import Foundation

public enum CoreEventError: Error { case malformed, tooManyTerminals, duplicate }

/// Applies generation 1 notifications to a bounded terminal cache.
public struct CoreEventReducer {
    public private(set) var sequence: UInt64
    private var terminals: [String: [String: Any]] = [:]
    private var encodedSizes: [String: Result<Int, Error>] = [:]
    private var addresses: [String] = []

    public init(snapshot: [String: Any]) throws {
        guard let seq = Self.sequence(snapshot["seq"]),
              let list = snapshot["terminals"] as? [[String: Any]] else { throw CoreEventError.malformed }
        guard list.count <= AgentListParser.maxAgents else { throw CoreEventError.tooManyTerminals }
        sequence = seq
        for terminal in list {
            guard let address = terminal["address"] as? String, Text.isIdentifier(address) else { throw CoreEventError.malformed }
            guard terminals[address] == nil else { throw CoreEventError.duplicate }
            store(terminal, address: address)
            addresses.append(address)
        }
    }

    public func currentRecords() throws -> [AgentRecord] {
        // Only explicit finished history is skipped; all other states are validated.
        let active = addresses.filter { terminals[$0]?["state"] as? String != "finished" }
        var bytes = #"{"result":{"terminals":[]}}"#.utf8.count + max(0, active.count - 1)
        for address in active { bytes += try encodedSizes[address]!.get() }
        guard bytes <= AgentListParser.maxBytes else { throw ParseError.oversized }
        return try AgentListParser.parseTerminals(active.compactMap { terminals[$0] })
    }

    /// nil means no displayed fields changed, not a new snapshot.
    public mutating func apply(_ message: [String: Any]) throws -> [AgentRecord]? {
        guard message["jsonrpc"] as? String == "2.0", message["id"] == nil,
              let method = message["method"] as? String, ["event", "heartbeat", "missed"].contains(method),
              let params = message["params"] as? [String: Any], let seq = Self.sequence(params["seq"]) else {
            throw CoreEventError.malformed
        }
        if seq < sequence || (seq == sequence && method == "event") { return nil }
        if method == "missed" {
            let replacement = try Self(snapshot: params)
            let records = try replacement.currentRecords()
            self = replacement
            return records
        }
        sequence = seq
        if method == "heartbeat" { return nil }
        guard let type = params["type"] as? String else { throw CoreEventError.malformed }
        if type == "doc" { return nil }
        guard let address = params["terminal"] as? String, Text.isIdentifier(address) else { throw CoreEventError.malformed }
        if type == "foreground", params["data"] is NSNull {
            try patch(address) { $0["foreground"] = NSNull() }
            return nil
        }
        guard let data = params["data"] as? [String: Any] else { throw CoreEventError.malformed }
        switch type {
        case "created", "restarted": try upsert(data, address: address)
        case "removed": terminals.removeValue(forKey: address); encodedSizes.removeValue(forKey: address); addresses.removeAll { $0 == address }
        case "status":
            guard data["status"] != nil, data["records"] is [String: Any],
                  let reported = data["reported"] as? NSNumber,
                  CFGetTypeID(reported) == CFBooleanGetTypeID() else { throw CoreEventError.malformed }
            try patch(address) { $0["status"] = data["status"]; $0["records"] = data["records"]; $0["reported"] = reported }
        case "turn": try patch(address) { $0["turn"] = data["turn"] }
        case "title": try patch(address) { $0["title"] = data["title"] }
        case "labels":
            if let record = data["record"] as? [String: Any] { try upsert(record, address: address) }
            else { try patch(address) { $0["labels"] = data["labels"] } }
        case "size": try patch(address) { $0["cols"] = data["cols"]; $0["rows"] = data["rows"] }; return nil
        case "foreground": try patch(address) { $0["foreground"] = data }; return nil
        case "keep": try patch(address) { $0["keep"] = data["keep"] }; return nil
        case "lost", "finished":
            // Finished history is a stub; a late "lost" must not revive it into a half-empty live record.
            if type == "lost", terminals[address]?["state"] as? String == "finished" { return nil }
            try patch(address) {
                $0["state"] = type == "lost" ? "live" : "finished"
                for key in ["reason", "exit_code", "signal", "finished_ms"] { $0[key] = data[key] ?? NSNull() }
                if type == "lost" { $0["pid"] = NSNull() }
                $0["foreground"] = NSNull()
            }
        default: throw CoreEventError.malformed
        }
        return try currentRecords()
    }

    private mutating func patch(_ address: String, _ update: (inout [String: Any]) -> Void) throws {
        guard var terminal = terminals[address] else { throw CoreEventError.malformed }
        update(&terminal)
        store(terminal, address: address)
    }

    private mutating func upsert(_ terminal: [String: Any], address: String) throws {
        guard terminal["address"] as? String == address else { throw CoreEventError.malformed }
        if terminals[address] == nil {
            guard terminals.count < AgentListParser.maxAgents else { throw CoreEventError.tooManyTerminals }
            addresses.append(address)
        }
        store(terminal, address: address)
    }

    private mutating func store(_ terminal: [String: Any], address: String) {
        let value = Self.freeze(Self.retained(terminal)) as! [String: Any]
        terminals[address] = value
        if value["state"] as? String == "finished" {
            encodedSizes.removeValue(forKey: address)
        } else {
            encodedSizes[address] = Result { try JSONSerialization.data(withJSONObject: value).count }
        }
    }

    // Snapshot nested Foundation containers and strings before caching their encoded size.
    private static func freeze(_ value: Any) -> Any {
        if let string = value as? String { return string }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues { freeze($0) } }
        if let array = value as? [Any] { return array.map { freeze($0) } }
        return value
    }
    /// Finished history keeps only its address and state: later metadata and removal events still apply, payloads do not stay.
    private static func retained(_ terminal: [String: Any]) -> [String: Any] {
        guard terminal["state"] as? String == "finished", let address = terminal["address"] else { return terminal }
        return ["address": address, "state": "finished"]
    }

    private static func sequence(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt64(number.stringValue)
    }
}
