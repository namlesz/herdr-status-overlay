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

    static func badge(in controller: PanelController) -> NSStackView? {
        Mirror(reflecting: controller).children.first { $0.label == "compactBadge" }!.value as? NSStackView
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
        func rows(in view: NSView) -> [NSView] {
            (String(describing: type(of: view)) == "ClickableRow" ? [view] : []) + view.subviews.flatMap { rows(in: $0) }
        }
        func renderRows(_ values: [[String: Any]], now: UInt64 = seconds(1)) throws {
            let data = try JSONSerialization.data(withJSONObject: ["result": ["terminals": values]])
            store.succeed("local", generation: store.begin("local"), agents: try AgentListParser.parse(data), now: seconds(1))
            controller.render(store.view(now: now))
        }
        func agent(_ address: String, _ status: String, _ title: String) -> [String: Any] {
            ["address": address, "state": "live", "reported": true, "status": ["state": status], "title": title]
        }
        let hiddenChildren = Mirror(reflecting: controller).children
        require((hiddenChildren.first { $0.label == "hoverMonitors" }!.value as! [Any]).isEmpty, "hidden auto-hide installs no mouse monitors")
        require((hiddenChildren.first { $0.label == "hoverTimer" }!.value as? Timer) == nil, "hidden auto-hide has no grace timer")
        require((hiddenChildren.first { $0.label == "animationTimer" }!.value as? Timer) == nil, "hidden auto-hide has no animation timer")
        controller.setAutoHide(false)
        try renderRows([agent("one", "working", "first"), agent("two", "idle", "second")])
        let originalRows = rows(in: root)
        let originalRow = originalRows[0] as! NSStackView
        let originalLine = originalRow.arrangedSubviews[0] as! NSStackView
        let originalIcon = originalLine.arrangedSubviews[0] as! NSImageView
        let originalName = originalLine.arrangedSubviews[1] as! NSTextField
        let originalPlace = originalLine.arrangedSubviews[2] as! NSTextField
        let originalActivityLine = originalRow.arrangedSubviews[1] as! NSStackView
        let originalActivity = originalActivityLine.arrangedSubviews[1] as! NSTextField
        let card = originalRows[0].superview!
        let header = (card as! NSStackView).arrangedSubviews[0] as! NSStackView
        let toggle = header.arrangedSubviews.compactMap { $0 as? NSButton }.first!
        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                             trackingNumber: 0, userData: nil)!
        toggle.mouseEntered(with: entered)
        try renderRows([agent("one", "working", "changed title"), agent("two", "idle", "second")])
        require(originalRow.arrangedSubviews[0] === originalLine && originalRow.arrangedSubviews[1] === originalActivityLine
                && originalActivityLine.arrangedSubviews[1] === originalActivity && originalActivity.stringValue == "changed title",
                "activity text refresh retains row children and updates content")
        require((card as! NSStackView).arrangedSubviews[0] === header && header.arrangedSubviews.contains { $0 === toggle },
                "row-only refresh retains hovered header control")
        require(toggle.contentTintColor == .labelColor && NSCursor.current == .pointingHand,
                "hovered header keeps its highlight and hand cursor across refresh")
        let exited = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                            trackingNumber: 0, userData: nil)!
        toggle.mouseExited(with: exited)
        try renderRows([agent("one", "done", "updated"), agent("two", "idle", "second"), agent("three", "working", "third")])
        require(header.arrangedSubviews.contains { $0 === toggle }, "count changes retain header control")
        require(originalRow.arrangedSubviews[0] === originalLine && originalLine.arrangedSubviews[0] === originalIcon
                && originalLine.arrangedSubviews[1] === originalName && originalLine.arrangedSubviews[2] === originalPlace
                && originalRow.arrangedSubviews[1] === originalActivityLine && originalActivity.stringValue == "updated"
                && originalIcon.contentTintColor == .systemGreen,
                "status and text updates retain row children and update icon and activity")
        let changedRows = rows(in: root)
        require(changedRows.contains { $0 === originalRows[0] } && changedRows.contains { $0 === originalRows[1] }, "rows retain identity after updates and reorder")
        require(changedRows.contains { $0.superview === card }, "section card retains identity")
        var selected: RowView?
        controller.onSelect = { selected = $0 }
        root.layoutSubtreeIfNeeded()
        let row = originalRows[0]
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let click = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        row.mouseUp(with: click)
        require(selected?.activity == "updated" && selected?.status == .done, "click uses updated row payload")
        controller.render(store.view(now: seconds(50)))
        require(rows(in: root).contains { $0 === row }, "stale transition retains row identity")
        require(row.toolTip?.contains("done") == true, "stale transition preserves row status")
        require(originalIcon.contentTintColor == .secondaryLabelColor && originalName.textColor == .secondaryLabelColor,
                "stale transition updates existing icon and label colors")
        try renderRows([agent("one", "done", "updated"), agent("two", "idle", "second"), agent("three", "working", "third")])
        require(originalRows[0].toolTip?.contains("done") == true, "updated row displays current status")
        require(originalIcon.contentTintColor == .systemGreen && originalName.textColor == .labelColor,
                "fresh transition restores existing icon and label colors")
        let panelHeightWithActivity = panel.frame.height
        originalRow.mouseEntered(with: entered)
        let rowHighlight = originalRow.layer!.sublayers!.first!
        try renderRows([agent("one", "done", "one"), agent("two", "idle", "second"), agent("three", "working", "third")])
        require(originalRow.arrangedSubviews.count == 1 && originalRow.arrangedSubviews[0] === originalLine,
                "activity equal to label removes only activity line")
        let expandedStack = card.superview as! NSStackView
        let heightWithoutActivity = min(expandedStack.fittingSize.height + dog.bounds.height + 4,
                                        panel.screen!.visibleFrame.height * 0.4).rounded(.up)
        require(panel.frame.height == max(heightWithoutActivity, 40), "removing activity resizes the panel to its content")
        root.layoutSubtreeIfNeeded()
        require(rowHighlight.frame == originalRow.bounds.insetBy(dx: -6, dy: -2),
                "hover highlight follows the shorter row after activity removal")
        try renderRows([agent("one", "done", "restored"), agent("two", "idle", "second"), agent("three", "working", "third")])
        require(originalRow.arrangedSubviews.count == 2 && originalRow.arrangedSubviews[0] === originalLine
                && ((originalRow.arrangedSubviews[1] as! NSStackView).arrangedSubviews[1] as! NSTextField).stringValue == "restored",
                "new activity adds only activity line")
        require(panel.frame.height == panelHeightWithActivity, "restoring activity restores the panel height")
        root.layoutSubtreeIfNeeded()
        require(rowHighlight.frame == originalRow.bounds.insetBy(dx: -6, dy: -2),
                "hover highlight follows the taller row after activity restoration")
        originalRow.mouseExited(with: exited)
        var renamed = agent("one", "done", "restored")
        renamed["status"] = ["state": "done", "app": "Renamed"]
        renamed["cwd"] = "/tmp/place"
        try renderRows([renamed, agent("two", "idle", "second"), agent("three", "working", "third")])
        require(originalLine.arrangedSubviews[1] === originalName && originalLine.arrangedSubviews[2] === originalPlace
                && originalName.stringValue == "Renamed" && originalPlace.stringValue == "place",
                "name and place update in their existing fields")
        root.layoutSubtreeIfNeeded()
        let updatedPoint = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let updatedClick = NSEvent.mouseEvent(with: .leftMouseUp, location: updatedPoint, modifierFlags: [], timestamp: 0,
                                              windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        row.mouseUp(with: updatedClick)
        require(selected?.label == "Renamed" && selected?.place == "place" && selected?.activity == "restored",
                "click uses latest renamed row payload")
        try renderRows([agent("one", "done", "updated")])
        require(rows(in: root).count == 1 && rows(in: root)[0] === originalRows[0], "row removal keeps remaining identity")
        do {
            var twoSources = Store(sources: [.local(executable: "/fake"),
                SourceConfig(id: "other", label: "Other", command: [], interval: 2, staleAfter: seconds(45))])
            let data = try JSONSerialization.data(withJSONObject: ["result": ["terminals": [agent("shared", "working", "task")]]])
            let records = try AgentListParser.parse(data)
            for id in ["local", "other"] {
                twoSources.succeed(id, generation: twoSources.begin(id), agents: records, now: seconds(1))
            }
            let sections = twoSources.view(now: seconds(1))
            controller.render(sections)
            let stack = Mirror(reflecting: controller).children.first { $0.label == "stack" }!.value as! NSStackView
            func toggleInFirstCard() -> NSButton {
                let card = stack.arrangedSubviews[0] as! NSStackView
                let header = card.arrangedSubviews[0] as! NSStackView
                return header.arrangedSubviews.compactMap { $0 as? NSButton }.first!
            }
            let firstToggle = toggleInFirstCard()
            firstToggle.mouseEntered(with: entered)
            let otherRow = (stack.arrangedSubviews[1] as! NSStackView).arrangedSubviews.first { String(describing: type(of: $0)) == "ClickableRow" }!
            otherRow.mouseEntered(with: entered)
            controller.render(Array(sections.reversed()))
            require(NSCursor.current == .pointingHand, "removing hovered header does not reset an unchanged hovered row")
            otherRow.mouseExited(with: exited)
            let movedToggle = toggleInFirstCard()
            movedToggle.mouseEntered(with: entered)
            controller.render([sections[0]])
            require(NSCursor.current == .arrow, "removing a hovered section clears its hand cursor")
        }
        let many = (0..<40).map { agent("scroll-\($0)", "working", "before") }
        try renderRows(many)
        root.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        let scrollOrigin = scroll.contentView.bounds.origin
        var changed = many
        changed[0] = agent("scroll-0", "working", "after")
        try renderRows(changed)
        root.layoutSubtreeIfNeeded()
        require(scrollOrigin.y > 0 && scroll.contentView.bounds.origin == scrollOrigin, "data update preserves scroll position")
        let largeList = (0..<1024).map { agent("large-\($0)", "working", "before") }
        try renderRows(largeList)
        root.layoutSubtreeIfNeeded()
        let largeRows = rows(in: root)
        var largeUpdate = largeList
        largeUpdate[512] = agent("large-512", "working", "after")
        let start = ProcessInfo.processInfo.systemUptime
        try renderRows(largeUpdate)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let refreshedRows = rows(in: root)
        require(largeRows.count == 1024 && refreshedRows.count == 1024 && zip(largeRows, refreshedRows).allSatisfy { $0 === $1 },
                "large-list refresh preserves all row identities")
        print("Large-list 1024-row refresh: \(String(format: "%.3f", elapsed))s (informational)")
        for direction in PanelDirection.allCases {
            controller.setDirection(direction)
            for style in [NSScroller.Style.legacy, .overlay] {
                scroll.scrollerStyle = style
                for count in [1, 20, 1] {
                    let agents = (0..<count).map { ["address": "p\($0)", "state": "live", "reported": true, "status": ["state": "done"]] as [String: Any] }
                    let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": ["terminals": agents, "machines": [], "hidden_finished": 0]])
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
                        let counters = badge(in: controller)!
                        require(!scroll.hasVerticalScroller, "collapsed badge has no scrollbar")
                        let frame = root.convert(counters.bounds, from: counters)
                        require(root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                                "badge must fit panel after expansion, collapse and edge dragging")
                        require(counters.superview === root && counters.bounds.height == 26
                                && counters.layer?.cornerRadius == 13,
                                "badge is a compact capsule beside the dog, not a scrolling card")
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
            let agents = statuses.enumerated().map { ["address": "s\($0.offset)", "state": "live", "reported": true, "status": ["state": $0.element]] as [String: Any] }
            let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": ["terminals": agents, "machines": [], "hidden_finished": 0]])
            store.succeed("local", generation: store.begin("local"),
                          agents: try AgentListParser.parse(data), now: seconds(1))
            let before = dogFrame()
            controller.render(store.view(now: seconds(1)))
            let after = dogFrame()
            require(before == after, "counter changes must not move corgi")
            widths.append(badge(in: controller)!.bounds.width)
        }
        require(widths[0] < widths[1] && widths[1] < widths[2] && widths[0] == widths[3],
                "badge grows and shrinks for one/two/three counters: \(widths)")
        for autoHide in [true, false] {
            controller.setAutoHide(autoHide)
            panel.setFrameOrigin(NSPoint(x: visible.midX - 210, y: visible.midY - 100))
            controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
            let before = dogFrame()
            for direction in PanelDirection.allCases {
                controller.setDirection(direction)
                require(dogFrame() == before, "direction changes keep mascot fixed away from screen edges")
                if autoHide {
                    let counters = badge(in: controller)!
                    let badgeFrame = panel.convertToScreen(counters.convert(counters.bounds, to: nil))
                    let dog = dogFrame()
                    require(direction.extendsLeft ? badgeFrame.midX < dog.midX : badgeFrame.midX > dog.midX,
                            "badge follows the selected horizontal side: \(direction)")
                    let verticalOffset = direction.extendsUp ? badgeFrame.maxY - dog.maxY : badgeFrame.minY - dog.minY
                    require(abs(verticalOffset) < 0.5, "badge aligns with the selected corner: \(direction)")
                    let gap = direction.extendsLeft ? dog.minX - badgeFrame.maxX : badgeFrame.minX - dog.maxX
                    require(abs(gap - 6) < 0.5, "badge stays outside the entire animation, with a 6 pt gap")
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
                    "jsonrpc": "2.0", "id": 1, "result": ["terminals": [["address": "quiet", "state": "live", "reported": true, "status": ["state": status]]], "machines": [], "hidden_finished": 0]
                ])
                store.succeed("local", generation: store.begin("local"),
                              agents: try AgentListParser.parse(data), now: seconds(1))
                controller.render(store.view(now: seconds(1)))
                require(dogFrame() == before, "hiding and restoring badge keeps mascot fixed")
                require((badge(in: controller) == nil) == (status == "idle"),
                        "idle-only auto-hide shows just corgi; active counters restore badge")
                require(!panel.isVisible, "idle layout checks never display a window")
            }
            controller.render(store.view(now: seconds(50)))
            root.layoutSubtreeIfNeeded()
            require(badge(in: controller) != nil, "stale data stays distinguishable from no active agents")
        }
        // Row-only changes must keep compact views alive, but still reach the expanded list and mascot.
        let now = MonotonicClock.now()
        var compactStore = Store(sources: [.local(executable: "/fake")])
        func renderCompact(title: String, status: String = "done", publish: Bool = true) throws {
            let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": ["terminals": [
                ["address": "busy", "state": "live", "reported": true, "status": ["state": "working"], "title": title],
                ["address": "finished", "state": "live", "reported": true, "status": ["state": status]]
            ], "machines": [], "hidden_finished": 0]])
            compactStore.succeed("local", generation: compactStore.begin("local"),
                                 agents: try AgentListParser.parse(data), now: now)
            if publish { controller.render(compactStore.view(now: now)) }
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
        try renderCompact(title: "Before")
        let unchangedBadge = badge(in: controller)!
        try renderCompact(title: "Latest activity")
        require(badge(in: controller) === unchangedBadge, "title-only changes must not rebuild the badge")
        try renderCompact(title: "Latest activity", status: "working", publish: false)
        try renderCompact(title: "Latest activity")
        require(badge(in: controller) === unchangedBadge, "new completion with equal counters keeps the badge")
        let mood = Mirror(reflecting: controller).children.first { $0.label == "mood" }!.value as! MascotMood?
        require(mood == .celebrating, "equal counters must still deliver new completion events to the mascot")
        controller.setAutoHide(false)
        require(containsText("Latest activity", in: root), "expansion must show the latest cached row data")
        controller.perform(NSSelectorFromString("toggleMinimized"))
        let compactCard = scroll.documentView!.subviews[0].subviews[0]
        try renderCompact(title: "Manual latest activity")
        require(scroll.documentView!.subviews[0].subviews[0] === compactCard,
                "manual compact mode also preserves its content for row-only changes")
        controller.perform(NSSelectorFromString("toggleMinimized"))
        require(containsText("Manual latest activity", in: root), "manual expansion uses latest row data")
        controller.setAutoHide(true)
        controller.render(compactStore.view(now: now + seconds(7)))
        require(badge(in: controller) !== unchangedBadge, "freshness changes must rebuild compact content")
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
                    let originalBadgeWidth = autoHide ? badge(in: controller)?.bounds.width : nil
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
                                "dog scaling leaves badge, text and card labels unchanged")
                        require(cardWidth() == originalCardWidth,
                                "dog scaling does not resize cards")
                        if let originalBadgeWidth {
                            require(abs((badge(in: controller)?.bounds.width ?? -1) - originalBadgeWidth) < 0.5,
                                    "dog scaling does not resize the counter badge")
                        }
                        if scale == 300 {
                            if !autoHide && !minimized {
                                require(scroll.contentView.bounds.height >= 80,
                                        "expanded list keeps an 80 pt scroll viewport at 300 percent")
                            }
                            if autoHide, let counters = badge(in: controller) {
                                let badgeFrame = counters.convert(counters.bounds, to: root)
                                require(root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(badgeFrame),
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
        print("Overlay AppKit layout checks passed (four directions, dynamic badge, restoration, both scrollbar styles and edge dragging).")
    }
}
