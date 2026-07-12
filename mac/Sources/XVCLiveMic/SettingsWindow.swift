import AppKit
import SwiftUI
import XVCCore

/// Server settings: host, port, token, self-signed trust, and which physical mic to
/// capture from. A small SwiftUI form hosted in a plain window.
enum SettingsWindow {
    @MainActor
    static func make(settings: AppSettings) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "XVC Live Mic — Server"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
        return window
    }
}

private struct SettingsView: View {
    let settings: AppSettings

    @State private var host: String
    @State private var port: String
    @State private var token: String
    @State private var trust: Bool
    @State private var inputDevice: String

    private let inputs: [String]

    init(settings: AppSettings) {
        self.settings = settings
        _host = State(initialValue: settings.host)
        _port = State(initialValue: String(settings.port))
        _token = State(initialValue: settings.token)
        _trust = State(initialValue: settings.trustSelfSigned)
        _inputDevice = State(initialValue: settings.inputDeviceName)
        inputs = AudioDevices.all().filter { $0.inputChannels > 0 && $0.name != "XVC Mic" }.map(\.name)
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Host / IP", text: $host)
                TextField("Port", text: $port)
                SecureField("Auth token", text: $token)
                Toggle("Trust self-signed certificate (dev)", isOn: $trust)
            }
            Section("Microphone") {
                Picker("Capture from", selection: $inputDevice) {
                    Text("System default").tag("")
                    ForEach(inputs, id: \.self) { Text($0).tag($0) }
                }
            }
            Text("The far end hears the converted voice by selecting \u{201C}XVC Mic\u{201D} as "
                 + "their microphone in the meeting app. Never pick XVC Mic as your speaker.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Save") { save(); close() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 340)
        .onDisappear { save() }
    }

    private func close() {
        // Dismiss the hosting window after saving, so the panel doesn't linger.
        NSApp.keyWindow?.close()
    }

    private func save() {
        settings.host = host.trimmingCharacters(in: .whitespaces)
        settings.port = Int(port) ?? 5002
        settings.token = token.trimmingCharacters(in: .whitespaces)
        settings.trustSelfSigned = trust
        settings.inputDeviceName = inputDevice
    }
}
