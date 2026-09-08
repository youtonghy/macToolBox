import Darwin
import Foundation

final class PowerSession: NSObject, PowerSamplingXPCProtocol {
    let engine = PowerSamplingEngine()

    func poll(withReply reply: @escaping (Data) -> Void) {
        engine.poll { response in
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }

    func stop(withReply reply: @escaping () -> Void) {
        engine.stop(reply)
    }
}

final class PowerListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let lock = NSLock()
    private var active: NSXPCConnection?
    private var session: PowerSession?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // The listener has already verified the native sender's code signature.
        guard active == nil, connection.effectiveUserIdentifier != 0 else { return false }
        let session = PowerSession()
        self.session = session
        active = connection
        connection.exportedInterface = NSXPCInterface(with: PowerSamplingXPCProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak self, weak connection] in
            session.engine.stop()
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.active === connection {
                self.active = nil
                self.session = nil
            }
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.resume()
        return true
    }

    func shutdown() {
        lock.lock()
        let connection = active
        let engine = session?.engine
        lock.unlock()
        engine?.stop()
        connection?.invalidate()
    }
}

guard geteuid() == 0, let executable = Bundle.main.executableURL else { exit(EXIT_FAILURE) }
// BundleProgram fixes this location inside the app approved by ServiceManagement.
let application = executable.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
guard application.pathExtension == "app",
      Bundle(url: application)?.bundleIdentifier == "com.youtonghy.toolbox",
      let requirement = try? PowerSamplingIdentity.requirement(for: application)
else { exit(EXIT_FAILURE) }

let delegate = PowerListenerDelegate()
let listener = NSXPCListener(machServiceName: PowerSamplingService.name)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = delegate
listener.resume()

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let terminationSources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        delegate.shutdown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(EXIT_SUCCESS) }
    }
    source.resume()
    return source
}
RunLoop.main.run()
