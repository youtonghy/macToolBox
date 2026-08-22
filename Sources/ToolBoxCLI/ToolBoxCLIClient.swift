import AppKit
import Darwin
import Foundation
import ToolBoxControlProtocol

enum ToolBoxCLIClientError: Error, Equatable {
    case endpointNotFound
    case endpointNotRegularFile
    case endpointPermissions(Int)
    case endpointOwnerMismatch
    case endpointUnreadable(String)
    case endpointInvalid(String)
    case staleEndpoint(Int32)
    case applicationNotFound
    case applicationLaunchFailed(String)
    case applicationLaunchTimedOut
    case connectionFailed(String)
    case requestTimedOut
    case malformedResponse(String)
    case protocolVersionMismatch(expected: Int, actual: Int)
    case requestIDMismatch(expected: String, actual: String)
    case missingResponsePayload
}

extension ToolBoxCLIClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .endpointNotFound:
            return "ToolBox 控制端尚未就绪"
        case .endpointNotRegularFile:
            return "ToolBox endpoint 元数据不是普通文件"
        case let .endpointPermissions(mode):
            return "ToolBox endpoint 元数据权限不安全（\(String(mode, radix: 8))）"
        case .endpointOwnerMismatch:
            return "ToolBox endpoint 元数据不属于当前用户"
        case let .endpointUnreadable(message):
            return "无法读取 ToolBox endpoint 元数据：\(message)"
        case let .endpointInvalid(message):
            return "ToolBox endpoint 元数据无效：\(message)"
        case let .staleEndpoint(processIdentifier):
            return "ToolBox endpoint 已失效（PID \(processIdentifier)）"
        case .applicationNotFound:
            return "找不到 ToolBox.app"
        case let .applicationLaunchFailed(message):
            return "无法启动 ToolBox.app：\(message)"
        case .applicationLaunchTimedOut:
            return "启动 ToolBox.app 超时"
        case let .connectionFailed(message):
            return "无法连接 ToolBox 控制端：\(message)"
        case .requestTimedOut:
            return "等待 ToolBox 响应超时"
        case let .malformedResponse(message):
            return "ToolBox 返回了无效响应：\(message)"
        case let .protocolVersionMismatch(expected, actual):
            return "ToolBox 协议版本不兼容（CLI=\(expected)，App=\(actual)）"
        case let .requestIDMismatch(expected, actual):
            return "ToolBox 响应 ID 不匹配（请求=\(expected)，响应=\(actual)）"
        case .missingResponsePayload:
            return "ToolBox 响应缺少结果或错误"
        }
    }
}

struct ToolBoxLoadedEndpoint {
    let metadata: ToolBoxEndpointMetadata
    let socketURL: URL
}

protocol ToolBoxEndpointLoading {
    func load() throws -> ToolBoxLoadedEndpoint
}

struct ToolBoxEndpointLoader: ToolBoxEndpointLoading {
    let metadataURL: URL
    let fileManager: FileManager

    init(
        metadataURL: URL = ToolBoxEndpointLocation.defaultMetadataURL(),
        fileManager: FileManager = .default
    ) {
        self.metadataURL = metadataURL
        self.fileManager = fileManager
    }

    func load() throws -> ToolBoxLoadedEndpoint {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw ToolBoxCLIClientError.endpointNotFound
        }

        do {
            let values = try metadataURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ToolBoxCLIClientError.endpointNotRegularFile
            }
            let attributes = try fileManager.attributesOfItem(atPath: metadataURL.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard permissions & 0o077 == 0 else {
                throw ToolBoxCLIClientError.endpointPermissions(permissions)
            }
            let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            guard ownerID == getuid() else {
                throw ToolBoxCLIClientError.endpointOwnerMismatch
            }
        } catch let error as ToolBoxCLIClientError {
            throw error
        } catch {
            throw ToolBoxCLIClientError.endpointUnreadable(error.localizedDescription)
        }

        let data: Data
        do {
            data = try Data(contentsOf: metadataURL, options: [.mappedIfSafe])
        } catch {
            throw ToolBoxCLIClientError.endpointUnreadable(error.localizedDescription)
        }

        do {
            let metadata = try ToolBoxEndpointMetadataCodec.decode(data)
            guard Self.isProcessAlive(metadata.appProcessIdentifier) else {
                throw ToolBoxCLIClientError.staleEndpoint(metadata.appProcessIdentifier)
            }
            let socketURL = URL(fileURLWithPath: metadata.socketPath)
            guard socketURL.standardizedFileURL == ToolBoxEndpointLocation.defaultSocketURL().standardizedFileURL else {
                throw ToolBoxCLIClientError.endpointInvalid("控制端 socket 路径不是 ToolBox 默认路径")
            }
            var socketMetadata = stat()
            guard lstat(socketURL.path, &socketMetadata) == 0,
                  socketMetadata.st_uid == getuid(),
                  socketMetadata.st_mode & S_IFMT == S_IFSOCK,
                  socketMetadata.st_mode & mode_t(0o077) == 0
            else {
                throw ToolBoxCLIClientError.endpointInvalid("控制端 socket 不存在或权限不安全")
            }
            return ToolBoxLoadedEndpoint(
                metadata: metadata,
                socketURL: socketURL
            )
        } catch let error as ToolBoxCLIClientError {
            throw error
        } catch {
            throw ToolBoxCLIClientError.endpointInvalid(String(describing: error))
        }
    }

    private static func isProcessAlive(_ processIdentifier: Int32) -> Bool {
        if kill(processIdentifier, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}

protocol ToolBoxApplicationLaunching {
    func launch(timeout: TimeInterval) throws
}

struct ToolBoxApplicationLauncher: ToolBoxApplicationLaunching {
    let workspace: NSWorkspace
    let bundle: Bundle

    init(workspace: NSWorkspace = .shared, bundle: Bundle = .main) {
        self.workspace = workspace
        self.bundle = bundle
    }

    func launch(timeout: TimeInterval) throws {
        guard let applicationURL = applicationURL() else {
            throw ToolBoxCLIClientError.applicationNotFound
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var launchError: Error?
        workspace.openApplication(at: applicationURL, configuration: configuration) { _, error in
            lock.lock()
            launchError = error
            lock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw ToolBoxCLIClientError.applicationLaunchTimedOut
        }
        lock.lock()
        let capturedError = launchError
        lock.unlock()
        if let capturedError {
            throw ToolBoxCLIClientError.applicationLaunchFailed(capturedError.localizedDescription)
        }
    }

    private func applicationURL() -> URL? {
        if let executableURL = bundle.executableURL {
            let helpersURL = executableURL.deletingLastPathComponent()
            let contentsURL = helpersURL.deletingLastPathComponent()
            let applicationURL = contentsURL.deletingLastPathComponent()
            if helpersURL.lastPathComponent == "Helpers",
               contentsURL.lastPathComponent == "Contents",
               Bundle(url: applicationURL)?.bundleIdentifier == ToolBoxEndpointMetadata.appBundleIdentifier {
                return applicationURL
            }
        }
        return workspace.urlForApplication(
            withBundleIdentifier: ToolBoxEndpointMetadata.appBundleIdentifier
        )
    }
}

protocol ToolBoxControlRequestSending {
    func send(
        requestData: Data,
        socketURL: URL,
        timeout: TimeInterval
    ) throws -> Data
}

struct ToolBoxControlRequestSender: ToolBoxControlRequestSending {
    func send(
        requestData: Data,
        socketURL: URL,
        timeout: TimeInterval
    ) throws -> Data {
        guard timeout.isFinite, timeout > 0 else {
            throw ToolBoxCLIClientError.requestTimedOut
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ToolBoxCLIClientError.connectionFailed(String(cString: strerror(errno)))
        }
        defer { close(descriptor) }
        try Self.setTimeout(timeout, on: descriptor)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathData = Data(socketURL.path.utf8)
        guard pathData.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ToolBoxCLIClientError.connectionFailed("控制端 socket 路径过长")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathData)
            buffer[pathData.count] = 0
        }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        guard connected == 0 else {
            throw ToolBoxCLIClientError.connectionFailed(String(cString: strerror(errno)))
        }

        try Self.writeFrame(requestData, to: descriptor)
        return try Self.readFrame(from: descriptor)
    }

    private static func setTimeout(_ timeout: TimeInterval, on descriptor: Int32) throws {
        var value = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &value,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0,
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &value,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0
        else {
            throw ToolBoxCLIClientError.connectionFailed(String(cString: strerror(errno)))
        }
    }

    private static func writeFrame(_ data: Data, to descriptor: Int32) throws {
        guard data.count <= ToolBoxControlJSONCodec.maximumPayloadSize else {
            throw ToolBoxCLIClientError.malformedResponse("请求数据过大")
        }
        var length = UInt32(data.count).bigEndian
        try writeBytes(Data(bytes: &length, count: MemoryLayout<UInt32>.size), to: descriptor)
        try writeBytes(data, to: descriptor)
    }

    private static func readFrame(from descriptor: Int32) throws -> Data {
        let lengthData = try readBytes(count: MemoryLayout<UInt32>.size, from: descriptor)
        let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= UInt32(ToolBoxControlJSONCodec.maximumPayloadSize) else {
            throw ToolBoxCLIClientError.malformedResponse("响应数据过大")
        }
        return try readBytes(count: Int(length), from: descriptor)
    }

    private static func writeBytes(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw ToolBoxCLIClientError.connectionFailed(String(cString: strerror(errno)))
                }
                offset += written
            }
        }
    }

    private static func readBytes(count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let readCount = Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    count - offset
                )
                if readCount < 0, errno == EINTR { continue }
                guard readCount > 0 else {
                    throw ToolBoxCLIClientError.connectionFailed("控制端提前关闭连接")
                }
                offset += readCount
            }
        }
        return data
    }
}

struct ToolBoxControlClientOptions: Equatable {
    let shouldLaunchApplication: Bool
    let timeout: TimeInterval
}

struct ToolBoxControlClient {
    let endpointLoader: ToolBoxEndpointLoading
    let applicationLauncher: ToolBoxApplicationLaunching
    let requestSender: ToolBoxControlRequestSending

    init(
        endpointLoader: ToolBoxEndpointLoading = ToolBoxEndpointLoader(),
        applicationLauncher: ToolBoxApplicationLaunching = ToolBoxApplicationLauncher(),
        requestSender: ToolBoxControlRequestSending = ToolBoxControlRequestSender()
    ) {
        self.endpointLoader = endpointLoader
        self.applicationLauncher = applicationLauncher
        self.requestSender = requestSender
    }

    func execute(
        _ request: ToolBoxControlRequestEnvelope,
        options: ToolBoxControlClientOptions
    ) throws -> ToolBoxControlResponseEnvelope {
        let deadline = Date().addingTimeInterval(options.timeout)
        var didLaunchApplication = false
        var lastEndpointError: ToolBoxCLIClientError = .endpointNotFound

        while true {
            do {
                let loadedEndpoint = try endpointLoader.load()
                guard loadedEndpoint.metadata.protocolVersion == ToolBoxControlProtocolVersion.current else {
                    throw ToolBoxCLIClientError.protocolVersionMismatch(
                        expected: ToolBoxControlProtocolVersion.current,
                        actual: loadedEndpoint.metadata.protocolVersion
                    )
                }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    throw ToolBoxCLIClientError.requestTimedOut
                }
                let requestData = try ToolBoxControlJSONCodec.encodeRequest(request)
                let responseData = try requestSender.send(
                    requestData: requestData,
                    socketURL: loadedEndpoint.socketURL,
                    timeout: remaining
                )
                return try decodeResponse(responseData, matching: request)
            } catch let error as ToolBoxCLIClientError {
                switch error {
                case .endpointNotFound,
                     .endpointNotRegularFile,
                     .endpointPermissions,
                     .endpointOwnerMismatch,
                     .endpointUnreadable,
                     .endpointInvalid,
                     .staleEndpoint:
                    lastEndpointError = error
                default:
                    throw error
                }
            } catch {
                throw ToolBoxCLIClientError.malformedResponse(error.localizedDescription)
            }

            guard options.shouldLaunchApplication else {
                throw lastEndpointError
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw ToolBoxCLIClientError.requestTimedOut
            }
            if !didLaunchApplication {
                try applicationLauncher.launch(timeout: min(remaining, 5))
                didLaunchApplication = true
            }
            Thread.sleep(forTimeInterval: min(0.1, max(deadline.timeIntervalSinceNow, 0)))
        }
    }

    private func decodeResponse(
        _ data: Data,
        matching request: ToolBoxControlRequestEnvelope
    ) throws -> ToolBoxControlResponseEnvelope {
        let response: ToolBoxControlResponseEnvelope
        do {
            response = try ToolBoxControlJSONCodec.decodeResponse(data)
        } catch {
            throw ToolBoxCLIClientError.malformedResponse(String(describing: error))
        }
        guard response.protocolVersion == ToolBoxControlProtocolVersion.current else {
            throw ToolBoxCLIClientError.protocolVersionMismatch(
                expected: ToolBoxControlProtocolVersion.current,
                actual: response.protocolVersion
            )
        }
        guard response.requestID == request.requestID else {
            throw ToolBoxCLIClientError.requestIDMismatch(
                expected: request.requestID,
                actual: response.requestID
            )
        }
        guard (response.result == nil) != (response.error == nil) else {
            throw ToolBoxCLIClientError.missingResponsePayload
        }
        return response
    }
}
