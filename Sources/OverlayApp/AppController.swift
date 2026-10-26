import AppKit
import OverlayCore

final class AppController: NSObject, NSApplicationDelegate {
    private let model: OverlayModel
    private let pollers: [SourcePoller]
    private let panel: PanelController
    private let delivery = LatestSections()
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var timer: Timer?
    private var stopping = false

    init(sources: [SourceConfig], stateDirectory: URL) {
        let model = OverlayModel(sources: sources)
        self.model = model
        pollers = sources.map { SourcePoller(source: $0, model: model) }
        panel = PanelController(stateFile: stateDirectory.appendingPathComponent("panel.json"),
                                onAcknowledge: { model.acknowledge($0, key: $1) })
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let delivery = self.delivery
        model.onChange = { [weak self] views in
            if delivery.replace(views) {
                DispatchQueue.main.async { self?.panel.render(delivery.take()) }
            }
        }
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
        pollers.forEach { $0.stop() }
        // Children are in their own sessions; wait for each runner to finish its group cleanup.
        for poller in pollers { _ = poller.drain(timeout: 3) }
        panel.saveState()
        exit(0)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "HSO"
        item.button?.setAccessibilityLabel("Herdr Status Overlay")
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Zakończ overlay", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        toggleItem = toggle
        updateToggleTitle()
    }

    private func updateToggleTitle() {
        toggleItem?.title = panel.isVisible ? "Ukryj panel" : "Pokaż panel"
    }

    @objc private func toggle() {
        panel.setVisible(!panel.isVisible)
        updateToggleTitle()
    }

    @objc private func quit() { shutdown() }
}
