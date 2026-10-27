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
public enum MascotFrame: String, CaseIterable {
    case run0 = "run-0", run1 = "run-1", run2 = "run-2", run3 = "run-3"
    case sniff0 = "sniff-0", sniff1 = "sniff-1", sniff2 = "sniff-2", sniff3 = "sniff-3"
    case splash0 = "splash-0", splash1 = "splash-1", splash2 = "splash-2", splash3 = "splash-3"
    case dig0 = "dig-0", dig1 = "dig-1", dig2 = "dig-2", dig3 = "dig-3"
    case tug0 = "tug-0", tug1 = "tug-1", tug2 = "tug-2", tug3 = "tug-3"
    case roll0 = "roll-0", roll1 = "roll-1", roll2 = "roll-2", roll3 = "roll-3"
    case fetch0 = "fetch-0", fetch1 = "fetch-1", fetch2 = "fetch-2", fetch3 = "fetch-3"
    case blocked, blocked1 = "blocked-1", blocked2 = "blocked-2", blocked3 = "blocked-3"
    case sleeping, celebrating, unavailable, standing

    public var resourceName: String { rawValue }
}

/// Frame and vertical offset for an animation tick; ticks are `MascotAnimation.tickInterval` apart.
public enum MascotAnimation {
    public static let tickInterval = 0.125
    /// Work: run for 4 s, sniff for 2 s, then five 4 s play activities; repeat.
    static let runTicks = 32, sniffTicks = 16
    static let run: [MascotFrame] = [.run0, .run1, .run2, .run3]
    static let sniff: [MascotFrame] = [.sniff0, .sniff1, .sniff2, .sniff3]
    static let playTicks = 32
    static let play: [[MascotFrame]] = [
        [.splash0, .splash1, .splash2, .splash3],
        [.dig0, .dig1, .dig2, .dig3],
        [.tug0, .tug1, .tug2, .tug3],
        [.roll0, .roll1, .roll2, .roll3],
        [.fetch0, .fetch1, .fetch2, .fetch3],
    ]
    static let stop: [MascotFrame] = [.blocked, .blocked1, .blocked2, .blocked3]

    public static func frame(for mood: MascotMood, tick: Int, reduceMotion: Bool) -> MascotFrame {
        switch mood {
        case .working:
            guard !reduceMotion else { return .standing }
            let phase = positive(tick, runTicks + sniffTicks + playTicks * play.count)
            if phase < runTicks { return run[phase % run.count] }
            if phase < runTicks + sniffTicks { return sniff[(phase - runTicks) / 2 % sniff.count] }
            let playTick = phase - runTicks - sniffTicks
            let frames = play[playTick / playTicks]
            return frames[playTick % playTicks / 2 % frames.count]
        case .sleeping: return .sleeping
        case .blocked: return reduceMotion ? .blocked : stop[positive(tick, 16) / 4]
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

    /// Three staggered letters drift through a three-second loop; Reduce Motion freezes the trail.
    public static func sleepPhases(tick: Int, reduceMotion: Bool) -> [Double] {
        (0..<3).map { index in
            reduceMotion ? Double(index + 1) / 4 : Double(positive(tick + index * 8, 24)) / 24
        }
    }

    private static func positive(_ tick: Int, _ period: Int) -> Int { (tick % period + period) % period }
}
