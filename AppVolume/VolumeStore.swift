import Foundation

/// Speichert Lautstärke und Stummschaltung pro App (Schlüssel: Bundle-ID) in den UserDefaults.
struct VolumeStore {
    private let defaults = UserDefaults.standard
    private let volumesKey = "volumes"
    private let mutedKey = "muted"

    func volume(for key: String) -> Double {
        (defaults.dictionary(forKey: volumesKey)?[key] as? Double) ?? 1.0
    }

    func isMuted(_ key: String) -> Bool {
        (defaults.dictionary(forKey: mutedKey)?[key] as? Bool) ?? false
    }

    func setVolume(_ volume: Double, for key: String) {
        var dict = defaults.dictionary(forKey: volumesKey) ?? [:]
        dict[key] = volume >= 0.999 ? nil : volume
        defaults.set(dict, forKey: volumesKey)
    }

    func setMuted(_ muted: Bool, for key: String) {
        var dict = defaults.dictionary(forKey: mutedKey) ?? [:]
        dict[key] = muted ? true : nil
        defaults.set(dict, forKey: mutedKey)
    }
}
