import Foundation
import ServiceManagement

protocol AuthorizedPowerSampling: AnyObject {
    func response() -> PowerSamplingResponse
    func suspend()
    /// Drops the session and stays disconnected long enough for the helper to
    /// exit, so the next connection reaches a new helper process.
    func restart()
    func stop()
}

final class AuthorizedPowerClient: AuthorizedPowerSampling {
    private let queue = DispatchQueue(label: "com.youtonghy.toolbox.power-client")
    private let serviceStatus: () -> SMAppService.Status
    private let restartHoldOff: TimeInterval
    private let makeConnection: () -> NSXPCConnection?
    private var connection: NSXPCConnection?
    private var cached = PowerSamplingResponse()
    private var pending = false
    private var requestedAt = Date.distantPast
    private var reconnectAfter = Date.distantPast
    private var closed = false

    init(
        serviceStatus: @escaping () -> SMAppService.Status = {
            SMAppService.daemon(plistName: PowerSamplingService.plistName).status
        },
        restartHoldOff: TimeInterval = PowerSamplingService.helperIdleExitDelay + 2,
        makeConnection: @escaping () -> NSXPCConnection? = AuthorizedPowerClient.helperConnection
    ) {
        self.serviceStatus = serviceStatus
        self.restartHoldOff = restartHoldOff
        self.makeConnection = makeConnection
    }

    static func helperConnection() -> NSXPCConnection? {
        let helper = Bundle.main.bundleURL.appendingPathComponent(PowerSamplingService.helperRelativePath)
        guard let requirement = try? PowerSamplingIdentity.requirement(for: helper) else { return nil }
        let connection = NSXPCConnection(machServiceName: PowerSamplingService.name, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        return connection
    }

    func response() -> PowerSamplingResponse {
        queue.sync {
            guard !closed else { return PowerSamplingResponse(failure: .stopped) }
            let status = serviceStatus()
            guard status == .enabled else {
                disconnect()
                return PowerSamplingResponse(failure: status == .requiresApproval ? .authorizationRequired : .connectionFailed)
            }
            if pending, Date().timeIntervalSince(requestedAt) > 3 {
                disconnect()
                cached = PowerSamplingResponse(failure: .connectionFailed)
            }
            if connection == nil {
                // Reconnecting before the helper's idle exit would reuse the old process.
                guard Date() >= reconnectAfter else { return PowerSamplingResponse() }
                connect()
            }
            if let connection, !pending {
                pending = true
                requestedAt = Date()
                let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] _ in
                    self?.queue.async { [weak self, weak connection] in
                        guard let self, self.connection === connection else { return }
                        self.disconnect()
                        self.cached = PowerSamplingResponse(failure: .connectionFailed)
                    }
                } as? PowerSamplingXPCProtocol
                proxy?.poll { [weak self, weak connection] data in
                    self?.queue.async { [weak self, weak connection] in
                        guard let self, self.connection === connection else { return }
                        self.pending = false
                        guard data.count < 16_384,
                              let response = try? JSONDecoder().decode(PowerSamplingResponse.self, from: data)
                        else {
                            self.cached = PowerSamplingResponse(failure: .samplingFailed)
                            return
                        }
                        self.cached = response
                    }
                }
            }
            if let reading = cached.reading, !reading.isFresh(at: Date()) {
                return PowerSamplingResponse(failure: .samplingFailed)
            }
            return cached
        }
    }

    func suspend() {
        queue.sync {
            reconnectAfter = .distantPast
            disconnect()
        }
    }

    func restart() {
        queue.sync {
            disconnect()
            reconnectAfter = Date().addingTimeInterval(restartHoldOff)
        }
    }

    func stop() {
        queue.sync {
            closed = true
            disconnect()
        }
    }

    private func connect() {
        guard let connection = makeConnection() else {
            cached = PowerSamplingResponse(failure: .connectionFailed)
            return
        }
        connection.remoteObjectInterface = NSXPCInterface(with: PowerSamplingXPCProtocol.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            self?.queue.async { [weak self, weak connection] in
                guard let self, self.connection === connection else { return }
                self.connection = nil
                self.pending = false
                self.cached = PowerSamplingResponse(failure: .connectionFailed)
            }
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        self.connection = connection
        connection.resume()
    }

    private func disconnect() {
        let previous = connection
        connection = nil
        pending = false
        cached = PowerSamplingResponse()
        previous?.invalidate()
    }
}
