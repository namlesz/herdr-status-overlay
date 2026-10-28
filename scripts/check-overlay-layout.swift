import AppKit
import OverlayCore

// Compile with PanelController.swift: inspect its real layout without displaying a window.
extension Bundle {
    static var module: Bundle { Bundle(path: CommandLine.arguments[1])! }
}

@main
struct OverlayLayoutCheck {
    static func require(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }

    static func cloud(in view: NSView) -> NSView? {
        if String(describing: type(of: view)) == "ThoughtBubbleView" { return view }
        return view.subviews.lazy.compactMap { cloud(in: $0) }.first
    }

    static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = PanelState()
        state.visible = false
        state.autoHide = true
        let url = directory.appendingPathComponent("panel.json")
        try JSONEncoder().encode(state).write(to: url)
        let controller = PanelController(stateFile: url)
        // Keep test-only access out of the production interface.
        let children = Mirror(reflecting: controller).children
        let panel = children.first { $0.label == "panel" }!.value as! NSPanel
        let scroll = children.first { $0.label == "scroll" }!.value as! NSScrollView
        let root = panel.contentView!
        let dog = children.first { $0.label == "corgi" }!.value as! NSView
        func dogFrame() -> NSRect {
            root.layoutSubtreeIfNeeded()
            return panel.convertToScreen(dog.convert(dog.bounds, to: nil))
        }
        func dogFrame(of controller: PanelController) -> NSRect {
            let children = Mirror(reflecting: controller).children
            let panel = children.first { $0.label == "panel" }!.value as! NSPanel
            let root = panel.contentView!
            let dog = children.first { $0.label == "corgi" }!.value as! NSView
            root.layoutSubtreeIfNeeded()
            return panel.convertToScreen(dog.convert(dog.bounds, to: nil))
        }
        var store = Store(sources: [.local(executable: "/fake")])
        for direction in PanelDirection.allCases {
            controller.setDirection(direction)
            for style in [NSScroller.Style.legacy, .overlay] {
                scroll.scrollerStyle = style
                for count in [1, 20, 1] {
                    let agents = (0..<count).map { ["pane_id": "p\($0)", "agent_status": "done"] }
                    let data = try JSONSerialization.data(withJSONObject: ["result": ["agents": agents]])
                    store.succeed("local", generation: store.begin("local"),
                                  agents: try AgentListParser.parse(data), now: seconds(1))
                    controller.render(store.view(now: seconds(1)))
                    controller.setAutoHide(false)
                    root.layoutSubtreeIfNeeded()
                    require(scroll.hasVerticalScroller, "expanded list must still scroll")
                    controller.setAutoHide(true)
                    root.layoutSubtreeIfNeeded()
                    let visible = panel.screen!.visibleFrame
                    let points = [panel.frame.origin,
                                  NSPoint(x: visible.maxX - panel.frame.width, y: visible.minY),
                                  visible.origin, NSPoint(x: visible.midX, y: visible.midY)]
                    for point in points {
                        panel.setFrameOrigin(point)
                        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
                        root.layoutSubtreeIfNeeded()
                        let bubble = cloud(in: root)!
                        let document = scroll.documentView!
                        require(abs(document.frame.width - scroll.contentView.bounds.width) < 0.5,
                                "stale scrollbar gutter clips cloud: document \(document.frame.width), clip \(scroll.contentView.bounds.width)")
                        let frame = document.convert(bubble.bounds, from: bubble)
                        require(document.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                                "cloud must fit document after expansion, collapse and edge dragging")
                        require(!panel.isVisible, "layout test must never display the overlay")
                    }
                }
            }
        }
        let visible = panel.screen!.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - 210, y: visible.midY - 100))
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
        var widths: [CGFloat] = []
        for statuses in [["working"], ["working", "blocked"], ["working", "blocked", "done"], ["working"]] {
            let agents = statuses.enumerated().map { ["pane_id": "s\($0.offset)", "agent_status": $0.element] }
            let data = try JSONSerialization.data(withJSONObject: ["result": ["agents": agents]])
            store.succeed("local", generation: store.begin("local"),
                          agents: try AgentListParser.parse(data), now: seconds(1))
            let before = dogFrame()
            controller.render(store.view(now: seconds(1)))
            let after = dogFrame()
            require(before == after, "counter changes must not move corgi")
            widths.append(cloud(in: root)!.bounds.width)
        }
        require(widths[0] < widths[1] && widths[1] < widths[2] && widths[0] == widths[3],
                "cloud grows and shrinks for one/two/three counters: \(widths)")
        for autoHide in [true, false] {
            controller.setAutoHide(autoHide)
            panel.setFrameOrigin(NSPoint(x: visible.midX - 210, y: visible.midY - 100))
            controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
            let before = dogFrame()
            for direction in PanelDirection.allCases {
                controller.setDirection(direction)
                require(dogFrame() == before, "direction changes keep mascot fixed away from screen edges")
                if autoHide {
                    let bubble = cloud(in: root)!
                    let bubbleFrame = panel.convertToScreen(bubble.convert(bubble.bounds, to: nil))
                    let dog = dogFrame()
                    require(direction.extendsLeft ? bubbleFrame.midX < dog.midX : bubbleFrame.midX > dog.midX,
                            "cloud center must be on the selected horizontal side of corgi: \(direction)")
                    require(abs(bubbleFrame.midX - dog.midX) <= bubbleFrame.width / 2,
                            "cloud stays close to the mascot center")
                    require(direction.extendsUp ? bubbleFrame.minY >= dog.maxY : bubbleFrame.maxY <= dog.minY,
                            "cloud must be on the selected vertical side of corgi: \(direction)")
                }
                controller.saveState()
                let restored = PanelController(stateFile: url)
                restored.render(store.view(now: seconds(1)))
                let restoredPanel = Mirror(reflecting: restored).children.first { $0.label == "panel" }!.value as! NSPanel
                require(restoredPanel.frame == panel.frame, "direction and placement survive restart: autoHide=\(autoHide), direction=\(direction), original=\(panel.frame), restored=\(restoredPanel.frame)")
                if !autoHide {
                    for _ in 0..<2 {
                        controller.perform(NSSelectorFromString("toggleMinimized"))
                        require(dogFrame() == before, "manual minimize and expand keep mascot fixed")
                        controller.saveState()
                        let compactRestored = PanelController(stateFile: url)
                        compactRestored.render(store.view(now: seconds(1)))
                        let compactPanel = Mirror(reflecting: compactRestored).children.first { $0.label == "panel" }!.value as! NSPanel
                        require(compactPanel.frame == panel.frame, "manual modes restore the same mascot position")
                    }
                }
            }
        }
        controller.setAutoHide(true)
        for direction in PanelDirection.allCases {
            controller.setDirection(direction)
            panel.setFrameOrigin(NSPoint(x: visible.midX - 210, y: visible.midY - 100))
            controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
            let before = dogFrame()
            for status in ["idle", "working", "idle"] {
                let data = try JSONSerialization.data(withJSONObject: [
                    "result": ["agents": [["pane_id": "quiet", "agent_status": status]]]
                ])
                store.succeed("local", generation: store.begin("local"),
                              agents: try AgentListParser.parse(data), now: seconds(1))
                controller.render(store.view(now: seconds(1)))
                require(dogFrame() == before, "hiding and restoring cloud keeps mascot fixed")
                require((cloud(in: root) == nil) == (status == "idle"),
                        "idle-only auto-hide shows just corgi; active counters restore cloud")
                require(!panel.isVisible, "idle layout checks never display a window")
            }
            controller.render(store.view(now: seconds(20)))
            root.layoutSubtreeIfNeeded()
            require(cloud(in: root) != nil, "stale data stays distinguishable from no active agents")
        }
        // Row-only changes must keep compact views alive, but still reach the expanded list and mascot.
        let now = MonotonicClock.now()
        var compactStore = Store(sources: [.local(executable: "/fake")])
        func renderCompact(title: String, sequence: Int) throws {
            let data = try JSONSerialization.data(withJSONObject: ["result": ["agents": [
                ["pane_id": "busy", "agent_status": "working", "terminal_title_stripped": title],
                ["pane_id": "finished", "agent_status": "done", "completion_seq": sequence]
            ]]])
            compactStore.succeed("local", generation: compactStore.begin("local"),
                                 agents: try AgentListParser.parse(data), now: now)
            controller.render(compactStore.view(now: now))
        }
        func containsText(_ text: String, in view: NSView) -> Bool {
            (view as? NSTextField)?.stringValue == text || view.subviews.contains { containsText(text, in: $0) }
        }
        func textValues(in view: NSView) -> [String] {
            let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
            return own + view.subviews.flatMap(textValues)
        }
        func cardWidth() -> CGFloat? {
            root.layoutSubtreeIfNeeded()
            let stack = scroll.documentView?.subviews.compactMap { $0 as? NSStackView }.first
            return stack?.arrangedSubviews.first?.frame.width
        }
        try renderCompact(title: "Before", sequence: 1)
        let unchangedCloud = cloud(in: root)!
        try renderCompact(title: "Latest activity", sequence: 1)
        require(cloud(in: root) === unchangedCloud, "title-only changes must not rebuild the cloud")
        try renderCompact(title: "Latest activity", sequence: 2)
        require(cloud(in: root) === unchangedCloud, "new completion with equal counters keeps the cloud")
        let mood = Mirror(reflecting: controller).children.first { $0.label == "mood" }!.value as! MascotMood?
        require(mood == .celebrating, "equal counters must still deliver new completion events to the mascot")
        controller.setAutoHide(false)
        require(containsText("Latest activity", in: root), "expansion must show the latest cached row data")
        controller.perform(NSSelectorFromString("toggleMinimized"))
        let compactCard = scroll.documentView!.subviews[0].subviews[0]
        try renderCompact(title: "Manual latest activity", sequence: 2)
        require(scroll.documentView!.subviews[0].subviews[0] === compactCard,
                "manual compact mode also preserves its content for row-only changes")
        controller.perform(NSSelectorFromString("toggleMinimized"))
        require(containsText("Manual latest activity", in: root), "manual expansion uses latest row data")
        controller.setAutoHide(true)
        controller.render(compactStore.view(now: now + seconds(7)))
        require(cloud(in: root) !== unchangedCloud, "freshness changes must rebuild compact content")
        require(!panel.isVisible, "optimization checks never display a window")
        let timers = Mirror(reflecting: controller).children
        require(timers.first { $0.label == "animationTimer" }!.value as! Timer? == nil,
                "hidden panel must not run an animation or hover timer")
        require(timers.first { $0.label == "celebrationTimer" }!.value as! Timer? == nil,
                "hidden panel must not schedule celebration expiry")
        let scaleScreen = panel.screen!.visibleFrame
        func dogAnchor(_ frame: NSRect, _ direction: PanelDirection) -> NSPoint {
            NSPoint(x: direction.extendsLeft ? frame.maxX : frame.minX,
                    y: direction.extendsUp ? frame.minY : frame.maxY)
        }
        for autoHide in [true, false] {
            controller.setAutoHide(autoHide)
            for minimized in (autoHide ? [false] : [false, true]) {
                let savedState = Mirror(reflecting: controller).children.first { $0.label == "state" }!.value as! PanelState
                if !autoHide && savedState.minimized != minimized {
                    controller.perform(NSSelectorFromString("toggleMinimized"))
                }
                controller.setDogScalePercent(100)
                controller.render(compactStore.view(now: now + seconds(7)))
                for direction in PanelDirection.allCases {
                    controller.setDirection(direction)
                    panel.setFrameOrigin(NSPoint(x: scaleScreen.midX - panel.frame.width / 2,
                                                 y: scaleScreen.midY - panel.frame.height / 2))
                    controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
                    let anchor = dogAnchor(dogFrame(), direction)
                    let originalTexts = textValues(in: root)
                    let originalCardWidth = cardWidth()
                    let originalCloudWidth = autoHide ? cloud(in: root)?.bounds.width : nil
                    for scale in [50, 100, 150, 200, 300] {
                        controller.setDogScalePercent(scale)
                        let frame = dogFrame()
                        let expectedSide = PanelGeometry.mascotSide(baseSide: 96, scalePercent: scale,
                                                                    in: scaleScreen)
                        require(abs(frame.width - expectedSide) < 0.5 && abs(frame.height - expectedSide) < 0.5,
                                "dog scene uses the selected scale, bounded by available screen space: \(scale)%")
                        let afterAnchor = dogAnchor(frame, direction)
                        require(abs(afterAnchor.x - anchor.x) < 0.5 && abs(afterAnchor.y - anchor.y) < 0.5,
                                "dog scale preserves its anchor in \(direction)")
                        require(textValues(in: root) == originalTexts,
                                "dog scaling leaves cloud, text and card labels unchanged")
                        require(cardWidth().map { abs($0 - (originalCardWidth ?? $0)) < 0.5 } == true,
                                "dog scaling does not resize cards")
                        if let originalCloudWidth {
                            require(abs((cloud(in: root)?.bounds.width ?? -1) - originalCloudWidth) < 0.5,
                                    "dog scaling does not resize the counter cloud")
                        }
                        if scale == 300 {
                            if !autoHide && !minimized {
                                require(scroll.contentView.bounds.height >= 80,
                                        "expanded list keeps an 80 pt scroll viewport at 300 percent")
                            }
                            if autoHide, let bubble = cloud(in: root) {
                                let bubbleFrame = bubble.convert(bubble.bounds, to: scroll.contentView)
                                require(scroll.contentView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(bubbleFrame),
                                        "compact counters stay visible beside the 300 percent dog")
                            }
                        }
                    }
                    controller.setDogScalePercent(100)
                }
                controller.setDogScalePercent(200)
                controller.saveState()
                let originalDog = dogFrame()
                let restored = PanelController(stateFile: url)
                restored.render(compactStore.view(now: now + seconds(7)))
                let restoredPanel = Mirror(reflecting: restored).children.first { $0.label == "panel" }!.value as! NSPanel
                let restoredDog = dogFrame(of: restored)
                require(restored.dogScalePercent == 200 && abs(restoredDog.width - originalDog.width) < 0.5,
                        "custom scale and dog size survive restart: autoHide=\(autoHide), minimized=\(minimized)")
                require(abs(restoredPanel.frame.minX - panel.frame.minX) < 0.5
                        && abs(restoredPanel.frame.minY - panel.frame.minY) < 0.5,
                        "scaled dog panel placement survives restart")
            }
        }
        controller.setDogScalePercent(301)
        require(controller.dogScalePercent == 200, "out-of-range programmatic scale leaves preference unchanged")
        controller.setDogScalePercent(100)
        print("Overlay AppKit layout checks passed (four directions, dynamic cloud, restoration, both scrollbar styles and edge dragging).")
    }
}
