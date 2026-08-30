import Foundation

/// 输入路径展开：把 CLI/面板传入的文件与目录路径统一展开为待处理图像 URL 列表。
///
/// 目录按（可选递归的）浅/深优先序展开；仅保留可识别的图像扩展名，
/// 隐藏文件（`.` 开头）跳过。
enum ImageFileCollector {
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
        "webp", "avif", "gif",
    ]

    enum CollectError: LocalizedError {
        case notFound(String)
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case let .notFound(path): return "路径不存在：\(path)"
            case let .readFailed(path): return "无法读取目录：\(path)"
            }
        }
    }

    /// 展开路径列表；保持输入顺序，目录内按名称稳定排序；
    /// 同一文件（如目录 + 其内文件同时指定）按标准化路径去重，避免并发重复写入。
    static func collect(paths: [String], recursive: Bool) throws -> [URL] {
        var urls: [URL] = []
        urls.reserveCapacity(paths.count)
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded.isEmpty ? path : expanded)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw CollectError.notFound(path)
            }
            if isDirectory.boolValue {
                urls.append(contentsOf: try expandDirectory(url, recursive: recursive))
            } else {
                urls.append(url)
            }
        }
        var seen = Set<URL>()
        return urls.filter { seen.insert($0.standardizedFileURL).inserted }
    }

    private static func expandDirectory(_ directory: URL, recursive: Bool) throws -> [URL] {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw CollectError.readFailed(directory.path)
        }
        var urls: [URL] = []
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if recursive {
                    urls.append(contentsOf: try expandDirectory(child, recursive: true))
                }
            } else if values?.isRegularFile == true, isSupported(child) {
                urls.append(child)
            }
        }
        return urls
    }

    private static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
