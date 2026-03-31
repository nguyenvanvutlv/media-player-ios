import Foundation

/// Lightweight global settings storage for feature flags.
/// Stored in `UserDefaults` to avoid threading/SwiftData access in the playback pipeline.
final class Settings {
    static let shared = Settings()

    private init() {}

    private enum Keys {
        static let enableLibass = "settings.enableLibass"
    }

    var enableLibass: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enableLibass) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enableLibass) }
    }
}

