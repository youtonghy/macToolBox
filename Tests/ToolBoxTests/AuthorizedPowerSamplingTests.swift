import Foundation
import Security
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
    func stop() { lock.lock(); defer { lock.unlock() }; stopped = true }
}
