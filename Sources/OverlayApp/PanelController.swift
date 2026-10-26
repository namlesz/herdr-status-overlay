import AppKit
import OverlayCore

/// Persisted panel placement: top-left offset inside the visible frame of a screen.
struct PanelState: Codable {
    var visible = true
    var screen: UInt32?
    var left: Double?
    var top: Double?
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
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

    private let panel: NSPanel
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let stateFile: URL
    private var state: PanelState
    private var rendered: [SectionView]?
    private var adjustingFrame = false
    /// Called on the main thread when the user clicks an agent row.
    var onSelect: ((RowView) -> Void)?

    init(stateFile: URL) {
        self.stateFile = stateFile
        state = (try? JSONDecoder().decode(PanelState.self, from: Data(contentsOf: stateFile))) ?? PanelState()
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        configurePanel()
        placeFromState()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    var isVisible: Bool { panel.isVisible }

    func restoreVisibility() { setVisible(state.visible) }

    /// Never makes the panel key or activates the app.
    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        state.visible = visible
        saveState()
    }

    func saveState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
    }

    /// Rebuilds only when the view model changed; heartbeats with equal data do nothing.
    func render(_ sections: [SectionView]) {
        guard sections != rendered else { return }
        rendered = sections
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for section in sections { addSection(section) }
        resize()
    }

    // MARK: Panel setup

    private func configurePanel() {
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
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
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

    private func addSection(_ section: SectionView) {
        let card = NSStackView()
        card.appearance = NSAppearance(named: .darkAqua)
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 4
        card.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        card.layer?.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let title = section.stale ? "\(section.label) — stale data" : section.label
        let titleField = label(title, size: 15, bold: true, secondary: section.stale)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.toolTip = title
        let titleLine = NSStackView(views: [titleField, NSView(), countView(section)])
        titleLine.orientation = .horizontal
        titleLine.alignment = .centerY
        titleLine.spacing = 6
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
    private func countView(_ section: SectionView) -> NSView {
        guard !section.stale else { return label("—", size: 13, secondary: true) }
        let order: [DisplayStatus] = [.working, .blocked, .done, .idle, .unknown]
        var views: [NSView] = []
        var summary: [String] = []
        for status in order {
            guard let count = section.counts?[status], count > 0 else { continue }
            let number = label("\(count)", size: 13)
            number.textColor = statusColor(status)
            let pair = NSStackView(views: [statusIcon(status, size: 12, color: statusColor(status)), number])
            pair.spacing = 3
            views.append(pair)
            summary.append("\(count) \(statusName(status))")
        }
        guard !views.isEmpty else { return label("no agents", size: 13, secondary: true) }
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
        let height = min(stack.fittingSize.height, screen.visibleFrame.height * 0.4).rounded(.up)
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size = NSSize(width: Self.width, height: max(height, 40))
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
        PanelGeometry.clamp(frame, to: screen.visibleFrame)
    }

    private func number(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func recordPosition() {
        guard let screen = currentScreen else { return }
        let visible = screen.visibleFrame
        state.screen = number(of: screen)
        state.left = Double(panel.frame.minX - visible.minX)
        state.top = Double(visible.maxY - panel.frame.maxY)
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
