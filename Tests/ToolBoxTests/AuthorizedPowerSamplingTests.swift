import Foundation
import Security
import ServiceManagement
import XCTest
@testable import ToolBoxCore

final class AuthorizedPowerSamplingTests: XCTestCase {
    // Captured from this Mac's system powermetrics output. Values are mW.
    private let report = """
    *** Sampled system activity (Tue Sep 8 2026) (1014.92ms elapsed) ***
    **** Processor usage ****
    CPU 0 frequency: 1837 MHz
    CPU Power: 23527 mW
    GPU Power: 54 mW
    ANE Power: 0 mW
    Combined Power (CPU + GPU + ANE): 23582 mW

    """

    func testCapturedSystemReportAcrossArbitraryPipeChunks() throws {
        var parser = PowermetricsParser()
        let now = Date()
        var readings: [AuthorizedPowerReading] = []
        for byte in Data(report.utf8) {
            readings += parser.append(Data([byte]), now: now)
        }
        let reading = try XCTUnwrap(readings.first)
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(reading.cpuWatts, 23.527, accuracy: 0.000001)
        XCTAssertEqual(reading.gpuWatts, 0.054)
        XCTAssertEqual(reading.aneWatts, 0)
        XCTAssertEqual(reading.combinedWatts, 23.582)
        XCTAssertEqual(reading.interval, 1.01492, accuracy: 0.000001)
        XCTAssertEqual(reading.timestamp, now)
    }

    func testMissingOrInvalidCPUDoesNotBecomeZeroOrReusePreviousReading() {
        for invalid in ["CPU Power: nan mW", "CPU Power: -1 mW", "CPU Power: 23 W", "CPU Power: unavailable"] {
            var parser = PowermetricsParser()
            let data = report + report.replacingOccurrences(of: "CPU Power: 23527 mW", with: invalid)
            XCTAssertEqual(parser.append(Data(data.utf8)).count, 1)
        }
        var parser = PowermetricsParser()
        XCTAssertTrue(parser.append(Data(report.replacingOccurrences(of: "CPU Power: 23527 mW\n", with: "").utf8)).isEmpty)
    }

    func testValidZeroIsPreservedAndIncompleteReportIsNotPublished() {
        var parser = PowermetricsParser()
        let partial = report.components(separatedBy: "Combined Power")[0]
        XCTAssertTrue(parser.append(Data(partial.utf8)).isEmpty)
        parser = PowermetricsParser()
        let zero = parser.append(Data(report.replacingOccurrences(of: "23527", with: "0").utf8)).first
        XCTAssertEqual(zero?.cpuWatts, 0)
    }

    func testStaleAndUnauthorizedSamplesHaveNoCPUValue() {
        var parser = PowermetricsParser()
        let now = Date()
        let reading = parser.append(Data(report.utf8), now: now.addingTimeInterval(-4)).first
        for response in [PowerSamplingResponse(reading: reading), PowerSamplingResponse(failure: .authorizationRequired)] {
            let snapshot = DarwinChipPowerProvider.authorizedSnapshot(
                response: response, systemWatts: 50, chipName: nil, macModel: nil, now: now
            )
            XCTAssertNil(snapshot.cpuWatts)
            XCTAssertNil(snapshot.combinedWatts)
            XCTAssertEqual(snapshot.status, .unavailable)
            XCTAssertEqual(snapshot.systemWatts, 50)
        }
    }

    func testContinuousMissingSamplesKeepRestartingWithBackoff() {
        var recovery = AuthorizedPowerRecovery(gracePeriod: 10, maximumDelay: 40, maximumObservationGap: 10)
        var outageStart = Date()
        XCTAssertFalse(recovery.observe(PowerSamplingResponse(), now: outageStart))
        // Restart delays double from the grace period up to the cap, and the
        // outage never turns sampling off.
        for delay in [10, 20, 40, 40] {
            for second in 1..<delay {
                XCTAssertFalse(recovery.observe(PowerSamplingResponse(), now: outageStart.addingTimeInterval(Double(second))))
            }
            let due = outageStart.addingTimeInterval(Double(delay))
            XCTAssertTrue(recovery.observe(PowerSamplingResponse(), now: due))
            // A busy settings operation defers the restart without losing it.
            outageStart = due.addingTimeInterval(0.5)
            XCTAssertTrue(recovery.observe(PowerSamplingResponse(), now: outageStart))
            recovery.markRestarted(now: outageStart)
        }
    }

    func testOnlyPendingSystemApprovalPausesRecovery() {
        let pending = AuthorizedPowerClient(serviceStatus: { .requiresApproval })
        XCTAssertEqual(pending.response().failure, .authorizationRequired)
        for status in [SMAppService.Status.notRegistered, .notFound] {
            let unavailable = AuthorizedPowerClient(serviceStatus: { status })
            XCTAssertEqual(unavailable.response().failure, .connectionFailed)
        }
    }

    func testFreshZeroAndPartialSamplesRecoverWithoutRequiringEveryChannel() {
        var recovery = AuthorizedPowerRecovery(gracePeriod: 1)
        let start = Date()
        XCTAssertFalse(recovery.observe(PowerSamplingResponse(), now: start))
        XCTAssertTrue(recovery.observe(PowerSamplingResponse(), now: start.addingTimeInterval(1)))
        recovery.markRestarted(now: start.addingTimeInterval(1))
        XCTAssertEqual(recovery.currentDelay, 2)
        let reading = AuthorizedPowerReading(
            timestamp: start.addingTimeInterval(2), interval: 1, cpuWatts: 0,
            gpuWatts: nil, aneWatts: nil, combinedWatts: nil
        )
        XCTAssertFalse(recovery.observe(PowerSamplingResponse(reading: reading), now: start.addingTimeInterval(2)))
        // Recovery also resets the backoff.
        XCTAssertEqual(recovery.currentDelay, 1)
        XCTAssertFalse(recovery.observe(PowerSamplingResponse(), now: start.addingTimeInterval(3)))
        XCTAssertTrue(recovery.observe(PowerSamplingResponse(), now: start.addingTimeInterval(4)))
    }

    func testStaleSampleDoesNotResetRecoveryAndWaitingForApprovalDoes() {
        var recovery = AuthorizedPowerRecovery(gracePeriod: 1)
        let start = Date()
        let stale = PowerSamplingResponse(reading: AuthorizedPowerReading(
            timestamp: start.addingTimeInterval(-10), interval: 1, cpuWatts: 2,
            gpuWatts: 1, aneWatts: 0, combinedWatts: 3
        ))
        XCTAssertFalse(recovery.observe(stale, now: start))
        XCTAssertTrue(recovery.observe(stale, now: start.addingTimeInterval(1)))
        recovery.markRestarted(now: start.addingTimeInterval(1))
        for second in 2..<30 {
            XCTAssertFalse(recovery.observe(
                PowerSamplingResponse(failure: .authorizationRequired), now: start.addingTimeInterval(Double(second))
            ))
        }
        XCTAssertFalse(recovery.observe(stale, now: start.addingTimeInterval(30)))
        XCTAssertTrue(recovery.observe(stale, now: start.addingTimeInterval(31)))
    }

    func testSamplingPauseAndManualResetGiveRecoveryANewGracePeriod() {
        var recovery = AuthorizedPowerRecovery(gracePeriod: 2, maximumObservationGap: 3)
        let start = Date()
        XCTAssertFalse(recovery.observe(PowerSamplingResponse(), now: start))
        XCTAssertFalse(recovery.observe(PowerSamplingResponse(), now: start.addingTimeInterval(1)))
        XCTAssertFalse(recovery.observe(PowerSamplingResponse(), now: start.addingTimeInterval(60)))
        XCTAssertFalse(recovery.observe(PowerSamplingResponse(), now: start.addingTimeInterval(61)))
        XCTAssertTrue(recovery.observe(PowerSamplingResponse(), now: start.addingTimeInterval(62)))
        recovery.markRestarted(now: start.addingTimeInterval(62))
        recovery.reset()
        XCTAssertFalse(recovery.observe(PowerSamplingResponse(), now: start.addingTimeInterval(63)))
        XCTAssertTrue(recovery.observe(PowerSamplingResponse(), now: start.addingTimeInterval(65)))
    }

    func testProviderRestartsMissingSamplesAndKeepsRecoveredSamplingEnabled() async {
        let recovered = expectation(description: "fresh samples after rebuilding the session")
        recovered.expectedFulfillmentCount = 2
        let reported = expectation(description: "recovery ends the failure streak")
        let client = RecoveryPowerTestClient(recoversAfterRestart: true)
        let provider = DarwinChipPowerProvider(
            authorizedModeEnabled: { true }, authorizedSamplerFactory: { client },
            authorizedRecoveryDelay: 0.25,
            restartAuthorizedMode: { true },
            // Reported once per restart, not on every fresh sample.
            authorizedSamplingRecovered: { reported.fulfill() }
        )
        provider.onUpdate = { snapshot in
            if snapshot.cpuWatts == 0 { recovered.fulfill() }
        }
        provider.start(interval: 0.25)
        await fulfillment(of: [recovered, reported], timeout: 3)
        provider.stop()
        XCTAssertEqual(client.restarts, 1)
        XCTAssertTrue(client.didStop)
    }

    func testProviderKeepsRestartingPersistentOutageWithoutDisabling() async {
        let restartedAgain = expectation(description: "persistent N/A restarts the helper again")
        let client = RecoveryPowerTestClient(recoversAfterRestart: false)
        client.onRestart = { count in if count == 2 { restartedAgain.fulfill() } }
        let provider = DarwinChipPowerProvider(
            authorizedModeEnabled: { true }, authorizedSamplerFactory: { client },
            authorizedRecoveryDelay: 0.25,
            restartAuthorizedMode: { true }
        )
        provider.start(interval: 0.1)
        await fulfillment(of: [restartedAgain], timeout: 3)
        provider.stop()
        // Still in authorized mode: the session was never suspended for fallback.
        XCTAssertEqual(client.suspensions, 0)
        XCTAssertTrue(client.didStop)
    }

    func testClientRestartHoldsOffReconnectUntilHelperCanExit() {
        var attempts = 0
        let client = AuthorizedPowerClient(
            serviceStatus: { .enabled }, restartHoldOff: 60, makeConnection: { attempts += 1; return nil }
        )
        XCTAssertEqual(client.response().failure, .connectionFailed)
        XCTAssertEqual(attempts, 1)
        client.restart()
        let waiting = client.response()
        XCTAssertNil(waiting.failure)
        XCTAssertNil(waiting.reading)
        XCTAssertEqual(attempts, 1)
        // Leaving authorized mode ends the hold-off for the next manual enable.
        client.suspend()
        XCTAssertEqual(client.response().failure, .connectionFailed)
        XCTAssertEqual(attempts, 2)

        var immediateAttempts = 0
        let immediate = AuthorizedPowerClient(
            serviceStatus: { .enabled }, restartHoldOff: 0, makeConnection: { immediateAttempts += 1; return nil }
        )
        immediate.restart()
        XCTAssertEqual(immediate.response().failure, .connectionFailed)
        XCTAssertEqual(immediateAttempts, 1)
    }

    @MainActor
    func testAutomaticRestartKeepsAnEnabledServiceAndRegistersAMissingOne() async {
        let suite = "PowerRecoverySettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PowerSamplingService.enabledKey)
        let service = RecoveryPowerTestService()
        let settings = AuthorizedPowerSettings(defaults: defaults, service: service, pinnedHelperIdentity: { nil })

        // An enabled daemon is left alone: the client's restart hold-off is
        // what lets launchd replace a stuck helper, not re-registration.
        var attempted = await settings.restartAfterSamplingFailure()
        XCTAssertTrue(attempted)
        XCTAssertTrue(settings.requested)
        XCTAssertEqual(service.unregistrations, 0)
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(settings.status, .enabled)

        service.status = .notRegistered
        attempted = await settings.restartAfterSamplingFailure()
        XCTAssertTrue(attempted)
        XCTAssertEqual(service.unregistrations, 0)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(settings.status, .enabled)
    }

    @MainActor
    func testLaunchReregistersAHelperPinnedToAnotherBuild() async {
        let suite = "PowerRecoverySettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PowerSamplingService.enabledKey)
        let service = RecoveryPowerTestService()
        var helper: String? = "build-1"
        let settings = AuthorizedPowerSettings(defaults: defaults, service: service, pinnedHelperIdentity: { helper })

        // A registration from before the identity was recorded is refreshed once.
        await settings.refreshStaleRegistration()
        XCTAssertEqual(service.unregistrations, 1)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(defaults.string(forKey: AuthorizedPowerSettings.registeredHelperKey), "build-1")
        await settings.refreshStaleRegistration()
        XCTAssertEqual(service.registrations, 1)

        // A rebuilt or updated helper gets a new cdhash.
        helper = "build-2"
        await settings.refreshStaleRegistration()
        XCTAssertEqual(service.unregistrations, 2)
        XCTAssertEqual(service.registrations, 2)
        XCTAssertEqual(defaults.string(forKey: AuthorizedPowerSettings.registeredHelperKey), "build-2")
        XCTAssertTrue(settings.requested)
        XCTAssertNil(settings.errorMessage)
    }

    @MainActor
    func testTeamSignedOrDisabledHelperIsNotReregistered() async {
        let suite = "PowerRecoverySettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PowerSamplingService.enabledKey)
        let service = RecoveryPowerTestService()
        let teamSigned = AuthorizedPowerSettings(defaults: defaults, service: service, pinnedHelperIdentity: { nil })
        await teamSigned.refreshStaleRegistration()
        XCTAssertEqual(service.unregistrations, 0)

        defaults.set(false, forKey: PowerSamplingService.enabledKey)
        let disabled = AuthorizedPowerSettings(defaults: defaults, service: service, pinnedHelperIdentity: { "build-1" })
        await disabled.refreshStaleRegistration()
        XCTAssertEqual(service.unregistrations, 0)
        XCTAssertEqual(service.registrations, 0)
    }

    @MainActor
    func testRecoveryReregistersAStaleHelperAndEnablingRecordsIt() async {
        let suite = "PowerRecoverySettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = RecoveryPowerTestService()
        service.status = .notRegistered
        let settings = AuthorizedPowerSettings(defaults: defaults, service: service, pinnedHelperIdentity: { "build-1" })

        settings.setEnabled(true)
        await waitForSettingsChange(settings)
        XCTAssertEqual(defaults.string(forKey: AuthorizedPowerSettings.registeredHelperKey), "build-1")
        let current = await settings.restartAfterSamplingFailure()
        XCTAssertTrue(current)
        XCTAssertEqual(service.unregistrations, 0)

        defaults.set("build-0", forKey: AuthorizedPowerSettings.registeredHelperKey)
        let stale = await settings.restartAfterSamplingFailure()
        XCTAssertTrue(stale)
        XCTAssertEqual(service.unregistrations, 1)
        XCTAssertEqual(service.registrations, 2)
        XCTAssertEqual(defaults.string(forKey: AuthorizedPowerSettings.registeredHelperKey), "build-1")
    }

    @MainActor
    func testFiveFailedRestartsTurnSamplingOffAndMarkItUnavailable() async {
        let suite = "PowerRecoverySettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PowerSamplingService.enabledKey)
        let service = RecoveryPowerTestService()
        let settings = AuthorizedPowerSettings(defaults: defaults, service: service, pinnedHelperIdentity: { nil })

        for _ in 0..<AuthorizedPowerSettings.maximumFailedRestarts {
            let restarted = await settings.restartAfterSamplingFailure()
            XCTAssertTrue(restarted)
        }
        XCTAssertTrue(settings.requested)
        XCTAssertFalse(settings.unavailable)

        let restarted = await settings.restartAfterSamplingFailure()
        XCTAssertFalse(restarted)
        XCTAssertFalse(settings.requested)
        XCTAssertFalse(defaults.bool(forKey: PowerSamplingService.enabledKey))
        XCTAssertTrue(settings.unavailable)
        await waitForSettingsChange(settings)
        XCTAssertEqual(service.unregistrations, 1)
        XCTAssertTrue(settings.unavailable)

        // Enabling again by hand clears the notice and starts a new streak.
        settings.setEnabled(true)
        await waitForSettingsChange(settings)
        XCTAssertTrue(settings.requested)
        XCTAssertFalse(settings.unavailable)
        XCTAssertEqual(defaults.integer(forKey: AuthorizedPowerSettings.failedRestartsKey), 0)
    }

    @MainActor
    func testFreshSampleResetsTheFailedRestartStreak() async {
        let suite = "PowerRecoverySettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PowerSamplingService.enabledKey)
        let settings = AuthorizedPowerSettings(defaults: defaults, service: RecoveryPowerTestService(), pinnedHelperIdentity: { nil })

        for _ in 0..<(AuthorizedPowerSettings.maximumFailedRestarts - 1) {
            _ = await settings.restartAfterSamplingFailure()
        }
        settings.recordSamplingRecovered()
        for _ in 0..<AuthorizedPowerSettings.maximumFailedRestarts {
            let restarted = await settings.restartAfterSamplingFailure()
            XCTAssertTrue(restarted)
        }
        XCTAssertTrue(settings.requested)
        XCTAssertFalse(settings.unavailable)
    }

    @MainActor
    func testAutomaticRecoveryDoesNotOverrideAManualShutdown() async {
        let suite = "PowerRecoverySettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PowerSamplingService.enabledKey)
        let service = RecoveryPowerTestService()
        let settings = AuthorizedPowerSettings(defaults: defaults, service: service, pinnedHelperIdentity: { nil })
        settings.setEnabled(false)
        let attempted = await settings.restartAfterSamplingFailure()
        XCTAssertFalse(attempted)
        await waitForSettingsChange(settings)
        XCTAssertEqual(service.registrations, 0)
        XCTAssertFalse(settings.requested)
        XCTAssertFalse(settings.unavailable)
    }

    func testDeferredRestartDoesNotStartPostRestartDeadline() {
        var recovery = AuthorizedPowerRecovery(gracePeriod: 1)
        let start = Date()
        XCTAssertFalse(recovery.observe(PowerSamplingResponse(), now: start))
        XCTAssertTrue(recovery.observe(PowerSamplingResponse(), now: start.addingTimeInterval(1)))
        XCTAssertTrue(recovery.observe(PowerSamplingResponse(), now: start.addingTimeInterval(2)))
        recovery.markRestarted(now: start.addingTimeInterval(5))
        XCTAssertFalse(recovery.observe(PowerSamplingResponse(), now: start.addingTimeInterval(6.5)))
        XCTAssertTrue(recovery.observe(PowerSamplingResponse(), now: start.addingTimeInterval(7)))
    }

    @MainActor
    func testManualDisableUpdatesSwitchImmediatelyAndUnregistersService() async {
        let suite = "PowerRecoverySettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PowerSamplingService.enabledKey)
        let service = RecoveryPowerTestService()
        let settings = AuthorizedPowerSettings(defaults: defaults, service: service, pinnedHelperIdentity: { nil })

        settings.setEnabled(false)
        XCTAssertFalse(settings.requested)
        XCTAssertFalse(defaults.bool(forKey: PowerSamplingService.enabledKey))
        await waitForSettingsChange(settings)
        XCTAssertEqual(service.unregistrations, 1)
        XCTAssertEqual(settings.status, .notRegistered)

        settings.setEnabled(true)
        await waitForSettingsChange(settings)
        XCTAssertTrue(settings.requested)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(settings.status, .enabled)
    }

    @MainActor
    func testManualDisableStaysOffWhenUnregisterFails() async {
        let suite = "PowerRecoverySettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PowerSamplingService.enabledKey)
        let service = RecoveryPowerTestService()
        service.failsRemoval = true
        let settings = AuthorizedPowerSettings(defaults: defaults, service: service, pinnedHelperIdentity: { nil })
        settings.setEnabled(false)
        await waitForSettingsChange(settings)
        XCTAssertFalse(settings.requested)
        XCTAssertFalse(defaults.bool(forKey: PowerSamplingService.enabledKey))
        XCTAssertNotNil(settings.errorMessage)
    }

    @MainActor
    private func waitForSettingsChange(_ settings: AuthorizedPowerSettings) async {
        for _ in 0..<100 {
            if !settings.isChanging { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Settings change did not finish")
    }

    func testEnginePublishesFinalReportBeforeProcessExit() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try report.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = PowerSamplingEngine(makeProcess: {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/cat")
            process.arguments = [file.path]
            return process
        })
        defer { engine.stop() }
        _ = await poll(engine)
        var reading: AuthorizedPowerReading?
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 25_000_000)
            reading = await poll(engine).reading
            if reading != nil { break }
        }
        XCTAssertEqual(reading?.cpuWatts, 23.527)
    }

    func testEngineContinuesAcrossManyCompletedBatches() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try report.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let launched = expectation(description: "twenty batches restart after EOF and exit")
        launched.expectedFulfillmentCount = 20
        let engine = PowerSamplingEngine(makeProcess: {
            launched.fulfill()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/cat")
            process.arguments = [file.path]
            return process
        })
        let polling = Task {
            for _ in 0..<200 {
                if Task.isCancelled { break }
                _ = await self.poll(engine)
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        await fulfillment(of: [launched], timeout: 6)
        polling.cancel()
        await polling.value
        engine.stop()
    }

    func testStopTerminatesChildAndCannotRestartIt() async throws {
        let child = sleeper()
        let engine = PowerSamplingEngine(makeProcess: { child })
        _ = await poll(engine)
        XCTAssertTrue(child.isRunning)
        await withCheckedContinuation { continuation in engine.stop { continuation.resume() } }
        let stoppedResponse = await poll(engine)
        XCTAssertEqual(stoppedResponse.failure, .stopped)
        try await waitForExit(child)
        XCTAssertFalse(child.isRunning)
    }

    func testExpiredLeaseTerminatesChildWithoutAnotherClientMessage() async throws {
        let child = sleeper()
        let engine = PowerSamplingEngine(leaseDuration: 0.1, makeProcess: { child })
        defer { engine.stop() }
        _ = await poll(engine)
        try await waitForExit(child)
        XCTAssertFalse(child.isRunning)
    }

    func testHungProcessTimesOutEvenWhileClientKeepsPolling() async throws {
        let child = sleeper()
        let engine = PowerSamplingEngine(leaseDuration: 10, processTimeout: 0.1, makeProcess: { child })
        defer { engine.stop() }
        _ = await poll(engine)
        for _ in 0..<80 {
            if !child.isRunning { break }
            _ = await poll(engine)
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(child.isRunning)
    }

    func testFailedProcessIsUnavailable() async throws {
        let engine = PowerSamplingEngine(makeProcess: {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/false")
            return process
        })
        defer { engine.stop() }
        _ = await poll(engine)
        var response = PowerSamplingResponse()
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 25_000_000)
            response = await poll(engine)
            if response.failure != nil { break }
        }
        XCTAssertEqual(response.failure, .samplingFailed)
        XCTAssertNil(response.reading)
    }

    func testSuccessfulProcessWithoutAReportIsUnavailable() async throws {
        let engine = PowerSamplingEngine(makeProcess: {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            return process
        })
        defer { engine.stop() }
        _ = await poll(engine)
        var response = PowerSamplingResponse()
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 25_000_000)
            response = await poll(engine)
            if response.failure != nil { break }
        }
        XCTAssertEqual(response.failure, .samplingFailed)
        XCTAssertNil(response.reading)
    }

    func testMatchingNativeCodeIdentityCanUseTheXPCProtocol() async throws {
        let replied = expectation(description: "approved peer receives a reply")
        let delegate = AcceptPowerTestPeer()
        let listener = NSXPCListener.anonymous()
        listener.setConnectionCodeSigningRequirement(try PowerSamplingIdentity.requirement(for: Bundle.main.bundleURL))
        listener.delegate = delegate
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: PowerSamplingXPCProtocol.self)
        connection.setCodeSigningRequirement(try PowerSamplingIdentity.requirement(for: Bundle.main.bundleURL))
        connection.resume()
        defer { connection.invalidate(); listener.invalidate() }
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail(error.localizedDescription)
            replied.fulfill()
        } as? PowerSamplingXPCProtocol
        proxy?.poll { data in
            XCTAssertNotNil(try? JSONDecoder().decode(PowerSamplingResponse.self, from: data))
            replied.fulfill()
        }
        await fulfillment(of: [replied], timeout: 3)
    }

    func testProviderUsesAuthorizedReadingThenStopsClient() async {
        let received = expectation(description: "authorized power source selected")
        let client = PowerTestClient()
        let provider = DarwinChipPowerProvider(
            authorizedModeEnabled: { true }, authorizedSamplerFactory: { client }
        )
        provider.onUpdate = { snapshot in
            XCTAssertEqual(snapshot.source, .systemPowermetrics)
            XCTAssertEqual(snapshot.cpuWatts, 23.527)
            provider.onUpdate = nil
            received.fulfill()
        }
        provider.start(interval: 1)
        await fulfillment(of: [received], timeout: 3)
        provider.stop()
        XCTAssertTrue(client.didStop)
    }

    func testXPCRejectsUnrelatedCodeIdentityBeforeDelegate() async {
        let rejected = expectation(description: "native XPC identity rejects the peer")
        let delegate = RejectUnexpectedPowerPeer()
        let listener = NSXPCListener.anonymous()
        listener.setConnectionCodeSigningRequirement("identifier \"com.youtonghy.toolbox.not-this-test-host\"")
        listener.delegate = delegate
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: PowerSamplingXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate(); listener.invalidate() }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in rejected.fulfill() } as? PowerSamplingXPCProtocol
        proxy?.poll { _ in XCTFail("An unrelated identity must not receive power data") }
        await fulfillment(of: [rejected], timeout: 3)
        XCTAssertFalse(delegate.wasCalled)
    }

    func testPinnedCDHashMatchesTheSignatureOfUnteamedCode() throws {
        let host = Bundle.main.bundleURL
        var code: SecStaticCode?
        var information: CFDictionary?
        XCTAssertEqual(SecStaticCodeCreateWithPath(host as CFURL, [], &code), errSecSuccess)
        XCTAssertEqual(SecCodeCopySigningInformation(
            try XCTUnwrap(code), SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ), errSecSuccess)
        let values = try XCTUnwrap(information as? [String: Any])
        let pinned = PowerSamplingIdentity.pinnedCDHash(for: host)
        if values[kSecCodeInfoTeamIdentifier as String] != nil {
            XCTAssertNil(pinned)
        } else {
            let hash = try XCTUnwrap(values[kSecCodeInfoUnique as String] as? Data)
            XCTAssertEqual(pinned, hash.map { String(format: "%02x", $0) }.joined())
        }
        XCTAssertNil(PowerSamplingIdentity.pinnedCDHash(for: URL(fileURLWithPath: "/nonexistent/ToolBox.app")))
    }

    func testHelperExecutableIdentityDetectsReplacedOrRemovedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("ToolBoxPowerHelper")
        try Data("old".utf8).write(to: executable)
        let launched = try XCTUnwrap(ExecutableFileIdentity(path: executable.path))
        XCTAssertEqual(ExecutableFileIdentity(path: executable.path), launched)

        // An app update installs a new file at the same path, even with the same bytes.
        let update = directory.appendingPathComponent("update")
        try Data("old".utf8).write(to: update)
        _ = try FileManager.default.replaceItemAt(executable, withItemAt: update)
        XCTAssertNotEqual(ExecutableFileIdentity(path: executable.path), launched)

        try FileManager.default.removeItem(at: executable)
        XCTAssertNil(ExecutableFileIdentity(path: executable.path))
    }

    private func poll(_ engine: PowerSamplingEngine) async -> PowerSamplingResponse {
        await withCheckedContinuation { continuation in engine.poll { continuation.resume(returning: $0) } }
    }

    private func sleeper() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        return process
    }

    private func waitForExit(_ process: Process) async throws {
        for _ in 0..<80 {
            if !process.isRunning { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        process.terminate()
    }
}

private final class RejectUnexpectedPowerPeer: NSObject, NSXPCListenerDelegate {
    private let lock = NSLock()
    private var called = false
    var wasCalled: Bool { lock.lock(); defer { lock.unlock() }; return called }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        called = true
        return false
    }
}

private final class AcceptPowerTestPeer: NSObject, NSXPCListenerDelegate, PowerSamplingXPCProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: PowerSamplingXPCProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    func poll(withReply reply: @escaping (Data) -> Void) {
        reply((try? JSONEncoder().encode(PowerSamplingResponse())) ?? Data())
    }
    func stop(withReply reply: @escaping () -> Void) { reply() }
}

private final class PowerTestClient: AuthorizedPowerSampling {
    private let lock = NSLock()
    private var stopped = false
    var didStop: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func response() -> PowerSamplingResponse {
        PowerSamplingResponse(reading: AuthorizedPowerReading(
            timestamp: Date(), interval: 1, cpuWatts: 23.527, gpuWatts: 0.054,
            aneWatts: 0, combinedWatts: 23.582
        ))
    }
    func suspend() {}
    func restart() {}
    func stop() { lock.lock(); defer { lock.unlock() }; stopped = true }
}

private final class RecoveryPowerTestClient: AuthorizedPowerSampling {
    private let lock = NSLock()
    private let recoversAfterRestart: Bool
    private var restartCount = 0
    private var suspensionCount = 0
    private var stopped = false
    var onRestart: ((Int) -> Void)?
    var restarts: Int { lock.lock(); defer { lock.unlock() }; return restartCount }
    var suspensions: Int { lock.lock(); defer { lock.unlock() }; return suspensionCount }
    var didStop: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    init(recoversAfterRestart: Bool) { self.recoversAfterRestart = recoversAfterRestart }

    func response() -> PowerSamplingResponse {
        guard recoversAfterRestart, restarts > 0 else { return PowerSamplingResponse() }
        return PowerSamplingResponse(reading: AuthorizedPowerReading(
            timestamp: Date(), interval: 1, cpuWatts: 0, gpuWatts: nil, aneWatts: nil, combinedWatts: nil
        ))
    }
    func suspend() { lock.lock(); defer { lock.unlock() }; suspensionCount += 1 }
    func restart() {
        lock.lock()
        restartCount += 1
        let count = restartCount
        lock.unlock()
        onRestart?(count)
    }
    func stop() { lock.lock(); defer { lock.unlock() }; stopped = true }
}

private final class RecoveryPowerTestService: AuthorizedPowerServicing {
    var status: SMAppService.Status = .enabled
    var registrations = 0
    var unregistrations = 0
    var failsRemoval = false

    func register() throws { registrations += 1; status = .enabled }
    func unregister() async throws {
        unregistrations += 1
        if failsRemoval { throw NSError(domain: "PowerRecoveryTests", code: 1) }
        status = .notRegistered
    }
}
