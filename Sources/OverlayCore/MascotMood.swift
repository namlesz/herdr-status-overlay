/// Pixel mascot state selected from usable sections, with blocked work taking priority.
public enum MascotMood: Equatable {
    case sleeping, working, blocked, unavailable, celebrating

    public static func select(in sections: [SectionView], now: UInt64) -> MascotMood {
        let fresh = sections.filter { $0.shouldDisplay && !$0.stale }
        let rows = fresh.flatMap(\.rows)
        if rows.contains(where: { $0.status == .blocked }) { return .blocked }
        if rows.contains(where: { row in
            guard let eventAt = row.completionEventAt else { return false }
            return now >= eventAt && now - eventAt < seconds(3)
        }) { return .celebrating }
        if rows.contains(where: { $0.status == .working }) { return .working }
        return fresh.isEmpty ? .unavailable : .sleeping
    }
}

/// One illustrated mascot frame; `resourceName` is the bundled PNG without extension.
public enum MascotFrame: Equatable, CaseIterable {
    case run0, run1, run2, run3, sniff0, sniff1, sniff2, sniff3
    case sleeping, blocked, celebrating, unavailable

    public var resourceName: String {
        switch self {
        case .run0: return "run-0"
        case .run1: return "run-1"
        case .run2: return "run-2"
        case .run3: return "run-3"
        case .sniff0: return "sniff-0"
        case .sniff1: return "sniff-1"
        case .sniff2: return "sniff-2"
        case .sniff3: return "sniff-3"
        case .sleeping: return "sleeping"
        case .blocked: return "blocked"
        case .celebrating: return "celebrating"
        case .unavailable: return "unavailable"
        }
    }
}

/// Frame and vertical offset for an animation tick; ticks are `MascotAnimation.tickInterval` apart.
public enum MascotAnimation {
    public static let tickInterval = 0.125
    /// Working alternates 4 s running in place (8 fps) with 2 s sniffing (4 fps).
    static let runTicks = 32, sniffTicks = 16
    static let run: [MascotFrame] = [.run0, .run1, .run2, .run3]
    static let sniff: [MascotFrame] = [.sniff0, .sniff1, .sniff2, .sniff3]

    public static func frame(for mood: MascotMood, tick: Int, reduceMotion: Bool) -> MascotFrame {
        switch mood {
        case .working:
            // Reduce Motion: one still frame with all four paws down.
            guard !reduceMotion else { return .run3 }
            let phase = positive(tick, runTicks + sniffTicks)
            return phase < runTicks ? run[phase % run.count] : sniff[(phase - runTicks) / 2 % sniff.count]
        case .sleeping: return .sleeping
        case .blocked: return .blocked
        case .celebrating: return .celebrating
        case .unavailable: return .unavailable
        }
    }

    /// Points to lift the art: slow breathing while asleep, little hops while celebrating, otherwise still.
    public static func lift(for mood: MascotMood, tick: Int, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 0 }
        switch mood {
        case .sleeping: return positive(tick, 24) < 12 ? 1 : 0
        case .celebrating: return [0, 3, 5, 3][positive(tick, 4)]
        case .working, .blocked, .unavailable: return 0
        }
    }

    private static func positive(_ tick: Int, _ period: Int) -> Int { (tick % period + period) % period }
}
