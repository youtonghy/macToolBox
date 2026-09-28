import Foundation

/// The macOS network locations (`networksetup -listlocations`) plus the
/// currently active one (`networksetup -getcurrentlocation`).
struct NetworkLocationSnapshot: Equatable {
    var locations: [String]
    var current: String?

    static let empty = NetworkLocationSnapshot(locations: [], current: nil)
}

enum NetworkLocationError: LocalizedError, Equatable {
    case invalidName
    case invalidRule
    case alreadyExists(String)
    case notFound(String)
    case cancelled
    case timedOut
    case launchFailed(String)
    case commandFailed(String)
    case notApplied(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return L10n.string("位置名称不能为空，不能以“-”开头，且不能包含换行")
        case .invalidRule:
            return L10n.string("SSID 和位置都不能为空")
        case let .alreadyExists(name):
            return String(format: L10n.string("位置“%@”已存在"), name)
        case let .notFound(name):
            return String(format: L10n.string("位置“%@”不存在"), name)
        case .cancelled:
            return L10n.string("已取消管理员授权")
        case .timedOut:
            return L10n.string("networksetup 执行超时")
        case let .launchFailed(detail):
            return String(format: L10n.string("无法启动 networksetup：%@"), detail)
        case let .commandFailed(detail):
            return detail.isEmpty ? L10n.string("networksetup 执行失败") : detail
        case let .notApplied(name):
            return String(format: L10n.string("系统未切换到位置“%@”"), name)
        }
    }
}

enum NetworkLocationName {
    static let maximumLength = 64

    /// Trims surrounding whitespace and rejects names that `networksetup`
    /// would misparse (leading `-`) or that cannot round-trip through its
    /// line-based `-listlocations` output.
    static func normalized(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maximumLength,
              !trimmed.hasPrefix("-"),
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw NetworkLocationError.invalidName
        }
        return trimmed
    }
}

/// Pure parsing of `networksetup` output so it can be unit tested.
enum NetworkSetupOutput {
    static func locations(from output: String) -> [String] {
        var seen = Set<String>()
        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isErrorLine($0) && seen.insert($0).inserted }
    }

    static func currentLocation(from output: String) -> String? {
        let lines = locations(from: output)
        return lines.count == 1 ? lines[0] : nil
    }

    /// `networksetup` refuses writes for non-admin users, or for everyone but
    /// root when "require an administrator password" is enabled.
    static func indicatesMissingPrivileges(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("privileges") || lowered.contains("requires admin")
            || lowered.contains("not authorized") || lowered.contains("permission denied")
    }

    private static func isErrorLine(_ line: String) -> Bool {
        line.hasPrefix("**") || line.lowercased().hasPrefix("error")
    }
}

// MARK: - SSID based auto switching

struct NetworkLocationSSIDRule: Codable, Equatable, Identifiable {
    var id: UUID
    var ssid: String
    var location: String

    init(id: UUID = UUID(), ssid: String, location: String) {
        self.id = id
        self.ssid = ssid
        self.location = location
    }
}

struct NetworkLocationAutoSwitchConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var rules: [NetworkLocationSSIDRule]
    /// Location applied when connected to a Wi-Fi network without a rule.
    /// `nil` leaves the current location untouched.
    var fallbackLocation: String?

    static let disabled = NetworkLocationAutoSwitchConfiguration(
        isEnabled: false,
        rules: [],
        fallbackLocation: nil
    )
}

enum NetworkLocationAutoSwitchPolicy {
    /// Returns the location to switch to for the given SSID, or `nil` when
    /// nothing should change. Disconnected states (`ssid == nil`) never switch
    /// so brief roaming gaps cannot flap the location. The first matching rule
    /// wins; SSIDs compare exactly because they are case sensitive.
    static func targetLocation(
        ssid: String?,
        configuration: NetworkLocationAutoSwitchConfiguration,
        snapshot: NetworkLocationSnapshot
    ) -> String? {
        guard configuration.isEnabled, let ssid, !ssid.isEmpty else { return nil }
        let target = configuration.rules.first { $0.ssid == ssid }?.location
            ?? configuration.fallbackLocation
        guard let target,
              snapshot.locations.contains(target),
              target != snapshot.current else {
            return nil
        }
        return target
    }
}
