import Combine
import Foundation

/// Versioned persistence for the menu-bar layout. The payload is a JSON array
/// of `{ id, isVisible }` entries stored under `menuBar.customization.v1`.
struct MenuBarCustomizationStore {
    static let defaultsKey = "menuBar.customization.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> MenuBarLayoutConfiguration {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            return MenuBarLayoutConfiguration.default()
        }
        guard let configuration = Self.decode(data) else {
            // Unreadable payloads are backed up (see CorruptDefaultsBackup)
            // and replaced by the shipped default so the app keeps running.
            CorruptDefaultsBackup.backup(defaults: defaults, key: Self.defaultsKey)
            return MenuBarLayoutConfiguration.default()
        }
        return configuration.normalized()
    }

    func save(_ configuration: MenuBarLayoutConfiguration) {
        let normalized = configuration.normalized()
        guard let data = Self.encode(normalized) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func decode(_ data: Data) -> MenuBarLayoutConfiguration? {
        do {
            let rawEntries = try JSONDecoder().decode([MenuBarElementEntry.RawDTO].self, from: data)
            return MenuBarLayoutConfiguration(
                entries: rawEntries.compactMap { $0.entry }
            )
        } catch {
            return nil
        }
    }

    private static func encode(_ configuration: MenuBarLayoutConfiguration) -> Data? {
        do {
            return try JSONEncoder().encode(configuration.entries)
        } catch {
            return nil
        }
    }
}

/// The single shared layout model. Owned by `AppDelegate` and injected into
/// the live menu-bar panel, the panel size calculator and the settings
/// editor, so there is exactly one source of ordering/visibility truth.
@MainActor
final class MenuBarCustomizationModel: ObservableObject {
    @Published private(set) var entries: [MenuBarElementEntry]

    private let store: MenuBarCustomizationStore

    init(store: MenuBarCustomizationStore = MenuBarCustomizationStore()) {
        self.store = store
        entries = store.load().normalized().entries
    }

    func isVisible(_ id: MenuBarElementID) -> Bool {
        entry(for: id)?.isVisible ?? true
    }

    func setVisible(_ visible: Bool, for id: MenuBarElementID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].isVisible != visible else { return }
        entries[index].isVisible = visible
        persist()
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        entries.move(fromOffsets: offsets, toOffset: destination)
        persist()
    }

    func resetToDefault() {
        entries = MenuBarLayoutConfiguration.default().entries
        persist()
    }

    var isDefaultLayout: Bool {
        entries == MenuBarLayoutConfiguration.default().entries
    }

    private func entry(for id: MenuBarElementID) -> MenuBarElementEntry? {
        entries.first { $0.id == id }
    }

    private func persist() {
        store.save(MenuBarLayoutConfiguration(entries: entries))
    }
}
