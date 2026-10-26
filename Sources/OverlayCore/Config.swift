import Foundation

public struct SourceConfig: Equatable {
    public let id: String
    public let label: String
    public let arguments: [String]
    public let interval: Double
    public let staleAfter: UInt64

    public static let retention = seconds(60)
    public static let finishedTTL = seconds(600)

    public init(id: String, label: String, arguments: [String], interval: Double, staleAfter: UInt64) {
        self.id = id
        self.label = label
        self.arguments = arguments
        self.interval = interval
        self.staleAfter = staleAfter
    }

    public static func local(executable: String) -> SourceConfig {
        SourceConfig(id: "local", label: "Local", arguments: [executable, "agent", "list"],
                     interval: 2, staleAfter: seconds(6))
    }

    public static func machine(_ alias: String, executable: String) -> SourceConfig {
        SourceConfig(id: "machine:" + alias, label: alias,
                     arguments: [executable, "--machine", alias, "agent", "list"],
                     interval: 5, staleAfter: seconds(20))
    }
}

/// `machines.txt` in the plugin config dir: one saved-machine alias per line, `#` comments.
public enum MachineList {
    public static let fileName = "machines.txt"
    public static let maxAliases = 16

    public struct Parsed: Equatable {
        public var aliases: [String] = []
        public var rejectedLines: [Int] = []

        public init() {}
    }

    /// Missing file means local only.
    public static func load(directory: URL) throws -> Parsed {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return Parsed() }
        let data = try Data(contentsOf: url)
        guard data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return parse(text)
    }

    public static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard isAlias(line), parsed.aliases.count < maxAliases else {
                parsed.rejectedLines.append(index + 1)
                continue
            }
            if !parsed.aliases.contains(line) { parsed.aliases.append(line) }
        }
        return parsed
    }

    /// Conservative: the alias becomes an argv element after `--machine`, never shell text.
    public static func isAlias(_ value: String) -> Bool {
        guard !value.hasPrefix("-"), value.utf8.count <= 128 else { return false }
        return !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._:@-".unicodeScalars.contains($0)
        }
    }
}
