import Foundation

enum CorruptDefaultsBackup {
    private static let maximumBackups = 3

    static func backup(defaults: UserDefaults, key: String) {
        guard let data = defaults.data(forKey: key) else { return }
        let prefix = "\(key).corrupt-"
        var existing = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .sorted()
        while existing.count >= maximumBackups {
            defaults.removeObject(forKey: existing.removeFirst())
        }
        let suffix = Int(Date().timeIntervalSince1970 * 1_000)
        defaults.set(data, forKey: "\(prefix)\(suffix)")
    }
}
