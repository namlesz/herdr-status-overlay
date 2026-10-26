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

final class PanelController: NSObject, NSWindowDelegate {
    private static let width: CGFloat = 340
    private static let margin: CGFloat = 16

    private let panel: NSPanel
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let stateFile: URL
    private let onAcknowledge: (String, AgentKey) -> Void
    private var state: PanelState
    private var rendered: [SectionView]?
    private var adjustingFrame = false

    init(stateFile: URL, onAcknowledge: @escaping (String, AgentKey) -> Void) {
        self.stateFile = stateFile
        self.onAcknowledge = onAcknowledge
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
        acknowledgements = [:]
        for section in sections { addSection(section) }
        let note = label("done = lista zakończeń overlayu; OK nie zmienia stanu Herdr.", size: 10, secondary: true)
        stack.addArrangedSubview(note)
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

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
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
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
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
        let title = section.stale ? "\(section.label) — dane nieaktualne" : section.label
        stack.addArrangedSubview(label(title, size: 12, bold: true, secondary: section.stale))

        let order: [DisplayStatus] = [.working, .blocked, .done, .idle, .unknown]
        var counts = section.counts.map { counts in
            order.map { "\($0.rawValue) \(counts[$0] ?? 0)" }.joined(separator: " · ")
        } ?? "liczniki: —"
        if section.staleAgents > 0 { counts += " · \(section.staleAgents) z nieaktualnych danych" }
        stack.addArrangedSubview(label(counts, size: 11, secondary: section.stale))

        if let problem = section.problem {
            stack.addArrangedSubview(label(describe(problem), size: 11, secondary: true))
        }
        for row in section.rows { stack.addArrangedSubview(rowView(row, stale: section.stale)) }
        if section.id != rendered?.last?.id { stack.addArrangedSubview(NSBox.separator()) }
    }

    private func rowView(_ row: RowView, stale: Bool) -> NSView {
        let status = row.status == .blocked ? "BLOCKED" : "DONE"
        var text = "\(status)  \(row.workspace) · \(row.label)"
        if stale { text += " · dane nieaktualne" }
        let field = label(text, size: 12, secondary: stale)
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        guard row.status == .done else { return field }

        let button = NSButton(title: "OK", target: self, action: #selector(acknowledge(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityLabel("Potwierdź zakończenie: \(row.label)")
        acknowledgements[ObjectIdentifier(button)] = (row.sourceID, row.key)
        let line = NSStackView(views: [field, button])
        line.orientation = .horizontal
        line.spacing = 6
        return line
    }

    private var acknowledgements: [ObjectIdentifier: (String, AgentKey)] = [:]

    @objc private func acknowledge(_ sender: NSButton) {
        guard let (source, key) = acknowledgements[ObjectIdentifier(sender)] else { return }
        onAcknowledge(source, key)
    }

    private func describe(_ problem: SectionView.Problem) -> String {
        switch problem {
        case .waiting: return "Brak danych — czekam na pierwszy odczyt."
        case .outdated: return "Brak świeżego odczytu."
        case .afterWake: return "Po wybudzeniu — czekam na świeży odczyt."
        case .failed(let failure):
            switch failure {
            case .exit(let code): return "Odczyt nieudany (kod \(code)). Sprawdź alias lub herdr machine status."
            case .signal(let signal): return "Odczyt przerwany sygnałem \(signal)."
            case .timeout: return "Odczyt przekroczył 10 s."
            case .oversized: return "Odpowiedź przekroczyła 1 MiB."
            case .malformed: return "Niepoprawna odpowiedź API."
            case .spawn(let code): return "Nie można uruchomić herdr (errno \(code))."
            }
        }
    }

    private func label(_ text: String, size: CGFloat, bold: Bool = false, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
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

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
