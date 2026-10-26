import Foundation

/// One replaceable UI model and at most one scheduled delivery, even if the main thread is busy.
public final class LatestSections {
    private let lock = NSLock()
    private var sections: [SectionView] = []
    private var scheduled = false

    public init() {}

    /// True only when the caller must schedule a delivery.
    public func replace(_ value: [SectionView]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sections = value
        let enqueue = !scheduled
        scheduled = true
        return enqueue
    }

    public func take() -> [SectionView] {
        lock.lock()
        defer { lock.unlock() }
        scheduled = false
        return sections
    }
}
