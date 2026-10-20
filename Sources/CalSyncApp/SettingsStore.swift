import Foundation
import CalSyncCore

/// Persists `AppConfig` in UserDefaults. Replaces the old `~/.calsync/config.json`:
/// the app owns its settings now, and the Settings window is the only editor.
@MainActor
final class SettingsStore: ObservableObject {
    private static let key = "config"

    @Published var config: AppConfig {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
        } else {
            config = AppConfig()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    var side: (company: SyncSide?, client: SyncSide?) {
        (config.sides.first { $0.id == "company" }, config.sides.first { $0.id == "client" })
    }
}
