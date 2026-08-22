import Foundation

enum ToolBoxCLIInstallError: Error, Equatable {
    case executableUnavailable
    case unsafeInstallDirectory(String)
    case collision(String)
    case notInstalled
    case foreignLink(String)
    case fileOperationFailed(String)
}

extension ToolBoxCLIInstallError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return "无法确定当前 toolbox 可执行文件路径"
        case let .unsafeInstallDirectory(path):
            return "安装目录包含符号链接或不是目录：\(path)"
        case let .collision(path):
            return "目标已存在且不是当前 ToolBox CLI：\(path)"
        case .notInstalled:
            return "toolbox 尚未安装到 ~/.local/bin"
        case let .foreignLink(path):
            return "拒绝删除不属于当前 ToolBox CLI 的链接：\(path)"
        case let .fileOperationFailed(message):
            return "文件操作失败：\(message)"
        }
    }
}

enum ToolBoxCLIInstallState: String, Codable, Equatable {
    case installed
    case alreadyInstalled = "already-installed"
    case uninstalled
}

struct ToolBoxCLIInstallOutputDTO: Codable, Equatable {
    let action: String
    let path: String
    let state: ToolBoxCLIInstallState
}

struct ToolBoxCLIInstallManager {
    let fileManager: FileManager
    let homeDirectory: URL
    let executableURL: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        executableURL: URL? = nil
    ) throws {
        self.fileManager = fileManager
        self.homeDirectory = (homeDirectory ?? fileManager.homeDirectoryForCurrentUser).standardizedFileURL
        guard let executableURL = executableURL ?? Bundle.main.executableURL else {
            throw ToolBoxCLIInstallError.executableUnavailable
        }
        self.executableURL = executableURL.resolvingSymlinksInPath().standardizedFileURL
    }

    var installURL: URL {
        homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("toolbox", isDirectory: false)
    }

    func install() throws -> ToolBoxCLIInstallOutputDTO {
        let directory = installURL.deletingLastPathComponent()
        try ensureInstallDirectory(directory)

        if fileManager.fileExists(atPath: installURL.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: installURL.path)) != nil {
            guard try isOwnedLink(at: installURL) else {
                throw ToolBoxCLIInstallError.collision(installURL.path)
            }
            return ToolBoxCLIInstallOutputDTO(
                action: "install",
                path: installURL.path,
                state: .alreadyInstalled
            )
        }

        do {
            try fileManager.createSymbolicLink(
                at: installURL,
                withDestinationURL: executableURL
            )
        } catch {
            throw ToolBoxCLIInstallError.fileOperationFailed(error.localizedDescription)
        }
        return ToolBoxCLIInstallOutputDTO(
            action: "install",
            path: installURL.path,
            state: .installed
        )
    }

    func uninstall() throws -> ToolBoxCLIInstallOutputDTO {
        guard fileManager.fileExists(atPath: installURL.path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: installURL.path)) != nil else {
            throw ToolBoxCLIInstallError.notInstalled
        }
        guard try isOwnedLink(at: installURL) else {
            throw ToolBoxCLIInstallError.foreignLink(installURL.path)
        }
        do {
            try fileManager.removeItem(at: installURL)
        } catch {
            throw ToolBoxCLIInstallError.fileOperationFailed(error.localizedDescription)
        }
        return ToolBoxCLIInstallOutputDTO(
            action: "uninstall",
            path: installURL.path,
            state: .uninstalled
        )
    }

    private func ensureInstallDirectory(_ directory: URL) throws {
        let localDirectory = directory.deletingLastPathComponent()
        try ensureDirectory(localDirectory)
        try ensureDirectory(directory)
    }

    private func ensureDirectory(_ directory: URL) throws {
        if fileManager.fileExists(atPath: directory.path) {
            do {
                let values = try directory.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw ToolBoxCLIInstallError.unsafeInstallDirectory(directory.path)
                }
                return
            } catch let error as ToolBoxCLIInstallError {
                throw error
            } catch {
                throw ToolBoxCLIInstallError.fileOperationFailed(error.localizedDescription)
            }
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o755]
            )
        } catch {
            throw ToolBoxCLIInstallError.fileOperationFailed(error.localizedDescription)
        }
    }

    private func isOwnedLink(at url: URL) throws -> Bool {
        let destination: String
        do {
            destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
        } catch {
            return false
        }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = url.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return destinationURL.resolvingSymlinksInPath().standardizedFileURL == executableURL
    }
}
