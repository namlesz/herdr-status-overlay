/// Hover expansion with a grace period for crossing from the mascot into the panel.
public struct AutoHideHover {
    public private(set) var expanded = false
    private var leftAt: Double?

    public init() {}

    @discardableResult
    public mutating func update(inside: Bool, now: Double) -> Bool {
        let previous = expanded
        if inside {
            expanded = true
            leftAt = nil
        } else if expanded {
            if let leftAt {
                if now - leftAt >= 0.4 { expanded = false }
            } else {
                leftAt = now
            }
        }
        return previous != expanded
    }
}
