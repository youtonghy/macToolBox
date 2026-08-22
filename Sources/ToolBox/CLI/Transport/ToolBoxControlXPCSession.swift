import Darwin
import Foundation
import OSLog
import ToolBoxControlProtocol

final class ToolBoxControlXPCSession: @unchecked Sendable {
    typealias FailureDataFactory = (ToolBoxControlTransportFailure, String) -> Data

    private enum FrameError: Error {
        case tooLarge
        case closed
        case io
    }

    private let lock = NSLock()
    private var descriptor: Int32
    private var isStopped = false
    private let maximumRequestBytes: Int
    private let handler: ToolBoxControlRequestHandling
    private let makeFailureData: FailureDataFactory
    private let onFinished: () -> Void
    private let logger = Logger(subsystem: "ToolBox", category: "CLIControl")

    init(
        descriptor: Int32,
        maximumRequestBytes: Int,
        handler: ToolBoxControlRequestHandling,
        makeFailureData: @escaping FailureDataFactory,
        onFinished: @escaping () -> Void
    ) {
        self.descriptor = descriptor
        self.maximumRequestBytes = maximumRequestBytes
        self.handler = handler
        self.makeFailureData = makeFailureData
        self.onFinished = onFinished
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.receiveRequest()
        }
    }

    func stop() {
        let descriptor: Int32?
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        descriptor = self.descriptor
        self.descriptor = -1
        lock.unlock()

        if let descriptor {
            close(descriptor)
        }
    }

    private func receiveRequest() {
        do {
            let requestData = try Self.readFrame(
                from: currentDescriptor(),
                maximumBytes: maximumRequestBytes
            )
            let request: ToolBoxControlRequestEnvelope
            do {
                request = try ToolBoxControlJSONCodec.decodeRequest(requestData)
            } catch {
                logger.error("Rejected malformed CLI request: \(String(describing: error), privacy: .public)")
                finish(makeFailureData(.invalidRequest, Self.requestID(from: requestData)))
                return
            }
            guard request.protocolVersion == ToolBoxControlProtocolVersion.current else {
                finish(makeFailureData(
                    .unsupportedProtocolVersion(actual: request.protocolVersion),
                    request.requestID
                ))
                return
            }

            let handler = self.handler
            Task { @MainActor [weak self, handler] in
                guard let self else { return }
                let responseData: Data
                do {
                    let response = try await handler.handle(request)
                    guard Self.isValid(response: response, for: request) else {
                        finish(makeFailureData(.invalidHandlerResponse, request.requestID))
                        return
                    }
                    responseData = (try? ToolBoxControlJSONCodec.encodeResponse(response))
                        ?? makeFailureData(.responseEncodingFailed, request.requestID)
                } catch is CancellationError {
                    responseData = makeFailureData(.serviceShuttingDown, request.requestID)
                } catch {
                    responseData = makeFailureData(
                        .handlerFailed(message: Self.message(for: error)),
                        request.requestID
                    )
                }
                finish(responseData)
            }
        } catch FrameError.tooLarge {
            logger.error("Rejected oversized CLI request")
            finish(makeFailureData(
                .requestTooLarge(maximumBytes: maximumRequestBytes),
                "unknown"
            ))
        } catch {
            logger.error("CLI session read failed: \(String(describing: error), privacy: .public)")
            finish(makeFailureData(.invalidRequest, "unknown"))
        }
    }

    private func currentDescriptor() throws -> Int32 {
        lock.lock()
        let descriptor = self.descriptor
        let stopped = isStopped
        lock.unlock()
        guard !stopped, descriptor >= 0 else {
            throw FrameError.closed
        }
        return descriptor
    }

    private func finish(_ responseData: Data) {
        let descriptor: Int32?
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        descriptor = self.descriptor
        self.descriptor = -1
        lock.unlock()

        guard let descriptor else {
            onFinished()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [onFinished] in
            try? Self.writeFrame(responseData, to: descriptor)
            close(descriptor)
            onFinished()
        }
    }

    private static func readFrame(from descriptor: Int32, maximumBytes: Int) throws -> Data {
        let lengthData = try readBytes(count: MemoryLayout<UInt32>.size, from: descriptor)
        let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= UInt32(maximumBytes) else {
            throw FrameError.tooLarge
        }
        return try readBytes(count: Int(length), from: descriptor)
    }

    private static func writeFrame(_ data: Data, to descriptor: Int32) throws {
        guard data.count <= ToolBoxControlJSONCodec.maximumPayloadSize else {
            throw FrameError.tooLarge
        }
        var length = UInt32(data.count).bigEndian
        try writeBytes(Data(bytes: &length, count: MemoryLayout<UInt32>.size), to: descriptor)
        try writeBytes(data, to: descriptor)
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
                    throw FrameError.closed
                }
                offset += readCount
            }
        }
        return data
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
                    throw FrameError.io
                }
                offset += written
            }
        }
    }

    private static func isValid(
        response: ToolBoxControlResponseEnvelope,
        for request: ToolBoxControlRequestEnvelope
    ) -> Bool {
        response.protocolVersion == ToolBoxControlProtocolVersion.current
            && response.requestID == request.requestID
            && ((response.result == nil) != (response.error == nil))
    }

    private static func requestID(from data: Data) -> String {
        guard data.count <= ToolBoxControlJSONCodec.maximumPayloadSize,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestID = object["requestID"] as? String,
              !requestID.isEmpty,
              requestID.utf8.count <= 128
        else { return "unknown" }
        return requestID
    }

    private static func message(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return String(description.prefix(2_048))
        }
        return String(String(describing: error).prefix(2_048))
    }
}
