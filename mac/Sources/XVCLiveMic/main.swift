import AppKit

// Menu-bar app (LSUIElement in Info.plist = no Dock icon, no main window). The pipeline
// lives in XVCCore, shared with the xvc-cli test harness. See docs/MAC_APP.md §3.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var engine = Engine(settings: settings)
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController(engine: engine, settings: settings)
        // Bring the pipeline up in passthrough immediately so "XVC Mic" is never a dead
        // device once the app is running (docs/MAC_APP.md §4).
        engine.start()
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
