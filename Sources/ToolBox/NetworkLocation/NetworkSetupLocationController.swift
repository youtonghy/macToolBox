import Foundation

/// Blocking network-location operations. Callers must invoke them off the
/// main thread; `NetworkLocationModel` serializes them on a private queue.
protocol NetworkLocationControlling: AnyObject, Sendable {
    func snapshot() throws -> NetworkLocationSnapshot
    /// `allowsAuthorizationPrompt` gates the administrator password dialog,
    /// so automatic switching never interrupts the user.
    func createLocation(named name: String, allowsAuthorizationPrompt: Bool) throws
    func switchToLocation(named name: String) throws
}

struct NetworkLocationProcessResult {
    var status: Int32
    var output: String
}

protocol NetworkLocationProcessRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> NetworkLocationProcessResult
}

/// Drives `/usr/sbin/networksetup`:
///
/// - `-listlocations` / `-getcurrentlocation` for reads (no privileges).
/// - `-switchtolocation`; when refused for missing privileges, falls back to
///   `scselect`, which macOS permits for any local console user without a
///   password prompt.
/// - `-createlocation <name> populate`; when refused, retries through the
///   standard administrator authorization dialog. `populate` adds the default
///   services, otherwise the new location would have no network connectivity.
///
/// `networksetup` does not reliably report failures through its exit status,
/// so every write is verified by re-reading the location state.
final class NetworkSetupLocationController: NetworkLocationControlling {
    static let networksetupPath = "/usr/sbin/networksetup"
    static let scselectPath = "/usr/sbin/scselect"
    static let osascriptPath = "/usr/bin/osascript"

    private let runner: NetworkLocationProcessRunning
    private let commandTimeout: TimeInterval
    private let authorizationTimeout: TimeInterval

    init(
        runner: NetworkLocationProcessRunning = NetworkLocationProcessRunner(),
        commandTimeout: TimeInterval = 20,
        authorizationTimeout: TimeInterval = 180
    ) {
        self.runner = runner
        self.commandTimeout = commandTimeout
        self.authorizationTimeout = authorizationTimeout
    }

    func snapshot() throws -> NetworkLocationSnapshot {
        let list = try networksetup(["-listlocations"])
        guard list.status == 0 else {
            throw NetworkLocationError.commandFailed(list.output.trimmed)
        }
        let current = try networksetup(["-getcurrentlocation"])
        return NetworkLocationSnapshot(
            locations: NetworkSetupOutput.locations(from: list.output),
            current: current.status == 0 ? NetworkSetupOutput.currentLocation(from: current.output) : nil
        )
    }

    func createLocation(named rawName: String, allowsAuthorizationPrompt: Bool) throws {
        let name = try NetworkLocationName.normalized(rawName)
        guard !(try snapshot().locations.contains(name)) else {
            throw NetworkLocationError.alreadyExists(name)
        }

        let result = try networksetup(["-createlocation", name, "populate"])
        if try snapshot().locations.contains(name) { return }

        guard allowsAuthorizationPrompt,
              NetworkSetupOutput.indicatesMissingPrivileges(result.output) else {
            throw NetworkLocationError.commandFailed(result.output.trimmed)
        }
        try runWithAdministratorPrivileges(["-createlocation", name, "populate"])
        guard try snapshot().locations.contains(name) else {
            throw NetworkLocationError.commandFailed(result.output.trimmed)
        }
    }

    func switchToLocation(named rawName: String) throws {
        let name = try NetworkLocationName.normalized(rawName)
        let before = try snapshot()
        guard before.locations.contains(name) else {
            throw NetworkLocationError.notFound(name)
        }
        guard before.current != name else { return }

        let result = try networksetup(["-switchtolocation", name])
        if try snapshot().current == name { return }

        guard NetworkSetupOutput.indicatesMissingPrivileges(result.output) else {
            throw NetworkLocationError.commandFailed(result.output.trimmed)
        }
        let fallback = try runner.run(
            executable: Self.scselectPath,
            arguments: [name],
            timeout: commandTimeout
        )
        guard try snapshot().current == name else {
            let detail = fallback.output.trimmed
            throw detail.isEmpty
                ? NetworkLocationError.notApplied(name)
                : NetworkLocationError.commandFailed(detail)
        }
    }

    private func networksetup(_ arguments: [String]) throws -> NetworkLocationProcessResult {
        try runner.run(executable: Self.networksetupPath, arguments: arguments, timeout: commandTimeout)
    }

    /// Runs `networksetup` as root through the system authorization dialog.
    /// Arguments reach the shell only via `quoted form of`, never by string
    /// interpolation, so location names cannot inject shell syntax.
    private func runWithAdministratorPrivileges(_ arguments: [String]) throws {
        let quotedArguments = arguments.indices
            .map { "quoted form of (item \($0 + 1) of argv)" }
            .joined(separator: " & \" \" & ")
        let script = [
            "on run argv",
            "do shell script \"\(Self.networksetupPath) \" & \(quotedArguments) with administrator privileges",
            "end run",
        ]
        let result = try runner.run(
            executable: Self.osascriptPath,
            arguments: script.flatMap { ["-e", $0] } + arguments,
            timeout: authorizationTimeout
        )
        guard result.status == 0 else {
            // AppleScript error -128 is "User canceled".
            if result.output.contains("-128") { throw NetworkLocationError.cancelled }
            throw NetworkLocationError.commandFailed(result.output.trimmed)
        }
    }
}

/// Runs a short-lived tool, capturing merged stdout/stderr and terminating it
/// once `timeout` elapses.
struct NetworkLocationProcessRunner: NetworkLocationProcessRunning {
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> NetworkLocationProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw NetworkLocationError.launchFailed(error.localizedDescription)
        }

        // Drain the pipe concurrently so a chatty child can never block on a
        // full pipe buffer while we wait for it to exit.
        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            throw NetworkLocationError.timedOut
        }
        // A descendant that inherited the pipe could keep it open after exit.
        guard drained.wait(timeout: .now() + 2) == .success else {
            throw NetworkLocationError.timedOut
        }
        return NetworkLocationProcessResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
