import Foundation

public struct SourceConfig {
    public let id: String
    public let label: String
    public let command: [String]
    public let interval: Double
    public let staleAfter: UInt64
    public static let retention = seconds(60)

    public init(id: String, label: String, command: [String], interval: Double, staleAfter: UInt64) {
        self.id = id; self.label = label; self.command = command; self.interval = interval; self.staleAfter = staleAfter
    }

    public static func local(executable: String) -> SourceConfig {
        SourceConfig(id: "local", label: "Herdr", command: [executable], interval: 2, staleAfter: seconds(45))
    }

    public func focusArguments(paneID: String) -> [String]? {
        guard Text.isIdentifier(paneID), !paneID.hasPrefix("-") else { return nil }
        let environment = ProcessInfo.processInfo.environment
        if let executable = environment["HERDR_APP_BIN_PATH"] { return [executable, "do", "agent.focus", "--terminal", paneID] }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let candidates = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/herdr-app" }
            + [URL(fileURLWithPath: home).appendingPathComponent(".local/bin/herdr-app").path]
        if let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return [executable, "do", "agent.focus", "--terminal", paneID]
        }
        return ["/usr/bin/env", "herdr-app", "do", "agent.focus", "--terminal", paneID]
    }
}
