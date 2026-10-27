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
        var store = Store(sources: [.local(executable: "/fake")])
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
        print("Overlay AppKit layout checks passed (both scrollbar styles, resizing and edge dragging).")
    }
}
