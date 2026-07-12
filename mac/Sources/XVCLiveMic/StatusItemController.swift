import AppKit
import Combine
import XVCCore

/// The menu-bar presence. Left click toggles Convert directly; right click opens the menu
/// (the README — the toggle must be one click mid-call, never behind a menu).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let engine: Engine
    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?

    init(engine: Engine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
        super.init()

        if let button = statusItem.button {
            button.action = #selector(clicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        engine.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.render($0) }
            .store(in: &cancellables)
        render(engine.state)
    }

    // MARK: - clicks

    @objc private func clicked() {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if rightClick {
            openMenu()
        } else if settings.isConfigured || engine.isConverting {
            engine.toggleConvert()
        } else {
            // Not set up yet. Say so plainly and offer the exact next step, rather than
            // silently doing nothing (or flashing a bare error).
            promptSetup()
        }
    }

    /// Spell out what's missing and take the user straight there. Called on a left click
    /// before setup is complete, and once at first launch.
    func promptSetup() {
        let needsServer = settings.host.isEmpty
        let needsVoice = settings.selectedTarget == nil
        guard needsServer || needsVoice else { return }

        var lines: [String] = []
        var actions: [() -> Void] = []

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Set up XVC Live Mic"
        if needsServer {
            lines.append("•  Your server address, port and auth token — ask whoever runs the server.")
        }
        if needsVoice {
            lines.append("•  A target voice: a .wav file of the voice you want to sound like.")
        }
        alert.informativeText = "Before you can convert your voice, you need:\n\n"
            + lines.joined(separator: "\n\n")

        if needsServer {
            alert.addButton(withTitle: "Server Settings…")
            actions.append { [weak self] in self?.openSettings() }
        }
        if needsVoice {
            alert.addButton(withTitle: "Add Voice…")
            actions.append { [weak self] in self?.addVoice() }
        }
        alert.addButton(withTitle: "Later")
        actions.append {}

        NSApp.activate(ignoringOtherApps: true)
        // Buttons come back as .alertFirstButtonReturn, +1, +2 … in the order added.
        let idx = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if idx >= 0, idx < actions.count { actions[idx]() }
    }

    /// Re-render after settings change, so the "setup needed" badge clears the moment the
    /// user finishes configuring.
    func refresh() { render(engine.state) }

    private func openMenu() {
        let menu = buildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)   // pops the menu
        statusItem.menu = nil                   // detach so left-click toggles again
    }

    // MARK: - icon

    private func render(_ state: Engine.State) {
        guard let button = statusItem.button else { return }
        // A colored (non-template) symbol actually shows color in the menu bar; a template
        // one is forced to the bar's black/white and ignores contentTintColor — which is why
        // the earlier tinted "converting" looked identical to passthrough. So: converting is
        // GREEN, passthrough/idle are plain monochrome. Green vs. mono is the at-a-glance cue
        // that the far end hears the converted voice, not your real one (the README).
        var (symbol, color, desc): (String, NSColor?, String)
        switch state {
        case .idle:        (symbol, color, desc) = ("mic.slash", nil, "XVC: off")
        case .passthrough: (symbol, color, desc) = ("mic", nil, "XVC: passthrough — your real voice")
        case .connecting:  (symbol, color, desc) = ("mic.badge.ellipsis", .systemOrange, "XVC: connecting…")
        case .converting:  (symbol, color, desc) = ("mic.fill", .systemGreen, "XVC: converting — far end hears the converted voice")
        case .error:       (symbol, color, desc) = ("exclamationmark.triangle.fill", .systemRed, "XVC: error (right-click for details)")
        }
        // Not set up yet: say so in the bar rather than looking like a working idle app.
        // A real error still wins — it's the more urgent thing to show.
        var isError = false
        if case .error = state { isError = true }
        if !settings.isConfigured, !engine.isConverting, !isError {
            (symbol, color, desc) = ("mic.badge.plus", .systemOrange,
                                     "XVC: setup needed — click to add your server and a voice")
        }
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)
        if let color {
            let cfg = NSImage.SymbolConfiguration(paletteColors: [color])
            let colored = base?.withSymbolConfiguration(cfg)
            colored?.isTemplate = false
            button.image = colored
        } else {
            base?.isTemplate = true            // tracks the light/dark menu bar
            button.image = base
        }
        button.contentTintColor = nil
        button.toolTip = desc
    }

    // MARK: - menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(statusHeader())
        menu.addItem(.separator())

        let ready = settings.isConfigured
        let toggle = NSMenuItem(title: ready ? (engine.isConverting ? "Convert: ON" : "Convert: OFF")
                                             : "Convert (finish setup first)",
                                action: ready ? #selector(toggleConvert) : #selector(promptSetupAction),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = engine.isConverting ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())
        menu.addItem(sectionLabel("Target voice"))
        for target in settings.targets {
            let item = NSMenuItem(title: target.name, action: #selector(selectTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.id.uuidString
            item.state = (settings.selectedTarget?.id == target.id) ? .on : .off
            menu.addItem(item)
        }
        let addTitle = settings.selectedTarget == nil ? "Add voice…  ⚠︎ required" : "Add voice…"
        let add = NSMenuItem(title: addTitle, action: #selector(addVoice), keyEquivalent: "")
        add.target = self
        menu.addItem(add)

        menu.addItem(.separator())
        let settingsTitle = settings.host.isEmpty ? "Server settings…  ⚠︎ required" : "Server settings…"
        let settingsItem = NSMenuItem(title: settingsTitle, action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quit = NSMenuItem(title: "Quit XVC Live Mic", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func statusHeader() -> NSMenuItem {
        var text: String
        switch engine.state {
        case .idle: text = "Off"
        case .passthrough: text = "Passthrough — your real voice"
        case .connecting: text = "Connecting…"
        case .converting: text = String(format: "Converting — ~%.0f ms latency", engine.latencyMs)
        case .error(let m): text = "Error: \(m)"
        }
        // Before setup, the state is beside the point — tell them what to do instead.
        if !settings.isConfigured, !engine.isConverting {
            switch (settings.host.isEmpty, settings.selectedTarget == nil) {
            case (true, true):  text = "Setup needed — add your server and a voice"
            case (true, false): text = "Setup needed — add your server"
            case (false, true): text = "Setup needed — add a target voice"
            default: break
            }
        }
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func sectionLabel(_ s: String) -> NSMenuItem {
        let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - actions

    @objc private func toggleConvert() { engine.toggleConvert() }

    @objc private func promptSetupAction() { promptSetup() }

    @objc private func selectTarget(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String, let id = UUID(uuidString: idStr) else { return }
        settings.selectedTargetID = id
        refresh()
    }

    @objc private func addVoice() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var list = settings.targets
        let name = url.deletingPathExtension().lastPathComponent
        let voice = TargetVoice(name: name, wavPath: url.path, targetID: nil)
        list.append(voice)
        settings.targets = list
        settings.selectedTargetID = voice.id
        refresh()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow.make(settings: settings) { [weak self] in self?.refresh() }
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
