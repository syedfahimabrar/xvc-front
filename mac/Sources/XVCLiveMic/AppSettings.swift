import Foundation

/// A saved target voice: the local WAV plus the server handle it was last loaded as.
/// target_id doesn't survive a server restart, so it's a cache — re-uploaded on demand.
struct TargetVoice: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var wavPath: String
    var targetID: String?          // last-known server handle; nil until uploaded
}

/// Persisted user settings. Plain UserDefaults — this is a single-user menu-bar app.
final class AppSettings {
    private let defaults = UserDefaults.standard

    var host: String {
        get { defaults.string(forKey: "host") ?? "" }
        set { defaults.set(newValue, forKey: "host") }
    }
    var port: Int {
        get { defaults.object(forKey: "port") as? Int ?? 5002 }
        set { defaults.set(newValue, forKey: "port") }
    }
    var token: String {
        get { defaults.string(forKey: "token") ?? "" }
        set { defaults.set(newValue, forKey: "token") }
    }
    /// Trust a self-signed cert. Dev only — the shipped default is false.
    var trustSelfSigned: Bool {
        get { defaults.bool(forKey: "trustSelfSigned") }
        set { defaults.set(newValue, forKey: "trustSelfSigned") }
    }
    /// Physical mic to capture from. Empty = system default input (but never XVC Mic).
    var inputDeviceName: String {
        get { defaults.string(forKey: "inputDeviceName") ?? "" }
        set { defaults.set(newValue, forKey: "inputDeviceName") }
    }

    var targets: [TargetVoice] {
        get {
            guard let data = defaults.data(forKey: "targets"),
                  let list = try? JSONDecoder().decode([TargetVoice].self, from: data) else { return [] }
            return list
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "targets") }
    }
    var selectedTargetID: UUID? {
        get { defaults.string(forKey: "selectedTarget").flatMap(UUID.init) }
        set { defaults.set(newValue?.uuidString, forKey: "selectedTarget") }
    }

    var selectedTarget: TargetVoice? {
        guard let id = selectedTargetID else { return targets.first }
        return targets.first { $0.id == id } ?? targets.first
    }

    var isConfigured: Bool { !host.isEmpty && selectedTarget != nil }
}
