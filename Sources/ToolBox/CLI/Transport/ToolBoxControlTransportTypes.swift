import Foundation
import ToolBoxControlProtocol

@MainActor
protocol ToolBoxControlRequestHandling: AnyObject {
    func handle(
        _ request: ToolBoxControlRequestEnvelope
    ) async throws -> ToolBoxControlResponseEnvelope
}

@MainActor
final class ToolBoxControlClosureRequestHandler: ToolBoxControlRequestHandling {
    typealias Handler = @MainActor (
        ToolBoxControlRequestEnvelope
    ) async throws -> ToolBoxControlResponseEnvelope

    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func handle(
        _ request: ToolBoxControlRequestEnvelope
    ) async throws -> ToolBoxControlResponseEnvelope {
        try await handler(request)
    }
}

enum ToolBoxControlTransportFailure: Sendable {
    case requestTooLarge(maximumBytes: Int)
    case invalidRequest
    case unsupportedProtocolVersion(actual: Int)
    case invalidHandlerResponse
    case handlerFailed(message: String)
    case responseEncodingFailed
    case serviceShuttingDown

    var error: ToolBoxControlErrorDTO {
        switch self {
        case let .requestTooLarge(maximumBytes):
            return ToolBoxControlErrorDTO(
                code: .invalidRequest,
                message: "请求数据超过允许的大小。",
                details: ["maximumBytes": String(maximumBytes)]
            )
        case .invalidRequest:
            return ToolBoxControlErrorDTO(
                code: .invalidRequest,
                message: "无法解析 CLI 请求。"
            )
        case let .unsupportedProtocolVersion(actual):
            return ToolBoxControlErrorDTO(
                code: .unsupportedProtocolVersion,
                message: "CLI 协议版本与应用不兼容。",
                details: [
                    "actual": String(actual),
                    "expected": String(ToolBoxControlProtocolVersion.current),
                ]
            )
        case .invalidHandlerResponse:
            return ToolBoxControlErrorDTO(
                code: .internalError,
                message: "应用生成了无效的 CLI 响应。"
            )
        case let .handlerFailed(message):
            return ToolBoxControlErrorDTO(
                code: .operationFailed,
                message: message
            )
        case .responseEncodingFailed:
            return ToolBoxControlErrorDTO(
                code: .internalError,
                message: "无法编码 CLI 响应。"
            )
        case .serviceShuttingDown:
            return ToolBoxControlErrorDTO(
                code: .unavailable,
                message: "ToolBox 正在退出，无法完成请求。",
                isRecoverable: true
            )
        }
    }
}

enum ToolBoxControlTransportError: LocalizedError {
    case alreadyRunning
    case endpointDirectoryUnavailable(String)
    case insecureEndpointDirectory(String)
    case endpointLockUnavailable(String)
    case endpointWriteFailed(String)
    case expectedHelperMissing(String)
    case invalidExpectedHelper(String)
    case codeRequirementUnavailable(String)
    case fallbackResponseEncodingFailed
    case endpointEncodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "ToolBox CLI control service is already running."
        case let .endpointDirectoryUnavailable(path):
            return "Unable to create the private CLI endpoint directory at \(path)."
        case let .insecureEndpointDirectory(path):
            return "The CLI endpoint directory is not a private directory owned by this user: \(path)."
        case let .endpointLockUnavailable(path):
            return "Another ToolBox CLI control service owns the endpoint lock at \(path)."
        case let .endpointWriteFailed(path):
            return "Unable to securely publish the CLI endpoint at \(path)."
        case let .expectedHelperMissing(path):
            return "The embedded ToolBox CLI helper is missing at \(path)."
        case let .invalidExpectedHelper(path):
            return "The embedded ToolBox CLI helper has an invalid code signature at \(path)."
        case let .codeRequirementUnavailable(path):
            return "Unable to derive the embedded ToolBox CLI code requirement at \(path)."
        case .fallbackResponseEncodingFailed:
            return "Unable to encode the fallback CLI transport response."
        case let .endpointEncodingFailed(message):
            return "Unable to encode the CLI listener endpoint: \(message)"
        }
    }
}

struct ToolBoxControlTransportConfiguration {
    let endpointFileURL: URL
    let socketFileURL: URL
    let expectedHelperURL: URL
    let appVersion: String
    let maximumRequestBytes: Int

    init(
        endpointFileURL: URL = ToolBoxEndpointLocation.defaultMetadataURL(),
        socketFileURL: URL? = nil,
        expectedHelperURL: URL? = nil,
        appVersion: String? = nil,
        maximumRequestBytes: Int = ToolBoxControlJSONCodec.maximumPayloadSize
    ) {
        precondition(maximumRequestBytes > 0)
        precondition(maximumRequestBytes <= ToolBoxControlJSONCodec.maximumPayloadSize)

        self.endpointFileURL = endpointFileURL
        self.socketFileURL = socketFileURL ?? ToolBoxEndpointLocation.defaultSocketURL()
        self.expectedHelperURL = expectedHelperURL ?? Self.defaultExpectedHelperURL()
        self.appVersion = appVersion ?? Self.defaultAppVersion()
        self.maximumRequestBytes = maximumRequestBytes
    }

    static func defaultExpectedHelperURL(bundle: Bundle = .main) -> URL {
        bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("toolbox", isDirectory: false)
    }

    static func defaultAppVersion(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
