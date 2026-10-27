import Foundation

/// Direction of the list relative to the mascot (screen coordinates).
public enum PanelDirection: String, Codable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    public var extendsLeft: Bool { self == .topLeft || self == .bottomLeft }
    public var extendsUp: Bool { self == .topLeft || self == .topRight }

    public var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}
/// Persisted panel preferences and top-left offset inside a screen's visible frame.
public struct PanelState: Codable {
    public var visible = true
    public var minimized = false
    public var autoHide = false
    public var direction: PanelDirection = .topLeft
    /// Older manual-mode files stored the full panel, not the fixed mascot footprint.
    public var mascotAnchored = false

    public var screen: UInt32?
    public var left: Double?
    public var top: Double?

    public init() {}

    public func showsCompact(hovered: Bool) -> Bool { autoHide ? !hovered : minimized }

    private enum CodingKeys: String, CodingKey { case visible, minimized, autoHide, direction, mascotAnchored, screen, left, top }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        visible = try values.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        minimized = try values.decodeIfPresent(Bool.self, forKey: .minimized) ?? false
        autoHide = try values.decodeIfPresent(Bool.self, forKey: .autoHide) ?? false
        direction = try values.decodeIfPresent(PanelDirection.self, forKey: .direction) ?? .topLeft
        mascotAnchored = try values.decodeIfPresent(Bool.self, forKey: .mascotAnchored) ?? false
        screen = try values.decodeIfPresent(UInt32.self, forKey: .screen)
        left = try values.decodeIfPresent(Double.self, forKey: .left)
        top = try values.decodeIfPresent(Double.self, forKey: .top)
    }
}
