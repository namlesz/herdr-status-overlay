/// Pixel mascot state selected from usable sections, with blocked work taking priority.
public enum MascotMood: Equatable {
    case sleeping, working, pairWorking, blocked, unavailable, celebrating

    public static func select(in sections: [SectionView], now: UInt64) -> MascotMood {
        let fresh = sections.filter { $0.shouldDisplay && !$0.stale }
        let rows = fresh.flatMap(\.rows)
        let workingCount = Self.workingCount(in: sections)
        if rows.contains(where: { $0.status == .blocked }) { return .blocked }
        if rows.contains(where: { row in
            guard let eventAt = row.completionEventAt else { return false }
            return now >= eventAt && now - eventAt < seconds(3)
        }) { return .celebrating }
        if workingCount >= 2 { return .pairWorking }
        if workingCount > 0 { return .working }
        return fresh.isEmpty ? .unavailable : .sleeping
    }

    public static func workingCount(in sections: [SectionView]) -> Int {
        sections.filter { $0.shouldDisplay && !$0.stale }
            .flatMap(\.rows).filter { $0.status == .working }.count
    }
}

/// One illustrated mascot frame; `resourceName` is the bundled PNG without extension.
public enum MascotFrame: String, CaseIterable {
    case pairChase0 = "pair-chase-0", pairChase1 = "pair-chase-1", pairChase2 = "pair-chase-2", pairChase3 = "pair-chase-3"
    case pairTug0 = "pair-tug-0", pairTug1 = "pair-tug-1", pairTug2 = "pair-tug-2", pairTug3 = "pair-tug-3"
    case pairFetch0 = "pair-fetch-0", pairFetch1 = "pair-fetch-1", pairFetch2 = "pair-fetch-2", pairFetch3 = "pair-fetch-3"
    case pairWrestle0 = "pair-wrestle-0", pairWrestle1 = "pair-wrestle-1", pairWrestle2 = "pair-wrestle-2", pairWrestle3 = "pair-wrestle-3"
    case pairHop0 = "pair-hop-0", pairHop1 = "pair-hop-1", pairHop2 = "pair-hop-2", pairHop3 = "pair-hop-3"
    case pairDig0 = "pair-dig-0", pairDig1 = "pair-dig-1", pairDig2 = "pair-dig-2", pairDig3 = "pair-dig-3"
    case pairSplash0 = "pair-splash-0", pairSplash1 = "pair-splash-1", pairSplash2 = "pair-splash-2", pairSplash3 = "pair-splash-3"
    case pairSteal0 = "pair-steal-0", pairSteal1 = "pair-steal-1", pairSteal2 = "pair-steal-2", pairSteal3 = "pair-steal-3"
    case pairEnter0 = "pair-enter-0", pairEnter1 = "pair-enter-1", pairEnter2 = "pair-enter-2", pairEnter3 = "pair-enter-3"
    case pairExit0 = "pair-exit-0", pairExit1 = "pair-exit-1", pairExit2 = "pair-exit-2", pairExit3 = "pair-exit-3"
    case run0 = "run-0", run1 = "run-1", run2 = "run-2", run3 = "run-3"
    case sniff0 = "sniff-0", sniff1 = "sniff-1", sniff2 = "sniff-2", sniff3 = "sniff-3"
    case splash0 = "splash-0", splash1 = "splash-1", splash2 = "splash-2", splash3 = "splash-3"
    case dig0 = "dig-0", dig1 = "dig-1", dig2 = "dig-2", dig3 = "dig-3"
    case tug0 = "tug-0", tug1 = "tug-1", tug2 = "tug-2", tug3 = "tug-3"
    case roll0 = "roll-0", roll1 = "roll-1", roll2 = "roll-2", roll3 = "roll-3"
    case fetch0 = "fetch-0", fetch1 = "fetch-1", fetch2 = "fetch-2", fetch3 = "fetch-3"
    case flip0 = "flip-0", flip1 = "flip-1", flip2 = "flip-2", flip3 = "flip-3"
    case blocked, blocked1 = "blocked-1", blocked2 = "blocked-2", blocked3 = "blocked-3"
    case sleeping, celebrating, unavailable, standing

    public var resourceName: String { rawValue }
}

/// Work activities are selected only at sequence boundaries, never per frame.
public enum MascotActivity: CaseIterable {
    case running, sniffing, splashing, digging, tugging, rolling, fetching

    public var durationTicks: Int { self == .sniffing ? 16 : 32 }

    public func randomSuccessor() -> MascotActivity {
        Self.allCases.filter { $0 != self }.randomElement()!
    }

    fileprivate var frames: [MascotFrame] {
        switch self {
        case .running: return [.run0, .run1, .run2, .run3]
        case .sniffing: return [.sniff0, .sniff1, .sniff2, .sniff3]
        case .splashing: return [.splash0, .splash1, .splash2, .splash3]
        case .digging: return [.dig0, .dig1, .dig2, .dig3]
        case .tugging: return [.tug0, .tug1, .tug2, .tug3]
        case .rolling: return [.roll0, .roll1, .roll2, .roll3]
        case .fetching: return [.fetch0, .fetch1, .fetch2, .fetch3]
        }
    }
}
/// The eight group scenes; a shuffled bag avoids repetition at sequence boundaries.
public enum PairActivity: CaseIterable, Hashable {
    case chase, tug, fetch, wrestle, hop, dig, splash, steal

    fileprivate var frames: [MascotFrame] {
        switch self {
        case .chase: return [.pairChase0, .pairChase1, .pairChase2, .pairChase3]
        case .tug: return [.pairTug0, .pairTug1, .pairTug2, .pairTug3]
        case .fetch: return [.pairFetch0, .pairFetch1, .pairFetch2, .pairFetch3]
        case .wrestle: return [.pairWrestle0, .pairWrestle1, .pairWrestle2, .pairWrestle3]
        case .hop: return [.pairHop0, .pairHop1, .pairHop2, .pairHop3]
        case .dig: return [.pairDig0, .pairDig1, .pairDig2, .pairDig3]
        case .splash: return [.pairSplash0, .pairSplash1, .pairSplash2, .pairSplash3]
        case .steal: return [.pairSteal0, .pairSteal1, .pairSteal2, .pairSteal3]
        }
    }
}

public struct PairActivityBag {
    private var remaining: [PairActivity] = []
    private var previous: PairActivity?

    public init() {}

    public mutating func next() -> PairActivity {
        if remaining.isEmpty {
            remaining = PairActivity.allCases.shuffled()
            if remaining.first == previous { remaining.append(remaining.removeFirst()) }
        }
        let activity = remaining.removeFirst()
        previous = activity
        return activity
    }
}

/// Drives entry, group activity, and exit without allowing stale pair frames after interruption.
public struct MascotPairAnimation {
    private enum State { case solo, entering(Int), playing(PairActivity, Int), exiting(Int), still(PairActivity) }
    private var state: State = .solo

    private var bag = PairActivityBag()

    public init() {}

    public var needsTicks: Bool {
        switch state { case .entering, .playing, .exiting: return true; case .solo, .still: return false }
    }

    public var isExiting: Bool {
        if case .exiting = state { return true }
        return false
    }

    public mutating func setActive(_ active: Bool, reduceMotion: Bool) {
        if reduceMotion {
            if active {
                if case .still = state { return }
                state = .still(bag.next())
            } else { state = .solo }
            return
        }
        switch (active, state) {
        case (true, .solo), (true, .exiting): state = .entering(0)
        case (true, .still): state = .playing(bag.next(), 0)
        // The first entry frame contains only the original dog, so there is no friend to send away yet.
        case (false, .entering(let tick)) where tick < 2: state = .solo
        case (false, .entering), (false, .playing): state = .exiting(0)
        case (false, .still): state = .solo
        default: break
        }
    }

    public mutating func interrupt() { state = .solo }

    public mutating func tick(visible: Bool = true) {
        guard visible else { return }
        switch state {
        case .entering(let tick): state = tick + 1 >= 8 ? .playing(bag.next(), 0) : .entering(tick + 1)
        case .playing(let activity, let tick):
            state = tick + 1 >= 32 ? .playing(bag.next(), 0) : .playing(activity, tick + 1)
        case .exiting(let tick): state = tick + 1 >= 8 ? .solo : .exiting(tick + 1)
        case .solo, .still: break
        }
    }

    public func frame(reduceMotion: Bool) -> MascotFrame? {
        if reduceMotion {
            if case .still(let activity) = state { return activity.frames[0] }
            return nil
        }
        switch state {
        case .entering(let tick): return [.pairEnter0, .pairEnter1, .pairEnter2, .pairEnter3][tick / 2]
        case .playing(let activity, let tick): return activity.frames[(tick / 2) % 4]
        case .exiting(let tick): return [.pairExit0, .pairExit1, .pairExit2, .pairExit3][tick / 2]
        case .solo, .still: return nil
        }
    }
}


/// Frame and vertical offset for an animation tick; ticks are `MascotAnimation.tickInterval` apart.
public enum MascotAnimation {
    public static let tickInterval = 0.125
    static let stop: [MascotFrame] = [.blocked, .blocked1, .blocked2, .blocked3]

    /// Static poses need no animation ticks; hover and celebration expiry are separate concerns.
    public static func isAnimated(for mood: MascotMood, reduceMotion: Bool) -> Bool {
        !reduceMotion && mood != .unavailable
    }

    public static func frame(for mood: MascotMood, tick: Int, reduceMotion: Bool,
                             activity: MascotActivity = .running) -> MascotFrame {
        switch mood {
        case .working, .pairWorking:
            guard !reduceMotion else { return .standing }
            let phase = positive(tick, activity.durationTicks)
            return activity.frames[phase / (activity == .running ? 1 : 2) % 4]
        case .sleeping: return .sleeping
        case .blocked: return reduceMotion ? .blocked : stop[positive(tick, 16) / 4]
        case .celebrating: return .celebrating
        case .unavailable: return .unavailable
        }
    }

    /// A Space change plays once for one second; STOP and Reduce Motion always win.
    public static func flipFrame(for mood: MascotMood, elapsed: Double, reduceMotion: Bool) -> MascotFrame? {
        guard mood != .blocked, !reduceMotion, elapsed >= 0, elapsed < 1 else { return nil }
        return [MascotFrame.flip0, .flip1, .flip2, .flip3][Int(elapsed / 0.25)]
    }

    /// Points to lift the art: slow breathing while asleep, little hops while celebrating, otherwise still.
    public static func lift(for mood: MascotMood, tick: Int, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 0 }
        switch mood {
        case .sleeping: return positive(tick, 24) < 12 ? 1 : 0
        case .celebrating: return [0, 3, 5, 3][positive(tick, 4)]
        case .working, .pairWorking, .blocked, .unavailable: return 0
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
