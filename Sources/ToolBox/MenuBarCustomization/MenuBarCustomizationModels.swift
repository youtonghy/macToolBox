import Foundation

/// Stable identifiers for the customizable menu-bar panel elements.
///
/// The identifiers are persisted, so they must never be renamed or reordered
/// in ways that change their raw values once shipped.
enum MenuBarElementID: String, Codable, CaseIterable, Identifiable {
    case chipPower
    case appAudio
    case cableStatus
    case wifiSignal
    case displayControl
    case quickControls

    var id: String { rawValue }

    /// The shipped default order. It also defines the order in which elements
    /// missing from a stored configuration are re-appended.
    static let defaultOrder: [MenuBarElementID] = [
        .chipPower,
        .appAudio,
        .cableStatus,
        .wifiSignal,
        .displayControl,
        .quickControls,
    ]

    var displayName: String {
        switch self {
        case .chipPower:
            return L10n.string("芯片功耗")
        case .appAudio:
            return L10n.string("应用音频")
        case .cableStatus:
            return L10n.string("线缆状态")
        case .wifiSignal:
            return L10n.string("Wi-Fi 信号")
        case .displayControl:
            return L10n.string("显示器控制")
        case .quickControls:
            return L10n.string("快捷控制")
        }
    }

    var symbolName: String {
        switch self {
        case .chipPower:
            return "cpu"
        case .appAudio:
            return "speaker.wave.2"
        case .cableStatus:
            return "cable.connector"
        case .wifiSignal:
            return "wifi"
        case .displayControl:
            return "display"
        case .quickControls:
            return "rectangle.inset.filled"
        }
    }
}

/// One element slot in the persisted layout: identity plus user visibility.
struct MenuBarElementEntry: Codable, Equatable, Identifiable {
    let id: MenuBarElementID
    var isVisible: Bool

    init(id: MenuBarElementID, isVisible: Bool = true) {
        self.id = id
        self.isVisible = isVisible
    }

    /// Decoding DTO: identifiers written by a newer build stay decodable so
    /// only the unknown entry is dropped instead of the whole payload.
    struct RawDTO: Codable {
        let id: String
        let isVisible: Bool?

        var entry: MenuBarElementEntry? {
            guard let id = MenuBarElementID(rawValue: id) else { return nil }
            return MenuBarElementEntry(id: id, isVisible: isVisible ?? true)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case isVisible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        guard let id = MenuBarElementID(rawValue: rawID) else {
        throw DecodingError.dataCorruptedError(
            forKey: .id,
            in: container,
            debugDescription: "Unknown menu bar element identifier \(rawID)"
        )
        }
        self.id = id
        // Missing flag degrades to "visible" so hand-edited or older payloads
        // keep every element after a decode.
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
    }
}

/// The complete persisted menu-bar layout: an ordered list of element entries.
struct MenuBarLayoutConfiguration: Equatable {
    var entries: [MenuBarElementEntry]

    static func `default`() -> MenuBarLayoutConfiguration {
        MenuBarLayoutConfiguration(
            entries: MenuBarElementID.defaultOrder.map { MenuBarElementEntry(id: $0) }
        )
    }

    /// Drops unknown identifiers, keeps only the first occurrence of each
    /// element, and appends any known-but-missing element in default order.
    func normalized() -> MenuBarLayoutConfiguration {
        var seen = Set<MenuBarElementID>()
        var ordered: [MenuBarElementEntry] = []
        for entry in entries where !seen.contains(entry.id) {
            seen.insert(entry.id)
            ordered.append(entry)
        }
        for id in MenuBarElementID.defaultOrder where !seen.contains(id) {
            seen.insert(id)
            ordered.append(MenuBarElementEntry(id: id))
        }
        return MenuBarLayoutConfiguration(entries: ordered)
    }

    func entry(for id: MenuBarElementID) -> MenuBarElementEntry? {
        entries.first { $0.id == id }
    }
}

/// Snapshot of the runtime signals that decide whether an element currently
/// has anything to show. Purely value-typed so both the live panel, the panel
/// height calculator, and the settings editor project identical results.
struct MenuBarElementRuntimeContext: Equatable {
    var cableItemCount: Int = 0
    var audioRowCount: Int = 0
    var isAudioLiteMode: Bool = false
    var hasExternalDisplay: Bool = false
    var showsColorPreset: Bool = false

    /// Elements that have no data right now stay configured but are hidden
    /// from the live menu bar until their runtime signal returns.
    func isRuntimeAvailable(_ id: MenuBarElementID) -> Bool {
        switch id {
        case .chipPower, .wifiSignal, .quickControls:
            return true
        case .appAudio:
            return audioRowCount > 0
        case .cableStatus:
            return cableItemCount > 0
        case .displayControl:
            return hasExternalDisplay
        }
    }
}

/// Unified projection shared by the live panel, the panel size calculator and
/// the settings editor: user-enabled entries in configured order, filtered by
/// current runtime availability.
enum MenuBarElementProjection {
    static func visibleElements(
        from entries: [MenuBarElementEntry],
        context: MenuBarElementRuntimeContext
    ) -> [MenuBarElementID] {
        entries
            .filter { $0.isVisible && context.isRuntimeAvailable($0.id) }
            .map(\.id)
    }
}
