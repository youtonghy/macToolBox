import Foundation
import ServiceManagement

protocol AuthorizedPowerSampling: AnyObject {
    func response() -> PowerSamplingResponse
    func suspend()
    func stop()
}

final class AuthorizedPowerClient: AuthorizedPowerSampling {
    private let queue = DispatchQueue(label: "com.youtonghy.toolbox.power-client")
    private var connection: NSXPCConnection?
    private var cached = PowerSamplingResponse()
    private var pending = false
    private var requestedAt = Date.distantPast
    private var closed = false

    func response() -> PowerSamplingResponse {
        queue.sync {
            guard !closed else { return PowerSamplingResponse(failure: .stopped) }
            guard SMAppService.daemon(plistName: PowerSamplingService.plistName).status == .enabled else {
                disconnect()
                return PowerSamplingResponse(failure: .authorizationRequired)
            }
            if pending, Date().timeIntervalSince(requestedAt) > 3 {
                disconnect()
                cached = PowerSamplingResponse(failure: .connectionFailed)
            }
            if connection == nil { connect() }
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
        queue.sync { disconnect() }
    }

    func stop() {
        queue.sync {
            closed = true
            disconnect()
        }
    }

    private func connect() {
        let helper = Bundle.main.bundleURL.appendingPathComponent(PowerSamplingService.helperRelativePath)
        guard let requirement = try? PowerSamplingIdentity.requirement(for: helper) else {
            cached = PowerSamplingResponse(failure: .connectionFailed)
            return
        }
        let connection = NSXPCConnection(machServiceName: PowerSamplingService.name, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
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
