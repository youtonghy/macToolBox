import Darwin
import Foundation

/// The on-disk file a process was launched from. Replacing the app bundle leaves
/// a running helper on the old image, which peers can no longer resolve for
/// code-signing checks (errSecCSNoSuchCode), so it must exit and let launchd
/// start the updated binary.
struct ExecutableFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modified: timespec

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modified = info.st_mtimespec
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
            && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
    }
}
