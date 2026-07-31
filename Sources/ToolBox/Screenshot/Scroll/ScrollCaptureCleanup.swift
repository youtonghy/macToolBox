import Foundation

enum ScrollCaptureCleanup {
    static func removeStaleSessions(
        rootDirectory: URL = ScrollCaptureStripStore.defaultRootDirectory(),
        now: Date = Date(),
        maximumAge: TimeInterval = 24 * 60 * 60
    ) throws {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        let children = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix("session-"),
                  UUID(uuidString: String(name.dropFirst("session-".count))) != nil
            else {
                continue
            }
            let values = try child.resourceValues(forKeys: keys)
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > maximumAge
            else {
                continue
            }
            try FileManager.default.removeItem(at: child)
        }
    }
}
