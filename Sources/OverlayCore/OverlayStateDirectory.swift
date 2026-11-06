import Foundation

public enum OverlayStateDirectory {
    public static func resolve(home: String, xdgStateHome: String?, override: String? = nil) throws -> URL {
        let defaultURL = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? xdgStateHome.map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("herdr-status-overlay", isDirectory: true)
        } ?? URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/HerdrStatusOverlay", isDirectory: true)
        let legacyRoot = xdgStateHome ?? URL(fileURLWithPath: home).appendingPathComponent(".local/state").path
        let legacyURL = URL(fileURLWithPath: legacyRoot, isDirectory: true)
            .appendingPathComponent("herdr/plugins/local.status-overlay", isDirectory: true)
        let manager = FileManager.default
        let destination = defaultURL.appendingPathComponent("panel.json")
        let legacy = legacyURL.appendingPathComponent("panel.json")
        guard !manager.fileExists(atPath: destination.path), manager.fileExists(atPath: legacy.path) else { return defaultURL }
        try manager.createDirectory(at: defaultURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.copyItem(at: legacy, to: destination)
        return defaultURL
    }
}
