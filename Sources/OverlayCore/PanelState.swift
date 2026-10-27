import Foundation

/// Persisted panel preferences and top-left offset inside a screen's visible frame.
public struct PanelState: Codable {
    public var visible = true
    public var minimized = false
    public var autoHide = false

    public var screen: UInt32?
    public var left: Double?
    public var top: Double?

    public init() {}

    public func showsCompact(hovered: Bool) -> Bool { autoHide ? !hovered : minimized }

    private enum CodingKeys: String, CodingKey { case visible, minimized, autoHide, screen, left, top }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        visible = try values.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        minimized = try values.decodeIfPresent(Bool.self, forKey: .minimized) ?? false
        autoHide = try values.decodeIfPresent(Bool.self, forKey: .autoHide) ?? false
        screen = try values.decodeIfPresent(UInt32.self, forKey: .screen)
        left = try values.decodeIfPresent(Double.self, forKey: .left)
        top = try values.decodeIfPresent(Double.self, forKey: .top)
    }
}
