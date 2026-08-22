import Darwin
import Foundation
import OSLog
import ToolBoxControlProtocol

@MainActor
final class ToolBoxControlTransport {
    private let configuration: ToolBoxControlTransportConfiguration
    private let handler: ToolBoxControlRequestHandling
    private var endpointStore: ToolBoxControlEndpointStore?
    private var serverDescriptor: Int32 = -1
    private var acceptWorker: DispatchWorkItem?
    private var acceptCancellation: ToolBoxControlAcceptCancellation?
    private let sessionStore = ToolBoxControlSessionStore()
    private let logger = Logger(subsystem: "ToolBox", category: "CLIControl")

    init(
        configuration: ToolBoxControlTransportConfiguration = ToolBoxControlTransportConfiguration(),
        handler: ToolBoxControlRequestHandling
    ) {
        self.configuration = configuration
        self.handler = handler
    }

    convenience init(
        configuration: ToolBoxControlTransportConfiguration = ToolBoxControlTransportConfiguration(),
        handler: @escaping ToolBoxControlClosureRequestHandler.Handler
    ) {
        self.init(
            configuration: configuration,
            handler: ToolBoxControlClosureRequestHandler(handler: handler)
        )
    }

    func start() throws {
        guard serverDescriptor == -1 else { throw ToolBoxControlTransportError.alreadyRunning }

        let verifier = try ToolBoxControlClientIdentityVerifier(
            expectedHelperURL: configuration.expectedHelperURL
        )
        let endpointStore = ToolBoxControlEndpointStore(
            endpointFileURL: configuration.endpointFileURL
        )
        try endpointStore.acquireLock()

        let socketURL = configuration.socketFileURL
        var socketMetadata = stat()
        if lstat(socketURL.path, &socketMetadata) == 0 {
            guard socketMetadata.st_uid == geteuid(),
                  socketMetadata.st_mode & S_IFMT == S_IFSOCK,
                  unlink(socketURL.path) == 0
            else {
                endpointStore.releaseLock()
                throw ToolBoxControlTransportError.endpointWriteFailed(socketURL.path)
            }
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            endpointStore.releaseLock()
            throw ToolBoxControlTransportError.endpointWriteFailed(socketURL.path)
        }

        var worker: DispatchWorkItem?
        var cancellation: ToolBoxControlAcceptCancellation?
        do {
            try Self.bindAndListen(descriptor: descriptor, socketURL: socketURL)
            let sessionStore = self.sessionStore
            let maximumRequestBytes = configuration.maximumRequestBytes
            let requestHandler = handler
            let acceptCancellation = ToolBoxControlAcceptCancellation()
            cancellation = acceptCancellation
            let acceptWorker = DispatchWorkItem {
                Self.acceptConnections(
                    descriptor: descriptor,
                    identityVerifier: verifier,
                    maximumRequestBytes: maximumRequestBytes,
                    handler: requestHandler,
                    sessionStore: sessionStore,
                    cancellation: acceptCancellation
                )
            }
            worker = acceptWorker
            DispatchQueue.global(qos: .userInitiated).async(execute: acceptWorker)

            let metadata = ToolBoxEndpointMetadata(
                appVersion: configuration.appVersion,
                appProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
                socketPath: socketURL.standardizedFileURL.path
            )
            try endpointStore.publish(ToolBoxEndpointMetadataCodec.encode(metadata))

            self.endpointStore = endpointStore
            self.serverDescriptor = descriptor
            self.acceptWorker = worker
            self.acceptCancellation = cancellation
        } catch {
            cancellation?.cancel()
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
            worker?.cancel()
            unlink(socketURL.path)
            endpointStore.removePublishedEndpoint()
            endpointStore.releaseLock()
            throw error
        }
    }

    func stop() {
        acceptCancellation?.cancel()
        acceptCancellation = nil
        acceptWorker?.cancel()
        acceptWorker = nil
        sessionStore.stopAll()
        endpointStore?.removePublishedEndpoint()
        endpointStore?.releaseLock()
        endpointStore = nil
        if serverDescriptor >= 0 {
            shutdown(serverDescriptor, SHUT_RDWR)
            close(serverDescriptor)
            unlink(configuration.socketFileURL.path)
            serverDescriptor = -1
        }
    }

    private nonisolated static func acceptConnections(
        descriptor serverDescriptor: Int32,
        identityVerifier: ToolBoxControlClientIdentityVerifier,
        maximumRequestBytes: Int,
        handler: ToolBoxControlRequestHandling,
        sessionStore: ToolBoxControlSessionStore,
        cancellation: ToolBoxControlAcceptCancellation
    ) {
        let logger = Logger(subsystem: "ToolBox", category: "CLIControl")
        while !cancellation.isCancelled {
            let descriptor = accept(serverDescriptor, nil, nil)
            if descriptor < 0 {
                if errno == EINTR {
                    continue
                }
                if cancellation.isCancelled {
                    return
                }
                return
            }

            let acceptedFlags = fcntl(descriptor, F_GETFL)
            guard acceptedFlags >= 0,
                  fcntl(descriptor, F_SETFL, acceptedFlags & ~O_NONBLOCK) == 0
            else {
                close(descriptor)
                logger.error("Rejected CLI connection: unable to make accepted socket blocking")
                continue
            }

            var peerPID: Int32 = 0
            var peerPIDLength = socklen_t(MemoryLayout<Int32>.size)
            let pidResult = getsockopt(
                descriptor,
                SOL_LOCAL,
                LOCAL_PEEREPID,
                &peerPID,
                &peerPIDLength
            )
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            let credentialResult = getpeereid(descriptor, &peerUID, &peerGID)
            guard pidResult == 0, credentialResult == 0 else {
                logger.error("Rejected CLI connection: pidResult=\(pidResult), credentialResult=\(credentialResult), errno=\(errno)")
                close(descriptor)
                continue
            }
            guard identityVerifier.accepts(
                processIdentifier: peerPID,
                effectiveUserIdentifier: peerUID
            ) else {
                logger.error("Rejected CLI identity: pid=\(peerPID), uid=\(peerUID)")
                close(descriptor)
                continue
            }
            logger.debug("Accepted CLI identity: pid=\(peerPID), uid=\(peerUID)")

            let sessionID = UUID()
            let session = ToolBoxControlXPCSession(
                descriptor: descriptor,
                maximumRequestBytes: maximumRequestBytes,
                handler: handler,
                makeFailureData: Self.makeFailureData,
                onFinished: {
                    sessionStore.remove(sessionID)
                }
            )
            sessionStore.insert(sessionID, session)
            session.start()
        }
    }

    private static func bindAndListen(descriptor: Int32, socketURL: URL) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathData = Data(socketURL.path.utf8)
        guard pathData.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ToolBoxControlTransportError.endpointWriteFailed(socketURL.path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathData)
            buffer[pathData.count] = 0
        }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, addressLength)
            }
        }
        guard bindResult == 0,
              chmod(socketURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0,
              listen(descriptor, 8) == 0
        else {
            throw ToolBoxControlTransportError.endpointWriteFailed(
                "\(socketURL.path): \(String(cString: strerror(errno)))"
            )
        }
    }

    private nonisolated static func makeFailureData(
        _ failure: ToolBoxControlTransportFailure,
        _ requestID: String
    ) -> Data {
        (try? ToolBoxControlJSONCodec.encodeResponse(.failure(
            requestID: requestID,
            error: failure.error
        ))) ?? Data()
    }
}

private final class ToolBoxControlAcceptCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class ToolBoxControlSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [UUID: ToolBoxControlXPCSession] = [:]

    func insert(_ identifier: UUID, _ session: ToolBoxControlXPCSession) {
        lock.lock()
        sessions[identifier] = session
        lock.unlock()
    }

    func remove(_ identifier: UUID) {
        lock.lock()
        sessions.removeValue(forKey: identifier)
        lock.unlock()
    }

    func stopAll() {
        lock.lock()
        let activeSessions = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        activeSessions.forEach { $0.stop() }
    }
}
