import AppKit
import ImageIO
import OverlayCore
import QuartzCore


private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Illustrated corgi frames, decoded once from the bundled PNGs.
private enum CorgiArt {
    static let frames: [MascotFrame: NSImage] = {
        var frames: [MascotFrame: NSImage] = [:]
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        for frame in MascotFrame.allCases {
            guard let url = Bundle.module.url(forResource: frame.resourceName, withExtension: "png",
                                              subdirectory: "Corgi"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
                NSLog("Herdr Status Overlay: missing corgi frame %@", frame.resourceName)
                continue
            }
            frames[frame] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        return frames
    }()
}

private final class CorgiView: NSView {
    static let side: CGFloat = 96
    private var art: MascotFrame = .sleeping
    private var lift: CGFloat = 0

    private var sleepPhases: [Double] = []

    func show(_ art: MascotFrame, lift: CGFloat, sleepPhases: [Double]) {
        guard art != self.art || lift != self.lift || sleepPhases != self.sleepPhases else { return }
        self.art = art
        self.lift = lift
        self.sleepPhases = sleepPhases
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Inset so the highest hop (5 pt) still fits inside the view.
        CorgiArt.frames[art]?.draw(in: NSRect(x: 3, y: 1 + lift, width: bounds.width - 6, height: bounds.width - 6))
        for phase in sleepPhases {
            let p = CGFloat(phase)
            let text = p < 0.6 ? "z" : "Z"
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 2
            (text as NSString).draw(at: NSPoint(x: 56 + 17 * p + 3 * sin(p * .pi * 2), y: 48 + 28 * p),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 10 + 9 * p, weight: .bold),
                                                    .foregroundColor: NSColor(calibratedRed: 0.78, green: 0.88, blue: 1,
                                                                              alpha: sin(p * .pi)),
                                                    .shadow: shadow])
        }
    }
}


private final class CardBackdropView: NSVisualEffectView {
    static let tailHeight: CGFloat = 9
    private let speechTail: Bool

    init(speechTail: Bool, reduceTransparency: Bool) {
        self.speechTail = speechTail
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        if reduceTransparency {
            state = .inactive
            layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.97).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func layout() {
        super.layout()
        guard let layer else { return }
        let mask = CAShapeLayer()
        let path = CGMutablePath()
        let tail = speechTail ? Self.tailHeight : 0
        let radius: CGFloat = 10
        // Unflipped layer coordinates: minY is the bottom edge, where the tail points down at the dog.
        let rect = NSRect(x: bounds.minX, y: bounds.minY + tail, width: bounds.width, height: bounds.height - tail)
        if speechTail {
            let mid = bounds.midX
            path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
            path.addLine(to: CGPoint(x: mid - 8, y: rect.minY))
            path.addLine(to: CGPoint(x: mid, y: bounds.minY))
            path.addLine(to: CGPoint(x: mid + 8, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            path.closeSubpath()
        } else {
            path.addRoundedRect(in: bounds, cornerWidth: radius, cornerHeight: radius)
        }
        mask.path = path
        layer.mask = mask
    }
}
/// Agent row that reacts to a click without dragging the panel or needing it to be key first.
private final class ClickableRow: NSStackView {
    var onClick: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The whole row, labels and icons included, takes the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class PanelController: NSObject, NSWindowDelegate {
    private static let width: CGFloat = 420
    private static let margin: CGFloat = 16
    /// Fixed band under the scrolling cards that holds the expanded-mode mascot.
    private static let mascotFooter: CGFloat = CorgiView.side + 4

    private let panel: NSPanel
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let stateFile: URL
    private var state: PanelState
    private var rendered: [SectionView]?
    private let corgi = CorgiView(frame: NSRect(x: 0, y: 0, width: CorgiView.side, height: CorgiView.side))
    private var animationTimer: Timer?
    private var hover = AutoHideHover()
    private var compact: Bool { state.showsCompact(hovered: hover.expanded) }
    private var mood: MascotMood?
    private var tick = 0
    private var mascotCornerConstraints: [NSLayoutConstraint] = []
    private var scrollBottom: NSLayoutConstraint!

    private var adjustingFrame = false
    private var contentWidth: CGFloat = PanelController.width
    /// Called on the main thread when the user clicks an agent row.
    var onSelect: ((RowView) -> Void)?

    init(stateFile: URL) {
        self.stateFile = stateFile
        state = (try? JSONDecoder().decode(PanelState.self, from: Data(contentsOf: stateFile))) ?? PanelState()
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        configurePanel()
        // Restore placement only after applying the saved mode's actual dimensions.
        rebuildContent()
        placeFromState()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    /// User preference, independent of automatic hiding when no cards are available.
    var isVisibilityEnabled: Bool { state.visible }

    var isAutoHideEnabled: Bool { state.autoHide }

    func setAutoHide(_ enabled: Bool) {
        state.autoHide = enabled
        hover = AutoHideHover()
        rebuildContent()
        recordPosition()
        saveState()
    }

    private func updateHover() {
        guard state.autoHide else { return }
        // Keep the panel open throughout dragging, including the native window-tracking loop.
        let inside = panel.frame.contains(NSEvent.mouseLocation)
            || (hover.expanded && NSEvent.pressedMouseButtons != 0)
        if hover.update(inside: inside, now: ProcessInfo.processInfo.systemUptime) {
            rebuildContent()
            recordPosition()
            saveState()
        }
    }

    func restoreVisibility() { setVisible(state.visible) }

    /// Never makes the panel key or activates the app.
    func setVisible(_ visible: Bool) {
        state.visible = visible
        updateVisibility()
        saveState()
    }

    func saveState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
    }

    /// Rebuilds only when the view model changed; heartbeats with equal data do nothing.
    func render(_ sections: [SectionView]) {
        let sections = sections.filter(\.shouldDisplay)
        guard sections != rendered else { return }
        rendered = sections
        rebuildContent()
    }

    private func rebuildContent() {
        let sections = rendered ?? []
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        contentWidth = Self.width
        if compact {
            if state.autoHide {
                addCorgiCorner()
                contentWidth = CorgiView.side + 16
            } else {
                addCompactSummary(sections)
            }
        } else {
            addCorgiCorner()
            for section in sections { addSection(section) }
        }
        updateCorgiMood()
        resize()
        updateVisibility()
    }

    private func updateVisibility() {
        let visible = state.visible && !(rendered ?? []).isEmpty
        if visible == panel.isVisible { return }
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        if !visible { hover = AutoHideHover(); rebuildContent() }
        // The mascot animates only while the panel is on screen.
        animationTimer?.invalidate()
        animationTimer = visible ? Timer.scheduledTimer(withTimeInterval: MascotAnimation.tickInterval,
                                                        repeats: true) { [weak self] _ in
            self?.updateCorgiMood(advance: true)
            self?.updateHover()
        } : nil
    }

    // MARK: Panel setup

    private func configurePanel() {
        corgi.setAccessibilityLabel("Corgi status mascot")
        corgi.translatesAutoresizingMaskIntoConstraints = false
        corgi.widthAnchor.constraint(equalToConstant: CorgiView.side).isActive = true
        corgi.heightAnchor.constraint(equalToConstant: CorgiView.side).isActive = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.setAccessibilityLabel("Herdr Status Overlay")

        let background = NSView()
        panel.contentView = background

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)
        scrollBottom = scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: background.topAnchor),
            scrollBottom,
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    // MARK: Content

    private func makeCard(fillWidth: Bool = true, speechTail: Bool = false) -> NSStackView {
        let card = NSStackView()
        card.appearance = NSAppearance(named: .darkAqua)
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 4
        card.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10 + (speechTail ? CardBackdropView.tailHeight : 0),
                                       right: 12)
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.clear.cgColor
        card.layer?.cornerRadius = 10
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(card)
        let backdrop = CardBackdropView(speechTail: speechTail, reduceTransparency: reduceTransparency)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(backdrop, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: card.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        if fillWidth { card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return card
    }

    /// Pins the mascot to the panel's bottom-right corner, outside the scroll view, so it never scrolls away.
    private func addCorgiCorner() {
        guard let background = panel.contentView else { return }
        NSLayoutConstraint.deactivate(mascotCornerConstraints)
        corgi.removeFromSuperview()
        background.addSubview(corgi)
        scrollBottom.constant = -Self.mascotFooter
        mascotCornerConstraints = [
            corgi.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            corgi.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -2)
        ]
        NSLayoutConstraint.activate(mascotCornerConstraints)
    }

    /// A new mood restarts its animation; `advance` steps it unless Reduce Motion asks for a still frame.
    private func updateCorgiMood(advance: Bool = false) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let mood = MascotMood.select(in: rendered ?? [], now: MonotonicClock.now())
        if mood != self.mood {
            self.mood = mood
            tick = 0
            corgi.setAccessibilityLabel("Corgi: \(mood)")
        } else if advance && !reduceMotion {
            tick += 1
        }
        corgi.show(MascotAnimation.frame(for: mood, tick: tick, reduceMotion: reduceMotion),
                   lift: CGFloat(MascotAnimation.lift(for: mood, tick: tick, reduceMotion: reduceMotion)),
                   sleepPhases: mood == .sleeping ? MascotAnimation.sleepPhases(tick: tick, reduceMotion: reduceMotion) : [])
    }

    private func toggleButton() -> NSButton {
        let title = state.minimized ? "Expand overlay" : "Minimize overlay"
        let button = NSButton(image: NSImage(systemSymbolName: state.minimized ? "chevron.right" : "chevron.down",
                                            accessibilityDescription: title)!,
                              target: self, action: #selector(toggleMinimized))
        button.isBordered = false
        button.isHidden = state.autoHide
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }

    @objc private func toggleMinimized() {
        state.minimized.toggle()
        rebuildContent()
        recordPosition()
        saveState()
    }

    private func addCompactSummary(_ sections: [SectionView]) {
        let card = makeCard(fillWidth: false, speechTail: true)
        let counters = countView(SectionView.activeCounts(in: sections),
                                 order: [.working, .blocked, .done], emptyText: "No active agents")
        let line = NSStackView(views: [toggleButton(), counters])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 10
        card.addArrangedSubview(line)
        stack.removeArrangedSubview(card)
        NSLayoutConstraint.deactivate(mascotCornerConstraints)
        scrollBottom.constant = 0
        card.removeFromSuperview()
        // Speech bubble above the dog, its tail pointing down at the dog's head.
        let row = NSStackView(views: [card, corgi])
        row.orientation = .vertical
        row.alignment = .centerX
        row.spacing = 0
        stack.addArrangedSubview(row)
        contentWidth = min(Self.width, (row.fittingSize.width + 16).rounded(.up))
        let unavailable = sections.filter(\.stale).map(\.label)
        card.toolTip = unavailable.isEmpty ? counters.toolTip
            : "Fresh sources only. Unavailable: " + unavailable.joined(separator: ", ")
    }

    private func addSection(_ section: SectionView) {
        let card = makeCard()

        let title = section.stale ? "\(section.label) — stale data" : section.label
        let titleField = label(title, size: 15, bold: true, secondary: section.stale)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.toolTip = title
        let titleLine = NSStackView(views: [titleField, NSView(), countView(section.counts)])
        titleLine.orientation = .horizontal
        titleLine.alignment = .centerY
        titleLine.spacing = 6
        if section.id == rendered?.first?.id { titleLine.addArrangedSubview(toggleButton()) }
        card.addArrangedSubview(titleLine)
        titleLine.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -24).isActive = true

        if let problem = section.problem {
            card.addArrangedSubview(label(describe(problem), size: 11, secondary: true))
        }
        for row in section.rows {
            let view = rowView(row, stale: section.stale)
            card.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -24).isActive = true
        }
    }

    /// Counters as colored icons with numbers; words only in the tooltip.
    private func countView(_ counts: [DisplayStatus: Int]?,
                           order: [DisplayStatus] = [.working, .blocked, .done, .idle, .unknown],
                           emptyText: String = "no agents") -> NSView {
        guard let counts else { return label("—", size: 13, secondary: true) }
        var views: [NSView] = []
        var summary: [String] = []
        for status in order {
            guard let count = counts[status], count > 0 else { continue }
            let number = label("\(count)", size: 13)
            number.textColor = statusColor(status)
            let pair = NSStackView(views: [statusIcon(status, size: 12, color: statusColor(status)), number])
            pair.spacing = 3
            views.append(pair)
            summary.append("\(count) \(statusName(status))")
        }
        guard !views.isEmpty else { return label(emptyText, size: 13, secondary: true) }
        let counters = NSStackView(views: views)
        counters.spacing = 10
        counters.toolTip = summary.joined(separator: " · ")
        return counters
    }

    private func rowView(_ row: RowView, stale: Bool) -> NSView {
        let icon = statusIcon(row.status, size: 14, color: stale ? .secondaryLabelColor : statusColor(row.status))
        let name = label(row.label, size: 14, bold: true, secondary: stale)
        let place = label(row.place ?? "—", size: 14, secondary: true)
        place.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let line = NSStackView(views: [icon, name, place, NSView()])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 6
        let details = ClickableRow(views: [line])
        details.toolTip = "\(row.label) · \(row.place ?? "—") — \(statusName(row.status)). Click to open."
        details.onClick = { [weak self] in self?.onSelect?(row) }
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 2
        line.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        if let activity = row.activity, activity != row.label {
            let field = label(activity, size: 12, secondary: true)
            field.toolTip = activity
            let activityLine = NSStackView(views: [NSView(), field])
            activityLine.orientation = .horizontal
            activityLine.spacing = 6
            activityLine.views[0].widthAnchor.constraint(equalToConstant: 16).isActive = true
            details.addArrangedSubview(activityLine)
            activityLine.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        return details
    }

    private func statusIcon(_ status: DisplayStatus, size: CGFloat, color: NSColor) -> NSImageView {
        let symbol: String
        switch status {
        case .working: symbol = "circle.fill"
        case .blocked: symbol = "exclamationmark.triangle.fill"
        case .done: symbol = "checkmark.circle.fill"
        case .idle: symbol = "moon.fill"
        case .unknown: symbol = "questionmark.circle"
        }
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusName(status))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
        icon.contentTintColor = color
        icon.widthAnchor.constraint(equalToConstant: size + 2).isActive = true
        return icon
    }

    private func statusName(_ status: DisplayStatus) -> String {
        status == .working ? "in progress" : status.rawValue
    }

    /// JetBrains Mono when installed, otherwise the system font.
    private static func font(size: CGFloat, bold: Bool) -> NSFont {
        NSFont(name: bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", size: size)
            ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
    }

    private func statusColor(_ status: DisplayStatus) -> NSColor {
        switch status {
        case .working: return .systemBlue
        case .blocked: return .systemYellow
        case .done: return .systemGreen
        case .idle, .unknown: return .secondaryLabelColor
        }
    }

    private func describe(_ problem: SectionView.Problem) -> String {
        switch problem {
        case .waiting: return "No data yet — waiting for the first read."
        case .outdated: return "No fresh read."
        case .afterWake: return "After wake — waiting for a fresh read."
        case .failed(let failure):
            switch failure {
            case .exit(let code): return "Read failed (exit \(code)). Check the alias or herdr machine status."
            case .signal(let signal): return "Read killed by signal \(signal)."
            case .timeout: return "Read timed out after 10 s."
            case .oversized: return "Response exceeded 1 MiB."
            case .malformed: return "Malformed API response."
            case .spawn(let code): return "Cannot start herdr (errno \(code))."
            }
        }
    }

    private func label(_ text: String, size: CGFloat, bold: Bool = false, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = Self.font(size: size, bold: bold)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width - 30).isActive = true
        return field
    }

    // MARK: Geometry

    private var currentScreen: NSScreen? { panel.screen ?? NSScreen.main ?? NSScreen.screens.first }

    /// Height follows content up to 40% of the screen's visible frame; the rest scrolls.
    private func resize(to destination: NSScreen? = nil) {
        guard !adjustingFrame else { return }
        adjustingFrame = true
        defer { adjustingFrame = false }
        stack.layoutSubtreeIfNeeded()
        guard let screen = destination ?? currentScreen else { return }
        let footer = compact && !state.autoHide ? 0 : Self.mascotFooter
        let height = min(stack.fittingSize.height + footer, screen.visibleFrame.height * 0.4).rounded(.up)
        var frame = panel.frame
        if state.autoHide {
            // Both modes pin the dog at bottom-right; expand upwards and leftwards.
            frame = PanelGeometry.bottomRightFrame(size: NSSize(width: contentWidth, height: max(height, 40)), of: frame)
        } else {
            frame.origin.y = frame.maxY - max(height, 40)
        }
        frame.size = NSSize(width: contentWidth, height: max(height, 40))
        panel.setFrame(clamped(frame, to: screen), display: true)
    }

    private func placeFromState() {
        let saved = NSScreen.screens.first { number(of: $0) == state.screen }
        guard let screen = saved ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        if saved != nil, let left = state.left, let top = state.top {
            frame.origin = NSPoint(x: visible.minX + left, y: visible.maxY - top - frame.height)
        } else {
            frame.origin = NSPoint(x: visible.maxX - frame.width - Self.margin,
                                   y: visible.maxY - frame.height - Self.margin)
        }
        panel.setFrame(clamped(frame, to: screen), display: false)
        recordPosition()
    }

    private func clamped(_ frame: NSRect, to screen: NSScreen) -> NSRect {
        state.autoHide
            ? PanelGeometry.autoHideFrame(frame, expandedWidth: Self.width, in: screen.visibleFrame)
            : PanelGeometry.clamp(frame, to: screen.visibleFrame)
    }

    private func number(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func recordPosition() {
        guard let screen = currentScreen else { return }
        let visible = screen.visibleFrame
        state.screen = number(of: screen)
        // Startup is always collapsed: persist that footprint even while the list is open.
        let frame = state.autoHide
            ? PanelGeometry.bottomRightFrame(size: NSSize(width: min(CorgiView.side + 16, visible.width),
                                                          height: min(Self.mascotFooter, visible.height * 0.4)),
                                             of: panel.frame)
            : panel.frame
        state.left = Double(frame.minX - visible.minX)
        state.top = Double(visible.maxY - frame.maxY)
    }

    func windowDidMove(_ notification: Notification) {
        guard !adjustingFrame else { return }
        resize()
        recordPosition()
        saveState()
    }

    /// A disconnected monitor or resolution change moves the panel back into a visible area.
    @objc private func screensChanged() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        resize(to: screen)
        recordPosition()
        saveState()
    }
}
