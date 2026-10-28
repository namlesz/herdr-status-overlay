import Darwin
import Foundation
import CoreGraphics
import ImageIO
import OverlayCore

// Headless test suite: fixtures and /bin/sh fakes only. No Herdr, SSH or GUI.

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL [\(line)] \(name)")
    }
}

checkServerLifetime()

do {
    check(ThoughtBubble.opacity == 0.22, "thought cloud uses the approved 22 percent opacity")
    for width in [CGFloat(112), 240, 420] {
        let bounds = CGRect(x: 0, y: 0, width: width, height: 58)
        let tailX = width - 48
        let cloud = ThoughtBubble.path(in: bounds, tailX: tailX)
        check(bounds.contains(cloud.boundingBoxOfPath), "cloud and bubbles stay within their view")
        check(cloud.contains(CGPoint(x: width / 2, y: 38)), "cloud contains counter text center")
        check(!cloud.contains(CGPoint(x: 1, y: 57)) && !cloud.contains(CGPoint(x: width - 1, y: 57)),
              "thought cloud has transparent corners instead of a rectangular backdrop")
        check(cloud.contains(CGPoint(x: tailX + 5.5, y: 3.5))
              && cloud.contains(CGPoint(x: tailX + 1, y: 12)), "two thought bubbles point towards corgi")
        check(!cloud.contains(CGPoint(x: tailX + 4, y: 6.5)), "thought bubbles are separated by transparent space")
    }
    check(ThoughtBubble.path(in: .zero, tailX: 0).isEmpty, "empty cloud layout is safe")
}

func json(_ agents: [[String: Any]], extra: [String: Any] = [:]) -> Data {
    var root: [String: Any] = ["id": "x", "result": ["agents": agents]]
    root.merge(extra) { a, _ in a }
    return try! JSONSerialization.data(withJSONObject: root)
}

func agent(_ pane: String, _ status: String, seq: Any? = nil, terminal: String? = "t-1",
           name: Any? = nil) -> [String: Any] {
    var object: [String: Any] = ["pane_id": pane, "workspace_id": "w1", "agent_status": status,
                                 "agent": "claude", "cwd": "/private", "focused": false]
    if let seq { object["completion_seq"] = seq }
    if let terminal { object["terminal_id"] = terminal }
    if let name { object["name"] = name }
    return object
}

func parse(_ agents: [[String: Any]]) -> [AgentRecord] { try! AgentListParser.parse(json(agents)) }

func parseError(_ data: Data) -> ParseError? {
    do { _ = try AgentListParser.parse(data); return nil } catch { return error as? ParseError }
}

// MARK: Parser

do {
    let records = parse([agent("w1:p1", "idle", seq: 135, name: "  Bob\u{0007}\u{2028}x  "),
                         agent("w1:p2", "working", terminal: nil)])
    check(records.count == 2, "parses agents and ignores unknown fields")
    check(records[0].label == "claude", "agent kind takes priority over name")
    check(records[0].completionSeq == 135, "reads completion_seq")
    check(records[1].label == "claude", "falls back to agent type")
    check(records[1].key.terminalID == nil, "terminal_id is optional")
    check(records[0].place == "private", "place is final cwd component")

    var titled = agent("w1:p5", "working", name: "  Bob\u{0007}x  ")
    titled["agent"] = " "
    titled["cwd"] = "/work/herdr-status-overlay/"
    titled["terminal_title_stripped"] = "  Writing\n tests\u{0007} "
    let detail = parse([titled])[0]
    check(detail.label == "Bob x", "sanitized name is fallback when kind is empty")
    check(detail.place == "herdr-status-overlay", "place is final cwd component")
    check(detail.activity == "Writing tests", "activity is sanitized")
    titled["cwd"] = " "
    titled["terminal_title_stripped"] = "\n "
    check(parse([titled])[0].place == "w1" && parse([titled])[0].activity == nil, "empty place falls back, empty activity omitted")
    titled.removeValue(forKey: "cwd")
    titled.removeValue(forKey: "terminal_title_stripped")
    check(parse([titled])[0].place == "w1" && parse([titled])[0].activity == nil, "missing optional details")
    for field in ["agent", "name", "cwd", "terminal_title_stripped"] {
        var invalid = titled
        invalid[field] = 7
        check(parseError(json([invalid])) == .invalidField(field), "rejects non-string \(field)")
    }
    let unnamed = parse([agent("w1:p3", "idle", name: "\u{0085}\u{2029}")])
    check(unnamed[0].label == "claude", "empty sanitized name uses fallback")
    var bare = agent("w1:p4", "idle")
    bare.removeValue(forKey: "agent")
    check(parse([bare])[0].label == "w1:p4", "pane_id is the last label fallback")

    let long = String(repeating: "a", count: 1023) + "é" + "b"
    let cut = Text.label(long)
    check(cut.utf8.count <= 1024 && cut.hasSuffix("a") && !cut.contains("é"), "label cut on character boundary")
    check(Text.label("x\u{7f}y\u{9f}z") == "x y z", "DEL and C1 replaced")

    check(parseError(json([agent("w1:p1", "sleeping")])) == .invalidField("agent_status"), "unknown status rejected")
    check(parseError(json([["pane_id": 7, "agent_status": "idle"]])) == .invalidField("pane_id"), "pane_id type")
    check(parseError(json([agent("w1:p1", "idle", seq: true)])) == .invalidField("completion_seq"), "bool seq rejected")
    check(parseError(json([agent("w1:p1", "idle", seq: 1.5)])) == .invalidField("completion_seq"), "fraction seq rejected")
    check(parseError(json([agent("w1:p1", "idle", seq: -1)])) == .invalidField("completion_seq"), "negative seq rejected")
    check(parseError(json([agent("w1:p1", "idle", name: 3)])) == .invalidField("name"), "label type rejected")
    check(parseError(json([agent("w1:p1", "idle"), agent("w1:p1", "busy")])) != nil, "bad entry rejects snapshot")
    check(parseError(json([agent("w1:p1", "idle"), agent("w1:p1", "idle")])) == .duplicate, "duplicate rejected")
    check(parseError(json([agent("w1:\u{1b}p1", "idle")])) == .invalidField("pane_id"), "control char in id rejected")
    check(parseError(Data("{\"error\":{}}".utf8)) == .malformed, "error response rejected")
    check(parseError(Data([0xff, 0xfe])) == .malformed, "invalid UTF-8 rejected")
    check(parseError(Data(count: AgentListParser.maxBytes + 1)) == .oversized, "oversized rejected")
    let many = (0...AgentListParser.maxAgents).map { agent("p\($0)", "idle") }
    check(parseError(json(many)) == .tooManyAgents, "agent count bounded")
    var nulls = agent("w1:p1", "idle")
    nulls["completion_seq"] = NSNull()
    nulls["name"] = NSNull()
    check((try? AgentListParser.parse(json([nulls])))?.first?.completionSeq == nil, "null optionals accepted")
}

// MARK: Completions

do {
    var tracker = CompletionTracker()
    let key = AgentKey(paneID: "w1:p1", terminalID: "t-1")
    func step(_ status: String, _ seq: UInt64?) {
        tracker.apply(parse([agent("w1:p1", status, seq: seq.map { NSNumber(value: $0) })]), now: 0)
    }
    func displayed(_ status: String, _ seq: UInt64?) -> DisplayStatus {
        tracker.display(parse([agent("w1:p1", status, seq: seq.map { NSNumber(value: $0) })])[0], now: 0)
    }

    step("idle", 135)
    check(!tracker.isPending(key, now: 0), "baseline idle is not a completion")
    check(tracker.completionEventAt(key) == nil, "startup baseline has no celebration event")
    step("working", nil)
    check(!tracker.isPending(key, now: 0), "working without seq keeps marker")
    step("idle", 135)
    check(!tracker.isPending(key, now: 0), "same marker is not a completion")
    step("idle", 141)
    check(tracker.isPending(key, now: 0), "larger marker is a completion without seeing working")
    check(displayed("idle", 141) == .done, "pending idle shows done")
    check(displayed("working", nil) == .working, "working wins over pending done")
    check(displayed("blocked", nil) == .blocked, "blocked wins over pending done")
    check(displayed("done", 141) == .done, "server done with pending shows done")

    step("idle", 150)
    step("idle", 100)
    check(!tracker.isPending(key, now: 0), "regression resets without completion")
    step("idle", 120)
    check(tracker.isPending(key, now: 0), "new marker after reset counts")

    var fresh = CompletionTracker()
    fresh.apply(parse([agent("w1:p1", "working")]), now: 0)
    fresh.apply(parse([agent("w1:p1", "idle", seq: 7)]), now: 0)
    check(fresh.isPending(key, now: 0), "observed working then first marker is a completion")

    var cold = CompletionTracker()
    cold.apply(parse([agent("w1:p1", "idle")]), now: 0)
    cold.apply(parse([agent("w1:p1", "idle", seq: 7)]), now: 0)
    check(!cold.isPending(key, now: 0), "first marker without observed working is not a completion")

    check(cold.completionEventAt(key) == nil, "first marker without observed work has no event")

    var serverTransition = CompletionTracker()
    serverTransition.apply(parse([agent("w1:p1", "idle")]), now: 10)
    serverTransition.apply(parse([agent("w1:p1", "done")]), now: 20)
    check(serverTransition.completionEventAt(key) == 20, "known continuous transition to server done emits event")
    serverTransition.rebaseline()
    check(serverTransition.completionEventAt(key) == nil, "recovery clears celebration event")
    serverTransition.apply(parse([agent("w1:p1", "done")]), now: 30)
    check(serverTransition.completionEventAt(key) == nil, "recovery server done does not re-emit")


    var doneRegression = CompletionTracker()
    doneRegression.apply(parse([agent("w1:p1", "done", seq: 8)]), now: 10)
    doneRegression.apply(parse([agent("w1:p1", "done", seq: 4)]), now: 20)
    check(doneRegression.isPending(key, now: 20), "regressed sequence renews existing server-done display")
    check(doneRegression.completionEventAt(key) == nil, "sequence regression does not celebrate")
    check(!doneRegression.isPending(key, now: 20 + SourceConfig.finishedTTL),
          "regressed server-done display expires from its renewed timestamp")

    var earlyMarker = CompletionTracker()
    earlyMarker.apply(parse([agent("w1:p1", "idle")]), now: 0)
    earlyMarker.apply(parse([agent("w1:p1", "working", seq: 7)]), now: 0)
    earlyMarker.apply(parse([agent("w1:p1", "idle", seq: 7)]), now: 0)
    check(!earlyMarker.isPending(key, now: 0), "first marker on the first working snapshot is only a baseline")

    var identity = CompletionTracker()
    identity.apply(parse([agent("w1:p1", "idle", seq: 5)]), now: 0)
    identity.apply(parse([agent("w1:p1", "idle", seq: 9, terminal: "t-2")]), now: 0)
    check(!identity.isPending(AgentKey(paneID: "w1:p1", terminalID: "t-2"), now: 0), "new terminal is a new baseline")

    var removal = CompletionTracker()
    removal.apply(parse([agent("w1:p1", "idle", seq: 5)]), now: 0)
    removal.apply(parse([agent("w1:p1", "idle", seq: 6)]), now: 0)
    removal.apply(parse([]), now: 0)
    removal.apply(parse([agent("w1:p1", "idle", seq: 6)]), now: 0)
    check(!removal.isPending(key, now: 0), "removed agent drops pending and re-baselines")

    var recovery = CompletionTracker()
    recovery.apply(parse([agent("w1:p1", "idle", seq: 5), agent("w1:p2", "idle", seq: 1)]), now: 0)
    recovery.apply(parse([agent("w1:p1", "idle", seq: 6), agent("w1:p2", "idle", seq: 1)]), now: 0)
    recovery.rebaseline()
    recovery.apply(parse([agent("w1:p1", "idle", seq: 6), agent("w1:p2", "idle", seq: 9)]), now: 0)
    check(recovery.isPending(key, now: 0), "recovery keeps unexpired completion")
    check(!recovery.isPending(AgentKey(paneID: "w1:p2", terminalID: "t-1"), now: 0), "recovery never invents completion")

    var sticky = CompletionTracker()
    sticky.apply(parse([agent("w1:p1", "idle", seq: 1)]), now: 0)
    for seq in 2...5 { sticky.apply(parse([agent("w1:p1", "idle", seq: NSNumber(value: seq))]), now: 0) }
    check(sticky.isPending(key, now: 0), "one pending record per agent, not history")


    var moodStore = Store(sources: [.local(executable: "/fake")])
    func moodSnapshot(_ agents: [[String: Any]], at time: Double) -> [SectionView] {
        moodStore.succeed("local", generation: moodStore.begin("local"),
                          agents: parse(agents), now: seconds(time))
        return moodStore.view(now: seconds(time))
    }

    var moodViews = moodSnapshot([agent("w1:p1", "working", seq: 1)], at: 1)
    check(MascotMood.select(in: moodViews, now: seconds(1)) == .working, "working selects attentive mascot")
    moodViews = moodSnapshot([agent("w1:p1", "idle", seq: 1)], at: 2)
    check(MascotMood.select(in: moodViews, now: seconds(2)) == .sleeping, "fresh idle selects sleeping mascot")
    moodViews = moodSnapshot([agent("w1:p1", "idle", seq: 2), agent("w1:p2", "blocked")], at: 3)
    check(MascotMood.select(in: moodViews, now: seconds(3)) == .blocked, "blocked takes priority over celebration")
    moodViews = moodSnapshot([agent("w1:p1", "idle", seq: 2)], at: 4)
    check(MascotMood.select(in: moodViews, now: seconds(4)) == .celebrating, "completion marker selects celebration")
    check(MascotMood.select(in: moodViews, now: seconds(7)) == .sleeping, "celebration expires after three seconds")
    moodStore.fail("local", generation: moodStore.begin("local"), failure: .timeout)
    check(MascotMood.select(in: moodStore.view(now: seconds(8)), now: seconds(8)) == .unavailable,
          "stale-only sources select unavailable mascot")

    // Work preserves running/sniffing, then rotates through all five requested games.
    let tick = MascotAnimation.tickInterval
    check(MascotAnimation.frame(for: .working, tick: 0, reduceMotion: false) == .run0, "work starts running")
    check((0..<4).map { MascotAnimation.frame(for: .working, tick: $0, reduceMotion: false) }
          == [.run0, .run1, .run2, .run3], "run cycle steps through four frames")
    let sniffStart = Int(4 / tick)
    check(MascotAnimation.frame(for: .working, tick: sniffStart - 1, reduceMotion: false) == .run3,
          "running lasts four seconds")
    check((0..<8).map { MascotAnimation.frame(for: .working, tick: sniffStart + $0, reduceMotion: false) }
          == [.sniff0, .sniff0, .sniff1, .sniff1, .sniff2, .sniff2, .sniff3, .sniff3], "sniff cycle at half speed")
    let games: [[MascotFrame]] = [
        [.splash0, .splash1, .splash2, .splash3], [.dig0, .dig1, .dig2, .dig3],
        [.tug0, .tug1, .tug2, .tug3], [.roll0, .roll1, .roll2, .roll3],
        [.fetch0, .fetch1, .fetch2, .fetch3],
    ]
    for (index, frames) in games.enumerated() {
        let start = Int((6 + Double(index) * 4) / tick)
        let expected = (0..<32).map { frames[$0 / 2 % 4] }
        check((0..<32).map { MascotAnimation.frame(for: .working, tick: start + $0, reduceMotion: false) } == expected,
              "\(frames[0]) plays four distinct frames at 4 fps for four seconds")
    }
    let workPeriod = Int(26 / tick)
    check(MascotAnimation.frame(for: .working, tick: workPeriod, reduceMotion: false) == .run0,
          "running resumes after every game")
    check(MascotAnimation.frame(for: .working, tick: workPeriod - 1, reduceMotion: false) == .fetch3,
          "last game finishes before wrapping")
    for t in [Int.min, -209, -5, 0, 7, 40, 1_000_003, Int.max] {
        check(MascotAnimation.frame(for: .working, tick: t, reduceMotion: true) == .standing,
              "Reduce Motion keeps working on a still standing frame")
        check(MascotAnimation.frame(for: .working, tick: t, reduceMotion: false)
              == MascotAnimation.frame(for: .working, tick: (t % workPeriod + workPeriod) % workPeriod, reduceMotion: false),
              "work wraps safely for any tick")
        check(MascotAnimation.frame(for: .blocked, tick: t, reduceMotion: true) == .blocked,
              "Reduce Motion freezes the STOP pose")
    }
    let stopFrames: [MascotFrame] = [.blocked, .blocked1, .blocked2, .blocked3]
    check((0..<32).map { MascotAnimation.frame(for: .blocked, tick: $0, reduceMotion: false) }
          == (0..<32).map { stopFrames[$0 % 16 / 4] }, "STOP animation loops at 2 fps without work frames")
    for mood in [MascotMood.sleeping, .unavailable, .celebrating] {
        check(Set((0..<48).map { MascotAnimation.frame(for: mood, tick: $0, reduceMotion: false) }).count == 1,
              "\(mood) keeps its single state frame")
    }
    for mood in [MascotMood.sleeping, .working, .blocked, .unavailable, .celebrating] {
        check((0..<48).allSatisfy { MascotAnimation.lift(for: mood, tick: $0, reduceMotion: true) == 0 },
              "Reduce Motion stops \(mood) bobbing")
        check((0..<48).allSatisfy { (0...5).contains(MascotAnimation.lift(for: mood, tick: $0, reduceMotion: false)) },
              "\(mood) lift stays inside the view inset")
    }

    let stillSleep = MascotAnimation.sleepPhases(tick: 0, reduceMotion: true)
    for t in [-5, 0, 1, 23, 24, 1_000_003] {
        let phases = MascotAnimation.sleepPhases(tick: t, reduceMotion: false)
        check(phases.count == 3 && Set(phases).count == 3 && phases.allSatisfy { (0..<1).contains($0) },
              "three staggered sleep letters remain inside their animation cycle")
        check(MascotAnimation.sleepPhases(tick: t, reduceMotion: true) == stillSleep,
              "Reduce Motion freezes sleep letters")
    }
    check(MascotAnimation.sleepPhases(tick: 0, reduceMotion: false)
          != MascotAnimation.sleepPhases(tick: 1, reduceMotion: false), "sleep letters animate on each tick")
    check(MascotAnimation.sleepPhases(tick: 0, reduceMotion: false)
          == MascotAnimation.sleepPhases(tick: 24, reduceMotion: false), "sleep letters loop every three seconds")

    // Every selectable frame ships as a transparent PNG with a clear perimeter.
    let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../OverlayApp/Resources/Corgi").standardizedFileURL
    for frame in MascotFrame.allCases {
        let url = resources.appendingPathComponent(frame.resourceName + ".png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            check(false, "\(frame.resourceName).png loads"); continue
        }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        check(pixels.enumerated().contains { $0.offset % 4 == 3 && $0.element > 128 },
              "\(frame.resourceName).png contains visible artwork")
        let edge = (0..<image.width).flatMap { [($0, 0), ($0, image.height - 1), (0, $0), (image.width - 1, $0)] }
        check(image.width == image.height && image.alphaInfo != .none, "\(frame.resourceName).png is square with alpha")
        check(edge.allSatisfy { pixels[($0.1 * image.width + $0.0) * 4 + 3] == 0 },
              "\(frame.resourceName).png has a transparent perimeter")
    }
}

// MARK: Panel preferences and compact counters

do {
    let legacy = Data(#"{"visible":false,"screen":7,"left":42,"top":18}"#.utf8)
    var state = try! JSONDecoder().decode(PanelState.self, from: legacy)
    check(!state.minimized && !state.visible, "legacy panel state preserves visibility and defaults to expanded")
    check(state.screen == 7 && state.left == 42 && state.top == 18, "legacy panel placement survives migration")
    check(state.direction == .topLeft && !state.mascotAnchored, "legacy panel direction and placement format default safely")
    state.mascotAnchored = true
    for direction in PanelDirection.allCases {
        state.direction = direction
        let saved = try! JSONDecoder().decode(PanelState.self, from: JSONEncoder().encode(state))
        check(saved.direction == direction && saved.left == 42 && saved.mascotAnchored,
              "direction and canonical placement round-trip without losing position")
    }
    check(!state.autoHide, "legacy panel defaults to manual mode")
    for minimized in [false, true] {
        state.minimized = minimized
        check(state.showsCompact(hovered: false) == minimized && state.showsCompact(hovered: true) == minimized,
              "manual mode ignores hover")
        state.autoHide = true
        check(state.showsCompact(hovered: false) && !state.showsCompact(hovered: true),
              "auto-hide overrides manual mode only while enabled")
        let saved = try! JSONDecoder().decode(PanelState.self, from: JSONEncoder().encode(state))
        check(saved.autoHide && saved.minimized == minimized, "auto-hide and manual preference round-trip independently")
        state.autoHide = false
        let manual = try! JSONDecoder().decode(PanelState.self, from: JSONEncoder().encode(state))
        check(manual.minimized == minimized && !manual.autoHide && !manual.visible && manual.left == 42,
              "manual preference round-trips without losing visibility or placement")
    }
    var hover = AutoHideHover()
    check(!hover.update(inside: false, now: 0) && !hover.expanded, "auto-hide starts collapsed")
    check(hover.update(inside: true, now: 1) && hover.expanded, "entering expands")
    check(!hover.update(inside: false, now: 2) && hover.expanded, "exit starts grace period")
    check(!hover.update(inside: false, now: 2.39) && hover.expanded, "panel stays open during grace")
    check(!hover.update(inside: true, now: 2.4) && hover.expanded, "re-entry cancels collapse")
    check(!hover.update(inside: false, now: 3), "second exit starts a new grace period")
    check(hover.update(inside: false, now: 3.41) && !hover.expanded, "exit collapses after 0.4 seconds")
    check(!hover.update(inside: false, now: 10), "remaining outside does not rebuild")
    check(hover.update(inside: true, now: 11), "collapsed panel can expand again")

    var store = Store(sources: [.local(executable: "/fake"), .machine("box", executable: "/fake")])
    check(SectionView.activeCounts(in: []) == nil, "empty compact snapshot has no data")
    check(SectionView.activeCounts(in: store.view(now: 0)) == nil, "waiting compact snapshot is not zero agents")
    store.succeed("local", generation: 0,
                  agents: parse([agent("l1", "working"), agent("l2", "blocked"), agent("l3", "done"),
                                 agent("l4", "idle"), agent("l5", "unknown")]), now: 0)
    store.succeed("machine:box", generation: 0,
                  agents: parse([agent("r1", "working"), agent("r2", "done")]), now: 0)
    check(SectionView.activeCounts(in: store.view(now: 0)) == [.working: 2, .blocked: 1, .done: 2],
          "compact sums sources and excludes idle and unknown")
    store.fail("machine:box", generation: 0, failure: .timeout)
    check(SectionView.activeCounts(in: store.view(now: 0)) == [.working: 1, .blocked: 1, .done: 1],
          "compact excludes failed remote")
    store.succeed("local", generation: 0, agents: parse([agent("l3", "done")]), now: 0)
    check(SectionView.activeCounts(in: store.view(now: 0)) == [.done: 1],
          "compact removes working and blocked counters entirely when their agents disappear")
    store.succeed("local", generation: 0, agents: parse([agent("l1", "working")]), now: 0)
    check(SectionView.activeCounts(in: store.view(now: 0)) == [.working: 1],
          "compact keeps only the remaining nonzero status")
    check(SectionView.activeCounts(in: store.view(now: seconds(7))) == nil, "compact excludes stale local too")
    store.succeed("local", generation: 0, agents: parse([agent("l4", "idle")]), now: seconds(8))
    check(SectionView.activeCounts(in: store.view(now: seconds(8))) == [:], "fresh idle-only snapshot has no active agents")
    store.wake()
    check(SectionView.activeCounts(in: store.view(now: seconds(8))) == nil, "wake clears usable compact counts")
}

// MARK: Store, freshness, wake

do {
    let local = SourceConfig.local(executable: "/fake/herdr")
    let remote = SourceConfig.machine("box", executable: "/fake/herdr")
    var store = Store(sources: [local, remote])
    func displayed(_ now: UInt64) -> [String] {
        store.view(now: now).filter(\.shouldDisplay).map(\.id)
    }
    let t0: UInt64 = 1_000 * 1_000_000_000
    func section(_ id: String, _ now: UInt64) -> SectionView { store.view(now: now).first { $0.id == id }! }

    check(section("local", t0).problem == .waiting && section("local", t0).counts == nil, "no data yet is not zeros")
    var g = store.begin("local")
    store.succeed("local", generation: g, agents: parse([agent("w1:p1", "blocked"), agent("w1:p2", "idle", seq: 3)]), now: t0)
    var view = section("local", t0)
    check(view.counts?[.blocked] == 1 && view.counts?[.idle] == 1 && view.rows.map(\.status) == [.blocked, .idle],
          "counts, blocked row before idle row")
    check(section("machine:box", t0).problem == .waiting, "sources are independent")
    check(store.view(now: t0) == store.view(now: t0 + seconds(1)), "unchanged heartbeat gives equal view")
    check(displayed(t0) == ["local"], "remote is hidden until its first successful read")

    g = store.begin("local")
    store.succeed("local", generation: g, agents: parse([agent("w1:p2", "idle", seq: 3)]), now: t0 + seconds(2))
    check(section("local", t0 + seconds(2)).rows.map(\.key.paneID) == ["w1:p2"], "full replacement removes agents")

    view = section("local", t0 + seconds(9))
    check(view.stale && view.counts == nil && view.rows.count == 1 && view.problem == .outdated, "local stale after 6 s")

    g = store.begin("machine:box")
    store.succeed("machine:box", generation: g, agents: parse([agent("w9:p1", "idle", seq: 1)]), now: t0)
    check(!section("machine:box", t0 + seconds(19)).stale, "remote fresh before 20 s")
    check(section("machine:box", t0 + seconds(21)).stale, "remote stale after 20 s")
    check(displayed(t0 + seconds(19)) == ["local", "machine:box"], "fresh remote is shown")
    check(displayed(t0 + seconds(21)) == ["local"], "outdated remote is hidden, local stays")

    g = store.begin("machine:box")
    store.fail("machine:box", generation: g, failure: .timeout)
    check(section("machine:box", t0 + seconds(1)).problem == .failed(.timeout), "failure is immediately stale")
    check(section("local", t0 + seconds(2)).problem == nil, "remote failure does not touch local")
    check(displayed(t0 + seconds(2)) == ["local"], "failed remote is immediately hidden")

    store.expire(now: t0 + seconds(61))
    view = section("machine:box", t0 + seconds(61))
    check(view.rows.isEmpty && view.counts == nil, "cache dropped after 60 s, section kept")
    store.succeed("machine:box", generation: g, agents: [], now: t0 + seconds(62))
    check(displayed(t0 + seconds(62)) == ["local", "machine:box"], "successful reconnect restores even an empty remote")
    store.wake()
    check(displayed(t0 + seconds(63)) == ["local"], "wake hides remote until a fresh read")
    let remoteOnly = Store(sources: [remote]).view(now: t0).filter(\.shouldDisplay)
    check(remoteOnly.isEmpty, "no available cards leaves the panel empty")

    var waking = Store(sources: [local])
    g = waking.begin("local")
    waking.succeed("local", generation: g, agents: parse([agent("w1:p1", "idle", seq: 1)]), now: t0)
    let inFlight = waking.begin("local")
    waking.wake()
    check(!waking.succeed("local", generation: inFlight, agents: parse([agent("w1:p1", "idle", seq: 2)]),
                          now: t0 + seconds(1)), "read started before sleep is discarded")
    check(waking.view(now: t0 + seconds(1))[0].problem == .afterWake, "wake marks data stale")
    g = waking.begin("local")
    waking.succeed("local", generation: g, agents: parse([agent("w1:p1", "idle", seq: 2)]), now: t0 + seconds(2))
    check(waking.view(now: t0 + seconds(2))[0].rows.map(\.status) == [.idle], "first read after wake is a baseline")
    g = waking.begin("local")
    waking.succeed("local", generation: g, agents: parse([agent("w1:p1", "idle", seq: 3)]), now: t0 + seconds(3))
    let rows = waking.view(now: t0 + seconds(3))[0].rows
    check(rows.count == 1 && rows[0].status == .done, "completion after baseline listed")

    var sorting = Store(sources: [local])
    g = sorting.begin("local")
    sorting.succeed("local", generation: g, agents: parse([agent("w2:p1", "working"), agent("w1:p9", "blocked"),
                                                           agent("w1:p1", "blocked")]), now: t0)
    let ids = sorting.view(now: t0)[0].rows.map(\.key.paneID)
    check(ids == ["w1:p1", "w1:p9", "w2:p1"], "blocked rows precede working, sorted deterministically")
}


// MARK: Finished retention and detailed rows

do {
    var store = Store(sources: [SourceConfig.local(executable: "/fake")])
    func snapshot(_ status: String, _ time: Double, seq: Int = 1) -> SectionView {
        store.succeed("local", generation: store.begin("local"),
                      agents: parse([agent("w1:p1", status, seq: seq)]), now: seconds(time))
        return store.view(now: seconds(time))[0]
    }
    check(snapshot("done", 0).counts?[.done] == 1, "server done is finished on first snapshot")
    check(snapshot("done", 599).rows.first?.status == .done, "repeated server done stays until TTL")
    store.expire(now: seconds(600))
    let expired = store.view(now: seconds(600))[0]
    check(expired.rows.map(\.status) == [.idle] && expired.counts?[.idle] == 1, "server done expires exactly at 600 seconds")
    check(snapshot("done", 600).rows.map(\.status) == [.idle], "unchanged server done does not restart expiry")
    check(snapshot("working", 601).rows.first?.status == .working, "working row is visible")
    check(snapshot("idle", 602).rows.map(\.status) == [.idle], "working clears old completion")
    check(snapshot("done", 603).counts?[.done] == 1, "new server done transition starts a new finish")
    check(snapshot("working", 604, seq: 2).counts?[.done] == 0, "working clears completion even with a new marker")
    check(snapshot("idle", 605, seq: 2).rows.map(\.status) == [.idle], "cleared completion cannot resurface")
    check(snapshot("idle", 606, seq: 3).rows.first?.status == .done, "new completion marker still creates a finish")
    _ = snapshot("idle", 1205, seq: 3)
    check(store.view(now: seconds(1206))[0].rows.map(\.status) == [.idle], "marker-based finish expires after 600 seconds too")

    var detailed = agent("w1:p1", "working")
    detailed["cwd"] = "/repo/finance"
    detailed["terminal_title_stripped"] = "Writing tests"
    store.succeed("local", generation: store.begin("local"), agents: parse([detailed]), now: seconds(1207))
    let row = store.view(now: seconds(1207))[0].rows.first
    check(row?.place == "finance" && row?.activity == "Writing tests", "row carries place and activity")

    var a = agent("a", "working"), z = agent("z", "working")
    a["cwd"] = "/repo/zeta"
    z["cwd"] = "/repo/alpha"
    store.succeed("local", generation: store.begin("local"),
                  agents: parse([agent("idle", "idle"), agent("unknown", "unknown"), a, z, agent("blocked", "blocked"), agent("done", "done")]),
                  now: seconds(1208))
    check(store.view(now: seconds(1208))[0].rows.map(\.key.paneID) == ["blocked", "z", "a", "done", "unknown", "idle"],
          "rows sort blocked, working, done, unknown, idle, then place")
}

// MARK: Panel geometry (no AppKit or GUI)

do {
    let small = CGRect(x: 0, y: 0, width: 800, height: 600)
    let largeFrame = CGRect(x: 700, y: 900, width: 340, height: 800)
    let moved = PanelGeometry.clamp(largeFrame, to: small)
    check(moved.height == 240 && small.contains(moved), "smaller monitor caps panel to 40 percent")
    let anchored = PanelGeometry.clamp(CGRect(x: 20, y: 10, width: 340, height: 500), to: small)
    check(anchored.maxY == 510, "height clamp preserves panel top when possible")
    let desktop = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    for screen in [desktop, small, CGRect(x: 0, y: 0, width: 100, height: 200), CGRect(x: -1600, y: -200, width: 1600, height: 900)] {
        for point in [screen.origin, CGPoint(x: screen.maxX - 112, y: screen.maxY - 100)] {
            let dog = PanelGeometry.autoHideFrame(CGRect(origin: point, size: CGSize(width: 112, height: 100)),
                                                  expandedWidth: 420, in: screen)
            let full = PanelGeometry.autoHideFrame(CGRect(x: dog.maxX - 420, y: dog.minY,
                                                          width: 420, height: screen.height * 0.4),
                                                   expandedWidth: 420, in: screen)
            check(screen.contains(dog) && screen.contains(full), "both hover modes remain on screen")
            check(dog.maxX == full.maxX && dog.minY == full.minY, "hover keeps mascot bottom-right anchored at edges")
            let resting = PanelGeometry.bottomRightFrame(size: dog.size, of: full)
            let restoredOrigin = CGPoint(x: screen.minX + (resting.minX - screen.minX),
                                         y: screen.maxY - (screen.maxY - resting.maxY) - dog.height)
            let restored = PanelGeometry.autoHideFrame(CGRect(origin: restoredOrigin, size: dog.size),
                                                       expandedWidth: 420, in: screen)
            check(restored == dog, "saving expanded and restoring collapsed keeps the dog at the same position")
            check(PanelGeometry.autoHideFrame(dog, expandedWidth: 420, in: screen) == dog, "auto-hide geometry is stable")
            for bubbleSize in [CGSize(width: 112, height: 145), CGSize(width: 240, height: 145)] {
                let bubble = PanelGeometry.autoHideFrame(PanelGeometry.bottomRightFrame(size: bubbleSize, of: dog),
                                                         expandedWidth: 420, in: screen)
                check(bubble.maxX == full.maxX && bubble.minY == full.minY,
                      "bubble and expanded list keep the mascot in the same corner")
                let savedDog = PanelGeometry.bottomRightFrame(size: dog.size, of: bubble)
                let restoredBubble = PanelGeometry.bottomRightFrame(size: bubble.size, of: savedDog)
                check(restoredBubble == bubble, "canonical dog footprint restores the taller, wider bubble without shifting")
            }
        }
    }
    for direction in PanelDirection.allCases {
        for screen in [desktop, small, CGRect(x: -1600, y: -200, width: 1600, height: 900)] {
            for origin in [screen.origin, CGPoint(x: screen.maxX - 112, y: screen.maxY - 100)] {
                let dog = PanelGeometry.autoHideFrame(CGRect(origin: origin, size: CGSize(width: 112, height: 100)),
                                                     expandedWidth: 420, direction: direction, in: screen)
                for size in [CGSize(width: 112, height: 155), CGSize(width: 240, height: 155),
                             CGSize(width: 420, height: screen.height * 0.4)] {
                    let frame = PanelGeometry.autoHideFrame(
                        PanelGeometry.anchoredFrame(size: size, of: dog, direction: direction),
                        expandedWidth: 420, direction: direction, in: screen)
                    check(screen.contains(frame), "all directions fit at screen edges")
                    check(PanelGeometry.anchoredFrame(size: dog.size, of: frame, direction: direction) == dog,
                          "all directions keep canonical mascot position through resizing and restore")
                }
            }
        }
    }
    let compact = CGRect(x: 1700, y: 1000, width: 160, height: 40)
    check(PanelGeometry.clamp(compact, to: desktop) == compact,
          "restoring compact dimensions preserves saved placement near the right edge")
    let tiny = CGRect(x: -100, y: -50, width: 200, height: 300)
    let fitted = PanelGeometry.clamp(largeFrame, to: tiny)
    check(fitted.width == 200 && fitted.height == 120 && tiny.contains(fitted),
          "small screens and negative screen coordinates stay visible")
}

// MARK: Latest-wins UI delivery

do {
    let mailbox = LatestSections()
    let initial = Store(sources: [SourceConfig.local(executable: "/fake")]).view(now: 0)
    check(mailbox.replace(initial), "first UI update schedules a delivery")
    var extraDeliveries = 0
    for _ in 0..<1_000 { if mailbox.replace([]) { extraDeliveries += 1 } }
    check(extraDeliveries == 0 && mailbox.take().isEmpty, "busy UI keeps only the latest sections")
    check(mailbox.replace(initial) && mailbox.take() == initial, "UI delivery can be scheduled again after take")
}

// MARK: Config

do {
    let parsed = MachineList.parse("# comment\n\nbox\n  box  \n-oProxyCommand=x\nwith space\nok.host_1\n")
    check(parsed.aliases == ["box", "ok.host_1"], "aliases parsed and deduplicated")
    check(parsed.rejectedLines == [5, 6], "unsafe aliases rejected")
    let crlf = MachineList.parse("# comment\r\n\r\nbox\r\n  box  \r\n-oProxyCommand=x\r\nwith space\r\nok.host_1\r\n")
    check(crlf == parsed, "CRLF preserves aliases and rejected line numbers")
    check(MachineList.parse("").aliases.isEmpty, "empty list allowed")
    let limited = MachineList.parse((0..<17).map { "m\($0)" }.joined(separator: "\n"))
    check(limited.aliases == (0..<16).map { "m\($0)" } && limited.rejectedLines == [17],
          "machine list keeps the first 16 aliases and reports overflow")
    let missing = try? MachineList.load(directory: URL(fileURLWithPath: "/nonexistent-\(getpid())"))
    check(missing == MachineList.Parsed(), "missing file means local only")
    let source = SourceConfig.machine("box", executable: "/x/herdr")
    check(source.listArguments == ["/x/herdr", "--machine", "box", "agent", "list"], "remote argv without shell")
    check(SourceConfig.local(executable: "/x/herdr").listArguments == ["/x/herdr", "agent", "list"], "local argv")
    check(source.focusArguments(paneID: "p1") == ["/x/herdr", "--machine", "box", "agent", "focus", "p1"],
          "remote focus argv")
    check(SourceConfig.local(executable: "/x/herdr").focusArguments(paneID: "p1")
          == ["/x/herdr", "agent", "focus", "p1"], "local focus argv")
    check(source.focusArguments(paneID: "--help") == nil, "option-like pane id rejected")
    check(source.focusArguments(paneID: "") == nil, "empty pane id rejected")
}

// MARK: Process runner (fake children)

func run(_ script: String, timeout: Double = 5, maxStdout: Int = 1 << 20) -> (RunOutcome, Double, pid_t) {
    var limits = RunLimits()
    limits.timeout = timeout
    limits.maxStdout = maxStdout
    let runner = ProcessRunner(limits: limits)
    let start = Date()
    let outcome = runner.run(["/bin/sh", "-c", script])
    return (outcome, Date().timeIntervalSince(start), runner.lastGroup)
}

/// Killed orphans may stay as zombies until launchd reaps them, so allow a short settle time.
func groupGone(_ group: pid_t) -> Bool {
    for _ in 0..<50 {
        if kill(-group, 0) == -1 && errno == ESRCH { return true }
        usleep(20_000)
    }
    return false
}

do {
    var (outcome, _, _) = run("printf ok")
    check(outcome == .exited(0, stdout: Data("ok".utf8), stderrBytes: 0), "captures stdout")
    (outcome, _, _) = run("exit 3")
    check(outcome == .exited(3, stdout: Data(), stderrBytes: 0), "reports exit code")

    let (slow, _, _) = run("printf a; sleep 0.2; printf b; sleep 0.2; printf c")
    check(slow == .exited(0, stdout: Data("abc".utf8), stderrBytes: 0), "slow writer collected")

    let (closedPipes, _, _) = run("exec 1>&- 2>&-; sleep 0.2; exit 0")
    check(closedPipes == .exited(0, stdout: Data(), stderrBytes: 0),
          "EOF on both pipes does not kill a running child")
    let (closedTimeout, _, _) = run("exec 1>&- 2>&-; sleep 30", timeout: 0.3)
    check(closedTimeout == .timedOut, "closed pipes still enforce the child timeout")

    let (timedOut, took, group) = run("sleep 30 & sleep 30", timeout: 0.5)
    check(timedOut == .timedOut && took < 3, "timeout kills child")
    check(groupGone(group), "timeout kills whole process group")

    let (straggler, stragglerTook, stragglerGroup) = run("(sleep 30 &); printf ok")
    if case .exited(0, let out, _) = straggler { check(out == Data("ok".utf8), "straggler output kept") }
    else { check(false, "straggler run exits normally") }
    check(stragglerTook < 3, "leftover group members do not hold the read open")
    check(groupGone(stragglerGroup), "leftover group members cleaned up")

    let (big, _, _) = run("head -c 2000000 /dev/zero")
    check(big == .oversized, "oversized stdout stopped")

    let (flood, _, _) = run("head -c 5000000 /dev/zero >&2; printf done")
    check(flood == .exited(0, stdout: Data("done".utf8), stderrBytes: 5_000_000), "stderr flood drained, not kept")

    let (stdin, stdinTook, _) = run("cat")
    check(stdin == .exited(0, stdout: Data(), stderrBytes: 0) && stdinTook < 2, "stdin is /dev/null")

    let (tty, _, _) = run("if (: < /dev/tty) 2>/dev/null; then printf tty; else printf none; fi")
    check(tty == .exited(0, stdout: Data("none".utf8), stderrBytes: 0), "no controlling terminal for prompts")

    let missing = ProcessRunner().run(["/nonexistent/herdr", "agent", "list"])
    check(missing == .spawnFailed(ENOENT), "spawn failure reported")

    let killed = run("kill -TERM $$").0
    check(killed == .signaled(SIGTERM), "signal reported")

    let runner = ProcessRunner()
    let finished = DispatchSemaphore(value: 0)
    var cancelled: RunOutcome?
    let cancelStart = Date()
    DispatchQueue.global().async {
        cancelled = runner.run(["/bin/sh", "-c", "sleep 30"])
        finished.signal()
    }
    usleep(200_000)
    runner.cancel()
    check(finished.wait(timeout: .now() + 3) == .success && cancelled == .cancelled, "cancel stops child")
    check(Date().timeIntervalSince(cancelStart) < 3 && groupGone(runner.lastGroup), "cancel cleans group")
    check(runner.run(["/bin/sh", "-c", "printf x"]) == .cancelled, "cancelled runner starts nothing")
}

// MARK: Model result mapping and UI notifications

do {
    let failures: [(RunOutcome, ReadFailure)] = [
        (.exited(2, stdout: Data(), stderrBytes: 0), .exit(2)),
        (.exited(0, stdout: Data("garbage".utf8), stderrBytes: 0), .malformed),
        (.exited(0, stdout: Data(count: AgentListParser.maxBytes + 1), stderrBytes: 0), .oversized),
        (.spawnFailed(ENOENT), .spawn(ENOENT)),
        (.signaled(SIGTERM), .signal(SIGTERM)),
        (.timedOut, .timeout), (.cancelled, .timeout), (.oversized, .oversized),
    ]
    for (outcome, expected) in failures {
        let model = OverlayModel(sources: [.local(executable: "/fake")], clock: { 0 })
        check(!model.finish("local", generation: model.begin("local"), outcome: outcome),
              "failed read triggers backoff: \(expected)")
        check(model.snapshot()[0].problem == .failed(expected), "read failure reaches the UI: \(expected)")
    }

    let model = OverlayModel(sources: [.local(executable: "/fake")], clock: { 0 })
    var notifications = 0
    model.onChange = { _ in notifications += 1 }
    let success = RunOutcome.exited(0, stdout: json([agent("p1", "idle")]), stderrBytes: 0)
    check(model.finish("local", generation: model.begin("local"), outcome: success), "valid read succeeds")
    check(model.finish("local", generation: model.begin("local"), outcome: success), "unchanged read still succeeds")
    model.tick()
    let snapshot = model.snapshot() // Synchronizes with the queued tick before reading the callback count.
    check(snapshot[0].problem == nil && notifications == 1, "unchanged heartbeat and tick do not notify the UI")
    model.finish("local", generation: model.begin("local"), outcome: .timedOut)
    check(notifications == 2, "a changed view notifies the UI again")
}

// MARK: Poller

do {
    check(SourcePoller.delay(afterFailures: 0, interval: 2, backoff: SourcePoller.backoff) == 2, "interval after success")
    check((1...4).map { SourcePoller.delay(afterFailures: $0, interval: 2, backoff: SourcePoller.backoff) }
          == [5, 10, 30, 30], "backoff 5/10/30")

    let fast = SourceConfig(id: "local", label: "L", command: ["x"], interval: 0.01, staleAfter: seconds(6))
    let other = SourceConfig(id: "machine:m", label: "M", command: ["y"], interval: 0.01, staleAfter: seconds(6))
    let model = OverlayModel(sources: [fast, other])
    let lock = NSLock()
    var active: [String: Int] = [:], peak: [String: Int] = [:], calls: [String: Int] = [:]
    func reader(_ id: String, fails: Bool) -> ([String]) -> RunOutcome {
        { _ in
            lock.lock(); active[id, default: 0] += 1; peak[id] = max(peak[id] ?? 0, active[id]!)
            calls[id, default: 0] += 1; lock.unlock()
            usleep(30_000)
            lock.lock(); active[id]! -= 1; lock.unlock()
            return fails ? .timedOut : .exited(0, stdout: json([agent("w1:p1", "idle", seq: 1)]), stderrBytes: 0)
        }
    }
    let pollers = [SourcePoller(source: fast, model: model, read: reader("local", fails: false)),
                   SourcePoller(source: other, model: model, read: reader("machine:m", fails: true),
                                backoff: [0.01])]
    pollers.forEach { $0.start() }
    usleep(500_000)
    pollers.forEach { $0.stop() }
    usleep(100_000)
    lock.lock()
    check(peak["local"] == 1 && peak["machine:m"] == 1, "never more than one read per source")
    check((calls["local"] ?? 0) >= 5 && (calls["machine:m"] ?? 0) >= 5, "both sources kept polling")
    let settled = calls
    lock.unlock()
    usleep(100_000)
    lock.lock()
    check(calls == settled, "stop ends polling")
    lock.unlock()
    let longWait = SourceConfig(id: "local", label: "L", command: ["x"], interval: 60, staleAfter: seconds(6))
    let refreshed = DispatchSemaphore(value: 0)
    let resumePoller = SourcePoller(source: longWait, model: OverlayModel(sources: [longWait]), read: { _ in
        refreshed.signal()
        return .exited(0, stdout: json([]), stderrBytes: 0)
    })
    resumePoller.start()
    check(refreshed.wait(timeout: .now() + 2) == .success, "initial poll starts")
    resumePoller.refresh()
    check(refreshed.wait(timeout: .now() + 2) == .success, "wake refresh skips the old interval")
    resumePoller.stop()
    check(resumePoller.drain(timeout: 2), "refreshed poller drains on stop")
    let sections = model.snapshot()
    check(sections[0].problem == nil && sections[1].problem == SectionView.Problem.failed(.timeout), "failing source isolated")
}

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
