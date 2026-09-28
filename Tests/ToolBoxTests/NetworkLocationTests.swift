import Foundation
import XCTest
@testable import ToolBoxCore

final class NetworkLocationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "NetworkLocationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Output parsing

    func testLocationListParsingTrimsDeduplicatesAndSkipsErrors() {
        let output = "Automatic\n 公司 \n\n** Error: something\n公司\nHome\n"

        XCTAssertEqual(NetworkSetupOutput.locations(from: output), ["Automatic", "公司", "Home"])
    }

    func testCurrentLocationRequiresSingleLine() {
        XCTAssertEqual(NetworkSetupOutput.currentLocation(from: "公司\n"), "公司")
        XCTAssertNil(NetworkSetupOutput.currentLocation(from: ""))
        XCTAssertNil(NetworkSetupOutput.currentLocation(from: "a\nb\n"))
    }

    func testMissingPrivilegesMessageIsRecognized() {
        let message = "The networksetup tool requires at least admin privileges to change network settings."

        XCTAssertTrue(NetworkSetupOutput.indicatesMissingPrivileges(message))
        XCTAssertTrue(NetworkSetupOutput.indicatesMissingPrivileges("Command requires admin privileges."))
        XCTAssertFalse(NetworkSetupOutput.indicatesMissingPrivileges("Automatic\n"))
    }

    // MARK: - Name validation

    func testLocationNameIsTrimmedAndValidated() throws {
        XCTAssertEqual(try NetworkLocationName.normalized("  公司 "), "公司")
        for invalid in ["", "   ", "-bad", "two\nlines", String(repeating: "x", count: 65)] {
            XCTAssertThrowsError(try NetworkLocationName.normalized(invalid), invalid) { error in
                XCTAssertEqual(error as? NetworkLocationError, .invalidName)
            }
        }
    }

    // MARK: - Auto switch policy

    func testPolicyUsesFirstMatchingRule() {
        let configuration = autoSwitch(rules: [("Office", "公司"), ("Office", "Home")])
        let snapshot = NetworkLocationSnapshot(locations: ["Automatic", "公司", "Home"], current: "Automatic")

        XCTAssertEqual(
            NetworkLocationAutoSwitchPolicy.targetLocation(ssid: "Office", configuration: configuration, snapshot: snapshot),
            "公司"
        )
    }

    func testPolicySkipsWhenAlreadyCurrentDisconnectedDisabledOrMissing() {
        let snapshot = NetworkLocationSnapshot(locations: ["Automatic", "公司"], current: "公司")
        let configuration = autoSwitch(rules: [("Office", "公司"), ("Lab", "Gone")])

        XCTAssertNil(NetworkLocationAutoSwitchPolicy.targetLocation(ssid: "Office", configuration: configuration, snapshot: snapshot))
        XCTAssertNil(NetworkLocationAutoSwitchPolicy.targetLocation(ssid: nil, configuration: configuration, snapshot: snapshot))
        XCTAssertNil(NetworkLocationAutoSwitchPolicy.targetLocation(ssid: "Lab", configuration: configuration, snapshot: snapshot))

        var disabled = configuration
        disabled.isEnabled = false
        let elsewhere = NetworkLocationSnapshot(locations: ["Automatic", "公司"], current: "Automatic")
        XCTAssertNil(NetworkLocationAutoSwitchPolicy.targetLocation(ssid: "Office", configuration: disabled, snapshot: elsewhere))
    }

    func testPolicyFallsBackForUnmatchedNetworks() {
        var configuration = autoSwitch(rules: [("Office", "公司")])
        let snapshot = NetworkLocationSnapshot(locations: ["Automatic", "公司"], current: "公司")

        XCTAssertNil(NetworkLocationAutoSwitchPolicy.targetLocation(ssid: "Cafe", configuration: configuration, snapshot: snapshot))

        configuration.fallbackLocation = "Automatic"
        XCTAssertEqual(
            NetworkLocationAutoSwitchPolicy.targetLocation(ssid: "Cafe", configuration: configuration, snapshot: snapshot),
            "Automatic"
        )
    }

    // MARK: - Persistence

    func testSettingsRoundTripThroughDefaults() throws {
        let store = NetworkLocationSettingsStore(defaults: defaults)
        var configuration = autoSwitch(rules: [("Office", "公司")])
        configuration.fallbackLocation = "Automatic"

        try store.save(configuration)

        XCTAssertEqual(store.load(), configuration)
    }

    func testCorruptSettingsFallBackToDisabledAndKeepBackup() {
        defaults.set(Data("not json".utf8), forKey: NetworkLocationSettingsStore.defaultsKey)

        XCTAssertEqual(NetworkLocationSettingsStore(defaults: defaults).load(), .disabled)
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.contains {
            $0.hasPrefix("\(NetworkLocationSettingsStore.defaultsKey).corrupt-")
        })
    }

    // MARK: - networksetup controller

    func testSwitchUsesNetworksetup() throws {
        let runner = SimulatedNetworkSetup(locations: ["Automatic", "公司"], current: "Automatic")
        let controller = NetworkSetupLocationController(runner: runner)

        try controller.switchToLocation(named: "公司")

        XCTAssertEqual(runner.current, "公司")
        XCTAssertTrue(runner.calls.contains(["networksetup", "-switchtolocation", "公司"]))
        XCTAssertFalse(runner.calls.contains { $0.first == "scselect" })
    }

    func testSwitchFallsBackToScselectWhenPrivilegesAreMissing() throws {
        let runner = SimulatedNetworkSetup(locations: ["Automatic", "公司"], current: "Automatic")
        runner.networksetupWritesDenied = true
        let controller = NetworkSetupLocationController(runner: runner)

        try controller.switchToLocation(named: "公司")

        XCTAssertEqual(runner.current, "公司")
        XCTAssertTrue(runner.calls.contains(["scselect", "公司"]))
        XCTAssertFalse(runner.calls.contains { $0.first == "osascript" })
    }

    func testSwitchToUnknownLocationFails() {
        let runner = SimulatedNetworkSetup(locations: ["Automatic"], current: "Automatic")
        let controller = NetworkSetupLocationController(runner: runner)

        XCTAssertThrowsError(try controller.switchToLocation(named: "公司")) { error in
            XCTAssertEqual(error as? NetworkLocationError, .notFound("公司"))
        }
    }

    func testCreatePopulatesDefaultServices() throws {
        let runner = SimulatedNetworkSetup(locations: ["Automatic"], current: "Automatic")
        let controller = NetworkSetupLocationController(runner: runner)

        try controller.createLocation(named: " 公司 ", allowsAuthorizationPrompt: false)

        XCTAssertEqual(runner.locations, ["Automatic", "公司"])
        XCTAssertTrue(runner.calls.contains(["networksetup", "-createlocation", "公司", "populate"]))
    }

    func testCreateEscalatesWithNamesPassedAsArgumentsOnly() throws {
        let runner = SimulatedNetworkSetup(locations: ["Automatic"], current: "Automatic")
        runner.networksetupWritesDenied = true
        let controller = NetworkSetupLocationController(runner: runner)
        let hostile = "x'; touch /tmp/pwned; echo '"

        try controller.createLocation(named: hostile, allowsAuthorizationPrompt: true)

        XCTAssertTrue(runner.locations.contains(hostile))
        let osascript = try XCTUnwrap(runner.calls.first { $0.first == "osascript" })
        XCTAssertEqual(Array(osascript.suffix(3)), ["-createlocation", hostile, "populate"])
        let script = osascript.dropFirst().dropLast(3).joined(separator: "\n")
        XCTAssertFalse(script.contains(hostile))
        XCTAssertTrue(script.contains("quoted form of (item 2 of argv)"))
        XCTAssertTrue(script.contains("with administrator privileges"))
    }

    func testCreateNeverPromptsWhenPromptIsNotAllowed() {
        let runner = SimulatedNetworkSetup(locations: ["Automatic"], current: "Automatic")
        runner.networksetupWritesDenied = true
        let controller = NetworkSetupLocationController(runner: runner)

        XCTAssertThrowsError(try controller.createLocation(named: "公司", allowsAuthorizationPrompt: false))
        XCTAssertFalse(runner.calls.contains { $0.first == "osascript" })
        XCTAssertEqual(runner.locations, ["Automatic"])
    }

    func testCancelledAuthorizationIsReportedAsCancelled() {
        let runner = SimulatedNetworkSetup(locations: ["Automatic"], current: "Automatic")
        runner.networksetupWritesDenied = true
        runner.administratorCancels = true
        let controller = NetworkSetupLocationController(runner: runner)

        XCTAssertThrowsError(try controller.createLocation(named: "公司", allowsAuthorizationPrompt: true)) { error in
            XCTAssertEqual(error as? NetworkLocationError, .cancelled)
        }
    }

    func testCreateRejectsExistingLocation() {
        let runner = SimulatedNetworkSetup(locations: ["Automatic", "公司"], current: "Automatic")
        let controller = NetworkSetupLocationController(runner: runner)

        XCTAssertThrowsError(try controller.createLocation(named: "公司", allowsAuthorizationPrompt: true)) { error in
            XCTAssertEqual(error as? NetworkLocationError, .alreadyExists("公司"))
        }
    }

    // MARK: - Model

    @MainActor
    func testAutoSwitchRunsOncePerNetworkArrivalSoManualChoiceSticks() async throws {
        let runner = SimulatedNetworkSetup(locations: ["Automatic", "公司"], current: "Automatic")
        let monitor = FakeSSIDMonitor()
        let store = NetworkLocationSettingsStore(defaults: defaults)
        try store.save(autoSwitch(rules: [("Office", "公司")]))
        let model = NetworkLocationModel(
            controller: NetworkSetupLocationController(runner: runner),
            store: store,
            ssidMonitor: monitor,
            preferencesObserver: nil
        )
        model.start()
        XCTAssertTrue(monitor.isRunning)

        monitor.emit("Office")
        try await waitUntil { model.snapshot.current == "公司" && !model.isBusy }
        XCTAssertNotNil(model.lastAutoSwitchMessage)

        model.switchTo("Automatic")
        try await waitUntil { model.snapshot.current == "Automatic" && !model.isBusy }

        // Periodic re-reads and brief disconnects on the same network keep the manual choice.
        monitor.emit("Office")
        monitor.emit(nil)
        monitor.emit("Office")
        model.refresh()
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(model.snapshot.current, "Automatic")
        XCTAssertEqual(runner.calls.filter { $0 == ["networksetup", "-switchtolocation", "公司"] }.count, 1)
        model.stop()
    }

    @MainActor
    func testDisabledAutoSwitchDoesNotMonitorSSID() async throws {
        let monitor = FakeSSIDMonitor()
        let model = NetworkLocationModel(
            controller: NetworkSetupLocationController(
                runner: SimulatedNetworkSetup(locations: ["Automatic"], current: "Automatic")
            ),
            store: NetworkLocationSettingsStore(defaults: defaults),
            ssidMonitor: monitor,
            preferencesObserver: nil
        )

        model.start()
        try await waitUntil { model.snapshot.current == "Automatic" }
        XCTAssertFalse(monitor.isRunning)

        model.setAutoSwitchEnabled(true)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertTrue(monitor.didRequestAuthorization)
        model.stop()
    }

    // MARK: - Helpers

    private func autoSwitch(rules: [(String, String)]) -> NetworkLocationAutoSwitchConfiguration {
        NetworkLocationAutoSwitchConfiguration(
            isEnabled: true,
            rules: rules.map { NetworkLocationSSIDRule(ssid: $0.0, location: $0.1) },
            fallbackLocation: nil
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// In-memory stand-in for networksetup / scselect / osascript.
private final class SimulatedNetworkSetup: NetworkLocationProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _locations: [String]
    private var _current: String?
    private var _calls: [[String]] = []
    var networksetupWritesDenied = false
    var administratorCancels = false

    init(locations: [String], current: String?) {
        _locations = locations
        _current = current
    }

    var locations: [String] { lock.withLock { _locations } }
    var current: String? { lock.withLock { _current } }
    var calls: [[String]] { lock.withLock { _calls } }

    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> NetworkLocationProcessResult {
        lock.lock()
        defer { lock.unlock() }
        let tool = URL(fileURLWithPath: executable).lastPathComponent
        _calls.append([tool] + arguments)

        switch tool {
        case "networksetup":
            return networksetup(arguments, privileged: !networksetupWritesDenied)
        case "scselect":
            guard let name = arguments.first, _locations.contains(name) else {
                return NetworkLocationProcessResult(status: 1, output: "no such set")
            }
            _current = name
            return NetworkLocationProcessResult(status: 0, output: "CurrentSet updated to \(name)")
        case "osascript":
            if administratorCancels {
                return NetworkLocationProcessResult(status: 1, output: "execution error: User canceled. (-128)")
            }
            // The networksetup arguments are the trailing argv items.
            let separatorIndex = arguments.lastIndex(of: "end run").map { $0 + 1 } ?? arguments.count
            return networksetup(Array(arguments[separatorIndex...]), privileged: true)
        default:
            return NetworkLocationProcessResult(status: 127, output: "unknown tool")
        }
    }

    private func networksetup(_ arguments: [String], privileged: Bool) -> NetworkLocationProcessResult {
        let denied = NetworkLocationProcessResult(
            status: 0,
            output: "The networksetup tool requires at least admin privileges to change network settings."
        )
        switch arguments.first {
        case "-listlocations":
            return NetworkLocationProcessResult(status: 0, output: _locations.joined(separator: "\n") + "\n")
        case "-getcurrentlocation":
            return NetworkLocationProcessResult(status: 0, output: (_current ?? "") + "\n")
        case "-switchtolocation":
            guard privileged else { return denied }
            _current = arguments[1]
            return NetworkLocationProcessResult(status: 0, output: "")
        case "-createlocation":
            guard privileged else { return denied }
            _locations.append(arguments[1])
            return NetworkLocationProcessResult(status: 0, output: "")
        default:
            return NetworkLocationProcessResult(status: 1, output: "unsupported")
        }
    }
}

private final class FakeSSIDMonitor: NetworkLocationSSIDMonitoring {
    var onSSIDChange: (@MainActor (String?) -> Void)?
    var onAuthorizationChange: (@MainActor (NetworkLocationSSIDAuthorization) -> Void)?
    var authorization = NetworkLocationSSIDAuthorization.notDetermined
    private(set) var isRunning = false
    private(set) var didRequestAuthorization = false

    func requestAuthorization() { didRequestAuthorization = true }
    func start() { isRunning = true }
    func stop() { isRunning = false }

    @MainActor
    func emit(_ ssid: String?) {
        onSSIDChange?(ssid)
    }
}
