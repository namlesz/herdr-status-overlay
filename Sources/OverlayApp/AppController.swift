import AppKit
import OverlayCore

final class AppController: NSObject, NSApplicationDelegate {
    private static let terminalBundleID = "com.mitchellh.ghostty"

    private let sources: [SourceConfig]
    private let model: OverlayModel
    private let pollers: [SourcePoller]
    private let panel: PanelController
    private let delivery = LatestSections()
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var autoHideItem: NSMenuItem?
    private var timer: Timer?
    private var stopping = false
    private let focusQueue = DispatchQueue(label: "overlay.focus")
    /// Main thread only.
    private var focusing = false
    private let focusRunner: ProcessRunner = {
        var limits = RunLimits()
        limits.timeout = 5
        return ProcessRunner(limits: limits)
    }()

    init(sources: [SourceConfig], stateDirectory: URL) {
        self.sources = sources
        let model = OverlayModel(sources: sources)
        self.model = model
        pollers = sources.map { SourcePoller(source: $0, model: model) }
        panel = PanelController(stateFile: stateDirectory.appendingPathComponent("panel.json"))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let delivery = self.delivery
        model.onChange = { [weak self] views in
            if delivery.replace(views) {
                DispatchQueue.main.async { self?.panel.render(delivery.take()) }
            }
        }
        panel.onSelect = { [weak self] row in self?.open(row) }
        panel.render(model.snapshot())
        panel.restoreVisibility()
        installStatusItem()

        // Freshness and retention advance with time even when no read finishes.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [model] _ in model.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [model, pollers] _ in
                model.wake()
                pollers.forEach { $0.refresh() }
            }
        pollers.forEach { $0.start() }
    }

    func shutdown() {
        guard !stopping else { return }
        stopping = true
        timer?.invalidate()
        focusRunner.cancel()
        pollers.forEach { $0.stop() }
        // Children are in their own sessions; wait for each runner to finish its group cleanup.
        for poller in pollers { _ = poller.drain(timeout: 3) }
        panel.saveState()
        exit(0)
    }

    /// Brings the terminal forward at once (switching Spaces if needed) and selects the agent's pane in Herdr.
    /// Which Ghostty window comes forward is up to macOS; the overlay cannot map clients to windows.
    private func open(_ row: RowView) {
        guard let source = sources.first(where: { $0.id == row.sourceID }),
              let arguments = source.focusArguments(paneID: row.key.paneID) else { return NSSound.beep() }
        // Not after the focus command: remote focus over ssh would delay the switch by seconds.
        Self.activateTerminal()
        // Extra focus commands while one is in flight would only queue up.
        guard !focusing else { return }
        focusing = true
        focusQueue.async { [focusRunner] in
            let outcome = focusRunner.run(arguments)
            DispatchQueue.main.async {
                self.focusing = false
                if case .exited(0, _, _) = outcome { return }
                NSSound.beep()
            }
        }
    }

    /// LaunchServices activation works from this non-active accessory app, unlike `activate()`.
    private static func activateTerminal() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID) else {
            return NSSound.beep()
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "HSO"
        item.button?.setAccessibilityLabel("Herdr Status Overlay")
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let autoHide = NSMenuItem(title: "Auto-hide", action: #selector(toggleAutoHide), keyEquivalent: "")
        autoHide.target = self
        autoHide.state = panel.isAutoHideEnabled ? .on : .off
        menu.addItem(autoHide)
        autoHideItem = autoHide
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit overlay", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        toggleItem = toggle
        updateToggleTitle()
    }

    private func updateToggleTitle() {
        toggleItem?.title = panel.isVisibilityEnabled ? "Hide panel" : "Show panel"
    }

    @objc private func toggle() {
        panel.setVisible(!panel.isVisibilityEnabled)
        updateToggleTitle()
    }

    @objc private func toggleAutoHide() {
        panel.setAutoHide(!panel.isAutoHideEnabled)
        autoHideItem?.state = panel.isAutoHideEnabled ? .on : .off
    }

    @objc private func quit() { shutdown() }
}
