import Darwin
import Foundation

/// 原子替换落地：临时文件 + replaceItemAt，
/// 并在替换前把原件的 POSIX 权限与扩展属性复制到临时文件，
/// 避免 `.usingNewMetadataOnly` 把 0744 重置为 0644、丢 xattr。
enum AtomicFileReplacer {
    enum ReplaceError: Error, LocalizedError, CustomStringConvertible {
        case writeFailed(String)

        var errorDescription: String? { description }

        var description: String {
            switch self {
            case let .writeFailed(detail): return "写入失败：\(detail)"
            }
        }
    }

    /// 把 `data` 原子替换到 `original`，保留原件的权限与 xattr。
    /// - Parameters:
    ///   - tempExtension: 临时文件扩展名（区分调用方，便于排查遗留）。
    ///   - inheritAttributes: 为 false 时不复制原件属性（新增文件场景）。
    static func replace(
        original: URL,
        data: Data,
        tempExtension: String = "toolbox-replace",
        inheritAttributes: Bool = true
    ) throws {
        let directory = original.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(tempExtension)-\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporary, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporary) }
            if inheritAttributes {
                copyPOSIXPermissions(from: original, to: temporary)
                copyExtendedAttributes(from: original, to: temporary)
            }
            try Task.checkCancellation()
            do {
                _ = try FileManager.default.replaceItemAt(
                    original,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } catch {
                // replaceItemAt 对部分特殊路径会失败，退化为直接移动。
                try FileManager.default.moveItem(at: temporary, to: original)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if error is CancellationError { throw error }
            throw ReplaceError.writeFailed(error.localizedDescription)
        }
    }

    /// Publish a complete sibling without ever replacing an existing destination.
    /// RENAME_EXCL is atomic across threads/processes; unsupported filesystems fail closed.
    static func publishSibling(
        original: URL, data: Data, suffix: String, fileExtension: String
    ) throws -> URL {
        guard !suffix.contains("/"), !suffix.contains("\0") else {
            throw ReplaceError.writeFailed("文件后缀不能包含路径分隔符。")
        }
        let directory = original.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".toolbox-image-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ReplaceError.writeFailed(String(cString: strerror(errno))) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var published = false
        defer {
            try? handle.close()
            if !published { try? FileManager.default.removeItem(at: temporary) }
        }
        try handle.write(contentsOf: data)
        try handle.close()
        copyPOSIXPermissions(from: original, to: temporary)
        copyExtendedAttributes(from: original, to: temporary)
        let base = original.deletingPathExtension().lastPathComponent + suffix
        var counter = 1
        while true {
            try Task.checkCancellation()
            let name = counter == 1 ? base : "\(base)-\(counter)"
            let target = directory.appendingPathComponent("\(name).\(fileExtension)")
            if renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                published = true
                return target
            }
            let code = errno
            guard code == EEXIST else {
                throw ReplaceError.writeFailed(String(cString: strerror(code)))
            }
            counter += 1
        }
    }

    private static func copyPOSIXPermissions(from source: URL, to destination: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              let permissions = attributes[.posixPermissions] as? Int
        else { return }
        try? FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: destination.path
        )
    }

    /// 逐项复制 xattr。系统保护属性（如 com.apple.provenance）无法由用户态
    /// 写入，设置失败即忽略；ACL 以 xattr 形式尽力保留。
    private static func copyExtendedAttributes(from source: URL, to destination: URL) {
        let sourcePath = source.path
        let destinationPath = destination.path
        let nameBufferSize = listxattr(sourcePath, nil, 0, 0)
        guard nameBufferSize > 0 else { return }
        var namesBuffer = [CChar](repeating: 0, count: nameBufferSize)
        guard listxattr(sourcePath, &namesBuffer, nameBufferSize, 0) > 0 else { return }

        // 名字列表是连续的 NUL 结尾字符串，扫描切分。
        var names: [String] = []
        var start = 0
        while start < namesBuffer.count {
            var end = start
            while end < namesBuffer.count, namesBuffer[end] != 0 { end += 1 }
            if end > start {
                let nameBytes = namesBuffer[start ..< end].map { UInt8(bitPattern: $0) }
                names.append(String(decoding: nameBytes, as: UTF8.self))
            }
            start = end + 1
        }

        for name in names {
            let valueSize = getxattr(sourcePath, name, nil, 0, 0, 0)
            guard valueSize > 0 else { continue }
            var value = [UInt8](repeating: 0, count: valueSize)
            guard getxattr(sourcePath, name, &value, valueSize, 0, 0) == valueSize else { continue }
            _ = value.withUnsafeBufferPointer { pointer in
                setxattr(destinationPath, name, pointer.baseAddress, valueSize, 0, 0)
            }
        }
    }
}
