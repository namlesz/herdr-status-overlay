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
        print("Overlay AppKit layout checks passed (four directions, dynamic cloud, restoration, both scrollbar styles and edge dragging).")
    }
}
