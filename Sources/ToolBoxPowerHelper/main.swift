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
    private var idleExit: DispatchWorkItem?
    private var retiring = false
    private let executablePath: String
    private let launchedExecutable: ExecutableFileIdentity

    init(executablePath: String, launchedExecutable: ExecutableFileIdentity) {
        self.executablePath = executablePath
        self.launchedExecutable = launchedExecutable
    }

    func scheduleIdleExit() {
        lock.lock()
        defer { lock.unlock() }
        scheduleIdleExitLocked()
    }

    private func scheduleIdleExitLocked() {
        idleExit?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { exit(EXIT_SUCCESS) }
            self.lock.lock()
            let idle = self.active == nil
            self.lock.unlock()
            if idle { exit(EXIT_SUCCESS) }
        }
        idleExit = item
        // With no client connected the daemon has nothing to do; exiting lets
        // launchd respawn a clean process on the next connection instead of a
        // wedged listener holding the Mach service forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + PowerSamplingService.helperIdleExitDelay, execute: item)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The listener has already verified the native sender's code signature.
        guard connection.effectiveUserIdentifier != 0 else { return false }
        // After an app update the client rejects this stale process on every
        // message while its reconnects keep cancelling the idle exit. Retire so
        // launchd starts the updated helper for the next connection.
        guard ExecutableFileIdentity(path: executablePath) == launchedExecutable else {
            retire()
            return false
        }
        lock.lock()
        guard !retiring else {
            lock.unlock()
            return false
        }
        let session = PowerSession()
        idleExit?.cancel()
        idleExit = nil
        // The newest connection wins: a stale dead connection must not reject
        // reconnects for the daemon's entire lifetime.
        let previous = active
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
                self.scheduleIdleExitLocked()
            }
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.resume()
        lock.unlock()
        previous?.invalidate()
        return true
    }

    /// Stops sampling, then exits once the child has had time to terminate.
    func retire() {
        lock.lock()
        let alreadyRetiring = retiring
        retiring = true
        lock.unlock()
        guard !alreadyRetiring else { return }
        shutdown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(EXIT_SUCCESS) }
    }

    private func shutdown() {
        lock.lock()
        let connection = active
        let engine = session?.engine
        idleExit?.cancel()
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

guard let launchedExecutable = ExecutableFileIdentity(path: executable.path) else { exit(EXIT_FAILURE) }

let delegate = PowerListenerDelegate(executablePath: executable.path, launchedExecutable: launchedExecutable)
let listener = NSXPCListener(machServiceName: PowerSamplingService.name)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = delegate
listener.resume()
// A spawned helper whose client never connects (e.g. launchd raced an app
// exit) must not linger holding the Mach service.
delegate.scheduleIdleExit()

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let terminationSources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { delegate.retire() }
    source.resume()
    return source
}
RunLoop.main.run()
