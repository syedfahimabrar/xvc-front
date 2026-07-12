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
            // Nothing to convert with yet — guide the user to the menu (Add voice + Server
            // settings) instead of flashing a bare error triangle.
            openMenu()
        }
    }

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
        let (symbol, color, desc): (String, NSColor?, String)
        switch state {
        case .idle:        (symbol, color, desc) = ("mic.slash", nil, "XVC: off")
        case .passthrough: (symbol, color, desc) = ("mic", nil, "XVC: passthrough — your real voice")
        case .connecting:  (symbol, color, desc) = ("mic.badge.ellipsis", .systemOrange, "XVC: connecting…")
        case .converting:  (symbol, color, desc) = ("mic.fill", .systemGreen, "XVC: converting — far end hears the converted voice")
        case .error:       (symbol, color, desc) = ("exclamationmark.triangle.fill", .systemRed, "XVC: error (right-click for details)")
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

        let toggle = NSMenuItem(title: engine.isConverting ? "Convert: ON" : "Convert: OFF",
                                action: #selector(toggleConvert), keyEquivalent: "")
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
        let add = NSMenuItem(title: "Add voice…", action: #selector(addVoice), keyEquivalent: "")
        add.target = self
        menu.addItem(add)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Server settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quit = NSMenuItem(title: "Quit XVC Live Mic", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func statusHeader() -> NSMenuItem {
        let text: String
        switch engine.state {
        case .idle: text = "Off"
        case .passthrough: text = "Passthrough — your real voice"
        case .connecting: text = "Connecting…"
        case .converting: text = String(format: "Converting — ~%.0f ms latency", engine.latencyMs)
        case .error(let m): text = "Error: \(m)"
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

    @objc private func selectTarget(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String, let id = UUID(uuidString: idStr) else { return }
        settings.selectedTargetID = id
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
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow.make(settings: settings)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
