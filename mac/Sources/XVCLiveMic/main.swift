import AppKit
import Combine

// Menu-bar app (LSUIElement in Info.plist = no Dock icon, no main window). The pipeline
// lives in XVCCore, shared with the xvc-cli test harness. See the README
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var engine = Engine(settings: settings)
    private var statusController: StatusItemController?
    private var cancellables = Set<AnyCancellable>()
    private var promptedSetup = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController(engine: engine, settings: settings)
        // Bring the pipeline up in passthrough immediately so "XVC Mic" is never a dead
        // device once the app is running (the README).
        // First run (or still unconfigured): say what's needed instead of sitting there as
        // an inert icon. Wait until the engine settles, so this doesn't stack on top of the
        // macOS microphone-permission prompt that start() triggers.
        engine.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self, !self.promptedSetup, !self.settings.isConfigured else { return }
                switch state {
                case .passthrough, .error:
                    self.promptedSetup = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.statusController?.promptSetup()
                    }
                default: break
                }
            }
            .store(in: &cancellables)

        engine.start()
        // Debug: auto-toggle Convert on launch so the connection path can be driven from a
        // terminal run without clicking the menu bar.
        if ProcessInfo.processInfo.environment["XVC_AUTOCONVERT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [engine] in engine.setConvert(true) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu-bar only
    app.run()
}
