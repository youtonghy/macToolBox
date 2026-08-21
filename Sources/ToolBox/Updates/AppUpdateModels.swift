import Foundation

enum AppUpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case beta

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable: return "正式版"
        case .beta: return "Beta"
        }
    }
}

struct AppUpdateAsset: Decodable, Equatable, Sendable {
    let name: String
    let byteCount: Int64
    let downloadURL: URL
    let digest: String?

    init(name: String, byteCount: Int64, downloadURL: URL, digest: String? = nil) {
        self.name = name
        self.byteCount = byteCount
        self.downloadURL = downloadURL
        self.digest = digest
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case byteCount = "size"
        case downloadURL = "browser_download_url"
        case digest
    }
}

struct AppRelease: Decodable, Equatable, Sendable {
    let tagName: String
    let title: String
    let isDraft: Bool
    let isPrerelease: Bool
    let publishedAt: Date
    let assets: [AppUpdateAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case title = "name"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case publishedAt = "published_at"
        case assets
    }

    var appArchive: AppUpdateAsset? {
        assets.first { Self.version(from: $0.name) != nil }
    }

    var version: String? {
        guard let name = appArchive?.name else { return nil }
        return Self.version(from: name)
    }

    private static func version(from archiveName: String) -> String? {
        guard archiveName.hasPrefix("ToolBox-"), archiveName.hasSuffix(".app.zip") else {
            return nil
        }
        let version = String(
            archiveName.dropFirst("ToolBox-".count).dropLast(".app.zip".count)
        )
        guard let first = version.first,
              first.isLetter || first.isNumber,
              version.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
        else { return nil }
        return version
    }
}

enum AppUpdatePolicy {
    static func isDevelopmentVersion(_ version: String) -> Bool {
        version.hasPrefix("DEV")
    }

    static func latestUpdate(
        in releases: [AppRelease],
        channel: AppUpdateChannel,
        currentVersion: String
    ) -> AppRelease? {
        let candidates = releases
            .filter { release in
                !release.isDraft
                    && release.appArchive != nil
                    && (channel == .beta || !release.isPrerelease)
            }
            .sorted { $0.publishedAt > $1.publishedAt }

        guard let latest = candidates.first, let latestVersion = latest.version else { return nil }
        guard normalized(latestVersion) != normalized(currentVersion) else { return nil }
        if isDevelopmentVersion(currentVersion) { return latest }

        if let currentRelease = candidates.first(where: {
            normalized($0.version ?? "") == normalized(currentVersion)
        }) {
            return latest.publishedAt > currentRelease.publishedAt ? latest : nil
        }

        if let comparison = compareRecognizedVersions(latestVersion, currentVersion) {
            return comparison == .orderedDescending ? latest : nil
        }

        if channel == .beta,
           isRecognizedVersion(latestVersion),
           isRecognizedVersion(currentVersion) {
            // Stable and Beta formats are not numerically comparable. The Beta
            // channel follows GitHub's publication order across both streams.
            return latest
        }

        // A custom version absent from the public release list cannot be ordered safely.
        return nil
    }

    private static func normalized(_ version: String) -> String {
        version.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func compareRecognizedVersions(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult? {
        if let lhs = stableComponents(lhs), let rhs = stableComponents(rhs) {
            let count = max(lhs.count, rhs.count)
            for index in 0..<count {
                let left = index < lhs.count ? lhs[index] : 0
                let right = index < rhs.count ? rhs[index] : 0
                if left != right { return left < right ? .orderedAscending : .orderedDescending }
            }
            return .orderedSame
        }
        if let lhs = betaStamp(lhs), let rhs = betaStamp(rhs) {
            if lhs == rhs { return .orderedSame }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        }
        return nil
    }

    private static func stableComponents(_ raw: String) -> [Int]? {
        let value = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        return numbers.count == parts.count ? numbers : nil
    }

    private static func isRecognizedVersion(_ raw: String) -> Bool {
        stableComponents(raw) != nil || betaStamp(raw) != nil
    }

    private static func betaStamp(_ raw: String) -> Int? {
        let normalized = raw.replacingOccurrences(of: "-", with: "")
        guard normalized.lowercased().hasPrefix("beta") else { return nil }
        let stamp = normalized.dropFirst(4)
        guard stamp.count == 6, stamp.allSatisfy(\.isNumber) else { return nil }
        return Int(stamp)
    }
}

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case downloading(version: String)
    case ready(version: String)
    case failed(message: String)
}
