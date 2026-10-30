import AppKit
import ImageIO
import OverlayCore
import QuartzCore


private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Illustrated dog frames, decoded once from the bundled PNGs.
private enum CorgiArt {
    static let frames: [MascotFrame: NSImage] = {
        var frames: [MascotFrame: NSImage] = [:]
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        for frame in MascotFrame.allCases {
            guard let url = Bundle.module.url(forResource: frame.resourceName, withExtension: "png",
                                              subdirectory: "Corgi"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
                NSLog("Herdr Status Overlay: missing dog frame %@", frame.resourceName)
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
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = bounds.width / Self.side
        guard scale > 0 else { return }
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        // Inset so the highest hop (5 pt) still fits inside the view.
        CorgiArt.frames[art]?.draw(in: NSRect(x: 3, y: 1 + lift, width: Self.side - 6, height: Self.side - 6))
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
        context.restoreGState()
    }
}


private final class ThoughtBubbleView: NSView {
    private let reduceTransparency: Bool
    private let direction: PanelDirection

    init(reduceTransparency: Bool, direction: PanelDirection) {
        self.reduceTransparency = reduceTransparency
        self.direction = direction
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.white.withAlphaComponent(reduceTransparency ? 1 : ThoughtBubble.opacity).cgColor)
        let transform = CGAffineTransform(a: direction.extendsLeft ? 1 : -1, b: 0, c: 0,
                                         d: direction.extendsUp ? 1 : -1,
                                         tx: direction.extendsLeft ? 0 : bounds.width,
                                         ty: direction.extendsUp ? 0 : bounds.height)
        context.concatenate(transform)
        context.addPath(ThoughtBubble.path(in: bounds, tailX: bounds.maxX - 16))
        context.fillPath()
    }
}

private final class CardBackdropView: NSVisualEffectView {
    static let tailHeight: CGFloat = 9
    private let speechTail: Bool
    private let direction: PanelDirection

    init(speechTail: Bool, reduceTransparency: Bool, direction: PanelDirection) {
        self.speechTail = speechTail
        self.direction = direction
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
        var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: direction.extendsUp ? 1 : -1,
                                          tx: 0, ty: direction.extendsUp ? 0 : bounds.height)
        mask.path = path.copy(using: &transform)
        layer.mask = mask
    }
}
/// The panel never becomes key, so cursor rects are ignored; a tracking area shows the hand instead.
private func trackPointingHand(_ view: NSView) {
    for area in view.trackingAreas where area.options.contains(.cursorUpdate) { view.removeTrackingArea(area) }
    view.addTrackingArea(NSTrackingArea(rect: .zero,
                                        options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                        owner: view, userInfo: nil))
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackPointingHand(self)
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        super.mouseExited(with: event)
    }
}

/// Chevron toggle that shows the hand like the clickable rows.
private final class PointerButton: NSButton {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackPointingHand(self)
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        super.mouseExited(with: event)
    }
}

final class PanelController: NSObject, NSWindowDelegate {
    private static let width: CGFloat = 420
    private static let margin: CGFloat = 16
    /// Band under the scrolling cards sized for the mascot scene.
    private var mascotSide: CGFloat = CorgiView.side
    private var mascotFooter: CGFloat { mascotSide + 4 }

    private let panel: NSPanel
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let stateFile: URL
    private var state: PanelState
    private var rendered: [SectionView]?
    private let corgi = CorgiView(frame: NSRect(x: 0, y: 0, width: CorgiView.side, height: CorgiView.side))
    private var animationTimer: Timer?
    private var celebrationTimer: Timer?
    private var hover = AutoHideHover()
    private var compact: Bool { state.showsCompact(hovered: hover.expanded) }
    private var mood: MascotMood?
    private var tick = 0
    private var workActivity = MascotActivity.allCases.randomElement()!
    private var pairAnimation = MascotPairAnimation()
    private var flipStartedAt: TimeInterval?
    private var mascotCornerConstraints: [NSLayoutConstraint] = []
    private var scrollBottom: NSLayoutConstraint!
    private var scrollTop: NSLayoutConstraint!
    private var corgiWidthConstraint: NSLayoutConstraint!
    private var corgiHeightConstraint: NSLayoutConstraint!

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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateCorgiMood),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeSpaceChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil)
    }

    /// User preference, independent of automatic hiding when no cards are available.
    var isVisibilityEnabled: Bool { state.visible }

    var isAutoHideEnabled: Bool { state.autoHide }
    var direction: PanelDirection { state.direction }

    func setDirection(_ direction: PanelDirection) {
        guard direction != state.direction, let screen = currentScreen else { return }
        let dog = PanelGeometry.anchoredFrame(size: restingSize(in: screen.visibleFrame),
                                             of: panel.frame, direction: state.direction)
        state.direction = direction
        adjustingFrame = true
        panel.setFrame(PanelGeometry.anchoredFrame(size: panel.frame.size, of: dog, direction: direction), display: false)
        adjustingFrame = false
        rebuildContent()
        recordPosition()
        saveState()
    }
    var dogScalePercent: Int { state.dogScalePercent }

    func setDogScalePercent(_ percent: Int) {
        guard PanelState.dogScalePercentRange.contains(percent), percent != state.dogScalePercent else { return }
        state.dogScalePercent = percent
        if let screen = currentScreen {
            if updateMascotSize(for: screen.visibleFrame) { rebuildContent() }
            resize(to: screen)
            recordPosition()
        }
        saveState()
    }


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

    /// Compact content depends on counters and availability, not agent titles or row order.
    func render(_ sections: [SectionView]) {
        let sections = sections.filter(\.shouldDisplay)
        guard sections != rendered else { return }
        let sameSummary = compact && rendered.map { previous in
            previous.isEmpty == sections.isEmpty
                && SectionView.activeCounts(in: previous) == SectionView.activeCounts(in: sections)
                && previous.filter(\.stale).map(\.label) == sections.filter(\.stale).map(\.label)
        } == true
        rendered = sections
        if sameSummary { updateCorgiMood() } else { rebuildContent() }
    }

    private func rebuildContent() {
        // Removed rows and buttons never get mouseExited, so drop a hand left over from them.
        NSCursor.arrow.set()
        let sections = rendered ?? []
        // A collapsed cloud has no scrolling content; legacy scrollers otherwise leave a clipped gutter.
        scroll.hasVerticalScroller = !(state.autoHide && compact)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        contentWidth = Self.width
        stack.alignment = .leading
        if compact {
            addCompactSummary(sections)
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
        updateCorgiMood()
    }

    // MARK: Panel setup

    private func configurePanel() {
        corgi.setAccessibilityLabel("Dog status mascot")
        corgi.translatesAutoresizingMaskIntoConstraints = false
        corgiWidthConstraint = corgi.widthAnchor.constraint(equalToConstant: mascotSide)
        corgiHeightConstraint = corgi.heightAnchor.constraint(equalToConstant: mascotSide)
        NSLayoutConstraint.activate([corgiWidthConstraint, corgiHeightConstraint])
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
        scrollTop = scroll.topAnchor.constraint(equalTo: background.topAnchor)

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
            scrollTop,
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
        let transparentBubble = speechTail && state.autoHide
        card.appearance = NSAppearance(named: transparentBubble && NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                                      ? .aqua : .darkAqua)
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 4
        let padding: CGFloat = transparentBubble ? 20 : 12
        let tail = transparentBubble ? ThoughtBubble.tailHeight : (speechTail ? CardBackdropView.tailHeight : 0)
        let verticalPadding: CGFloat = transparentBubble ? 12 : 10
        card.edgeInsets = NSEdgeInsets(top: verticalPadding + (state.direction.extendsUp ? 0 : tail), left: padding,
                                       bottom: verticalPadding + (state.direction.extendsUp ? tail : 0), right: padding)
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.clear.cgColor
        card.layer?.cornerRadius = 10
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(card)
        let backdrop: NSView = transparentBubble
            ? ThoughtBubbleView(reduceTransparency: reduceTransparency, direction: state.direction)
            : CardBackdropView(speechTail: speechTail, reduceTransparency: reduceTransparency, direction: state.direction)
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

    /// Keeps the mascot outside the scrolling cards, opposite the list's direction.
    private func addCorgiCorner() {
        guard let background = panel.contentView else { return }
        NSLayoutConstraint.deactivate(mascotCornerConstraints)
        corgi.removeFromSuperview()
        background.addSubview(corgi)
        scrollTop.constant = state.direction.extendsUp ? 0 : mascotFooter
        scrollBottom.constant = state.direction.extendsUp ? -mascotFooter : 0
        mascotCornerConstraints = [
            state.direction.extendsLeft
                ? corgi.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8)
                : corgi.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            state.direction.extendsUp
                ? corgi.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -2)
                : corgi.topAnchor.constraint(equalTo: background.topAnchor, constant: 2)
        ]
        NSLayoutConstraint.activate(mascotCornerConstraints)
    }

    @objc private func activeSpaceChanged() {
        updateCorgiMood()
        guard panel.isVisible, flipStartedAt == nil, let mood,
              MascotAnimation.flipFrame(for: mood, elapsed: 0,
                  reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) != nil else { return }
        flipStartedAt = ProcessInfo.processInfo.systemUptime
        updateCorgiMood()
    }

    /// Select mood on data changes or celebration expiry, never on every animation frame.
    @objc private func updateCorgiMood() {
        let now = MonotonicClock.now()
        let sections = rendered ?? []
        let mood = MascotMood.select(in: sections, now: now)
        if mood != self.mood {
            self.mood = mood
            tick = 0
            if mood == .working { workActivity = MascotActivity.allCases.randomElement()! }
            corgi.setAccessibilityLabel("Dog: \(mood)")
        }
        if mood == .blocked || mood == .unavailable {
            pairAnimation.interrupt()
        } else {
            pairAnimation.setActive(MascotMood.workingCount(in: sections) >= 2,
                                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        showCorgiFrame()
        celebrationTimer?.invalidate()
        celebrationTimer = nil
        if panel.isVisible, mood == .celebrating,
           let event = sections.filter({ $0.shouldDisplay && !$0.stale }).flatMap(\.rows)
            .compactMap(\.completionEventAt).filter({ $0 <= now }).max() {
            let remaining = Double(seconds(3) - (now - event)) / 1_000_000_000
            celebrationTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                self?.updateCorgiMood()
            }
        }
        let animate = MascotAnimation.isAnimated(for: mood,
                          reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if panel.isVisible && (state.autoHide || animate || pairAnimation.needsTicks || flipStartedAt != nil) {
            guard animationTimer == nil else { return }
            animationTimer = Timer.scheduledTimer(withTimeInterval: MascotAnimation.tickInterval,
                                                  repeats: true) { [weak self] _ in
                guard let self else { return }
                let wasFlipping = self.flipStartedAt != nil
                let wasPairTicking = self.pairAnimation.needsTicks
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                let flipVisible: Bool
                if let startedAt = self.flipStartedAt, self.panel.isVisible, let mood = self.mood {
                    flipVisible = MascotAnimation.flipFrame(for: mood,
                        elapsed: ProcessInfo.processInfo.systemUptime - startedAt, reduceMotion: reduceMotion) != nil
                } else {
                    flipVisible = false
                }
                let pairSceneVisible = self.mood == .pairWorking || self.pairAnimation.isExiting
                self.pairAnimation.tick(visible: pairSceneVisible && !flipVisible)
                if let mood = self.mood, MascotAnimation.isAnimated(for: mood,
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
                    self.tick += 1
                    if mood == .working && self.tick >= self.workActivity.durationTicks {
                        self.workActivity = self.workActivity.randomSuccessor()
                        self.tick = 0
                    }
                }
                self.showCorgiFrame()
                if wasPairTicking && !self.pairAnimation.needsTicks { self.updateCorgiMood() }
                if wasFlipping && self.flipStartedAt == nil { self.updateCorgiMood() }
                self.updateHover()
            }
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func showCorgiFrame() {
        guard let mood else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let startedAt = flipStartedAt, panel.isVisible,
           let frame = MascotAnimation.flipFrame(for: mood,
               elapsed: ProcessInfo.processInfo.systemUptime - startedAt, reduceMotion: reduceMotion) {
            corgi.show(frame, lift: 0, sleepPhases: [])
            return
        }
        flipStartedAt = nil
        if let frame = pairAnimation.frame(reduceMotion: reduceMotion),
           (mood == .pairWorking || pairAnimation.isExiting) {
            corgi.show(frame, lift: 0, sleepPhases: [])
            return
        }
        corgi.show(MascotAnimation.frame(for: mood, tick: tick, reduceMotion: reduceMotion, activity: workActivity),
                   lift: CGFloat(MascotAnimation.lift(for: mood, tick: tick, reduceMotion: reduceMotion)),
                   sleepPhases: mood == .sleeping ? MascotAnimation.sleepPhases(tick: tick, reduceMotion: reduceMotion) : [])
    }

    private func toggleButton() -> NSButton {
        let title = state.minimized ? "Expand overlay" : "Minimize overlay"
        let button = PointerButton(image: NSImage(systemSymbolName: state.minimized ? "chevron.right" : "chevron.down",
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
        let counts = SectionView.activeCounts(in: sections)
        if state.autoHide, counts?.isEmpty == true {
            addCorgiCorner()
            contentWidth = mascotSide + 16
            return
        }
        let card = makeCard(fillWidth: false, speechTail: true)
        let counters = countView(counts,
                                 order: [.working, .blocked, .done], emptyText: "No active agents")
        // Measure before attaching to the old panel width; stack fitting sizes can retain that width.
        let counterWidth = counters.fittingSize.width
        let button = toggleButton()
        let line = NSStackView(views: state.autoHide ? [counters] : [button, counters])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 10
        card.addArrangedSubview(line)
        let unavailable = sections.filter(\.stale).map(\.label)
        card.toolTip = unavailable.isEmpty ? counters.toolTip
            : "Fresh sources only. Unavailable: " + unavailable.joined(separator: ", ")
        addCorgiCorner()
        let padding: CGFloat = state.autoHide ? 40 : 24
        let controls = state.autoHide ? 0 : button.fittingSize.width + line.spacing
        let sideInset: CGFloat = state.autoHide ? mascotSide / 2 : 0
        let bubbleWidth = min(Self.width, ceil(counterWidth + padding + controls))
        card.widthAnchor.constraint(equalToConstant: bubbleWidth).isActive = true
        contentWidth = max(mascotSide + 16, bubbleWidth + sideInset)
        let alignLeft = state.autoHide ? state.direction.extendsLeft : !state.direction.extendsLeft
        stack.alignment = alignLeft ? .leading : .trailing
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
        if state.autoHide && compact && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black
            shadow.shadowBlurRadius = 2
            let value = NSMutableAttributedString(attributedString: field.attributedStringValue)
            value.addAttribute(.shadow, value: shadow, range: NSRange(location: 0, length: value.length))
            field.attributedStringValue = value
        }
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
        let footer = mascotFooter
        let height = min(stack.fittingSize.height + footer, screen.visibleFrame.height * 0.4).rounded(.up)
        let frame = PanelGeometry.anchoredFrame(size: NSSize(width: contentWidth, height: max(height, 40)),
                                                of: panel.frame, direction: state.direction)
        panel.setFrame(clamped(frame, to: screen), display: true)
    }

    private func updateMascotSize(for visible: NSRect) -> Bool {
        let side = PanelGeometry.mascotSide(baseSide: CorgiView.side,
                                            scalePercent: state.dogScalePercent, in: visible)
        guard abs(side - mascotSide) > 0.5 else { return false }
        mascotSide = side
        corgiWidthConstraint.constant = side
        corgiHeightConstraint.constant = side
        corgi.setNeedsDisplay(corgi.bounds)
        return true
    }

    private func restingSize(in visible: NSRect) -> NSSize {
        NSSize(width: min(mascotSide + 16, visible.width),
               height: min(mascotFooter, visible.height * 0.4))
    }

    private func placeFromState() {
        let saved = NSScreen.screens.first { number(of: $0) == state.screen }
        guard let screen = saved ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        if updateMascotSize(for: visible) { rebuildContent() }
        var frame = panel.frame
        if saved != nil, let left = state.left, let top = state.top {
            let size = state.autoHide || state.mascotAnchored ? restingSize(in: visible) : frame.size
            let savedFrame = NSRect(x: visible.minX + left, y: visible.maxY - top - size.height,
                                    width: size.width, height: size.height)
            frame = PanelGeometry.anchoredFrame(size: frame.size, of: savedFrame, direction: state.direction)
        } else {
            frame.origin = NSPoint(x: visible.maxX - frame.width - Self.margin,
                                   y: visible.maxY - frame.height - Self.margin)
        }
        panel.setFrame(clamped(frame, to: screen), display: false)
        recordPosition()
    }

    private func clamped(_ frame: NSRect, to screen: NSScreen) -> NSRect {
        state.autoHide
            ? PanelGeometry.autoHideFrame(frame, expandedWidth: max(Self.width, contentWidth),
                                          direction: state.direction, in: screen.visibleFrame)
            : PanelGeometry.clamp(frame, to: screen.visibleFrame)
    }

    private func number(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func recordPosition() {
        guard let screen = currentScreen else { return }
        let visible = screen.visibleFrame
        state.screen = number(of: screen)
        // Content can change before or after restart; persist only the fixed mascot footprint.
        let frame = PanelGeometry.anchoredFrame(size: restingSize(in: visible),
                                                of: panel.frame, direction: state.direction)
        state.mascotAnchored = true
        state.left = Double(frame.minX - visible.minX)
        state.top = Double(visible.maxY - frame.maxY)
    }

    func windowDidMove(_ notification: Notification) {
        guard !adjustingFrame else { return }
        if let screen = currentScreen, updateMascotSize(for: screen.visibleFrame) { rebuildContent() }
        resize()
        recordPosition()
        saveState()
    }

    /// A disconnected monitor or resolution change moves the panel back into a visible area.
    @objc private func screensChanged() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        if updateMascotSize(for: screen.visibleFrame) { rebuildContent() }
        resize(to: screen)
        recordPosition()
        saveState()
    }
}
