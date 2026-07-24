import CoreAudio
import Darwin
import XCTest
@testable import ToolBox

final class AudioRouteLifecycleTests: XCTestCase {
    func testMissingAudioObjectCompletesIOProcTeardown() throws {
        typealias Classifier = @convention(c) (OSStatus, OSStatus) -> UInt32
        let classifier: Classifier = try loadTestSymbol(
            named: "TBAudioIOProcTeardownDisposition",
            as: Classifier.self
        )

        let completedAndCleared: UInt32 = 0b11
        XCTAssertEqual(classifier(noErr, noErr), completedAndCleared)
        XCTAssertEqual(
            classifier(kAudioHardwareNotRunningError, noErr),
            completedAndCleared
        )
        XCTAssertEqual(classifier(kAudioHardwareBadObjectError, noErr), completedAndCleared)
        XCTAssertEqual(classifier(kAudioHardwareBadDeviceError, noErr), completedAndCleared)
        XCTAssertEqual(classifier(noErr, kAudioHardwareBadObjectError), completedAndCleared)
        XCTAssertEqual(classifier(noErr, kAudioHardwareBadDeviceError), completedAndCleared)
        XCTAssertEqual(classifier(kAudioHardwareUnspecifiedError, noErr), 0b10)
        XCTAssertEqual(classifier(noErr, kAudioHardwareUnspecifiedError), 0)
    }

    func testRouteStopResultIgnoresUnrelatedQuarantine() throws {
        typealias Classifier = @convention(c) (Int32, Int32) -> Int32
        let classifier: Classifier = try loadTestSymbol(
            named: "TBAudioRouteStopResult",
            as: Classifier.self
        )

        XCTAssertEqual(classifier(0, 0), 1)
        XCTAssertEqual(classifier(1, 1), 1)
        XCTAssertEqual(classifier(1, 0), 0)
    }

    func testMissingAudioObjectCompletesObjectDestruction() throws {
        typealias Classifier = @convention(c) (OSStatus) -> Bool
        let classifier: Classifier = try loadTestSymbol(
            named: "TBAudioObjectDestructionComplete",
            as: Classifier.self
        )

        XCTAssertTrue(classifier(noErr))
        XCTAssertTrue(classifier(kAudioHardwareBadObjectError))
        XCTAssertTrue(classifier(kAudioHardwareBadDeviceError))
        XCTAssertFalse(classifier(kAudioHardwareUnspecifiedError))
    }

    func testNotReadyRouteSetupErrorsUseABoundedRetryBudget() throws {
        typealias Classifier = @convention(c) (OSStatus, UInt32) -> Bool
        let shouldRetry: Classifier = try loadTestSymbol(
            named: "TBAudioRouteSetupShouldRetry",
            as: Classifier.self
        )

        XCTAssertFalse(shouldRetry(kAudioDeviceUnsupportedFormatError, 0))
        XCTAssertTrue(shouldRetry(kAudioHardwareNotReadyError, 0))
        XCTAssertTrue(shouldRetry(kAudioHardwareNotReadyError, 8))
        XCTAssertFalse(shouldRetry(kAudioHardwareNotReadyError, 9))
        XCTAssertFalse(shouldRetry(kAudioDevicePermissionsError, 0))
        XCTAssertFalse(shouldRetry(kAudioHardwareBadDeviceError, 0))
    }

    func testTapDeviceSelectionPrefersTargetThenUnambiguousProcessDevice() throws {
        typealias Selector = @convention(c) (
            AudioObjectID,
            UnsafePointer<AudioObjectID>?,
            UInt32
        ) -> AudioObjectID
        let selectDevice: Selector = try loadTestSymbol(
            named: "TBAudioSelectTapDevice",
            as: Selector.self
        )

        var devices: [AudioObjectID] = [41, 42]
        XCTAssertEqual(selectDevice(42, &devices, UInt32(devices.count)), 42)

        devices = [41]
        XCTAssertEqual(selectDevice(42, &devices, UInt32(devices.count)), 41)

        devices = [41, 43]
        XCTAssertEqual(
            selectDevice(42, &devices, UInt32(devices.count)),
            AudioObjectID(kAudioObjectUnknown)
        )
        XCTAssertEqual(selectDevice(42, nil, 0), AudioObjectID(kAudioObjectUnknown))
    }

    func testDefaultOutputSelectionWaitsForProcessDeviceMigration() throws {
        typealias Classifier = @convention(c) (
            AudioObjectID,
            AudioObjectID,
            UnsafePointer<AudioObjectID>?,
            UInt32,
            UInt32
        ) -> Bool
        let shouldWait: Classifier = try loadTestSymbol(
            named: "TBAudioTapDeviceSelectionShouldWait",
            as: Classifier.self
        )

        var oldDevice: AudioObjectID = 41
        XCTAssertTrue(shouldWait(42, 42, &oldDevice, 1, 0))
        XCTAssertFalse(shouldWait(42, 42, &oldDevice, 1, 9))
        XCTAssertFalse(shouldWait(42, 99, &oldDevice, 1, 0))
        XCTAssertFalse(shouldWait(42, 42, nil, 0, 0))

        var targetDevice: AudioObjectID = 42
        XCTAssertFalse(shouldWait(42, 42, &targetDevice, 1, 0))
    }

    func testDefaultOutputMigrationTimeoutBindsTheNewTargetDevice() throws {
        typealias Selector = @convention(c) (
            AudioObjectID,
            AudioObjectID,
            UnsafePointer<AudioObjectID>?,
            UInt32
        ) -> AudioObjectID
        let selectDevice: Selector = try loadTestSymbol(
            named: "TBAudioSelectTapDeviceAfterMigrationWait",
            as: Selector.self
        )

        var oldDevice: AudioObjectID = 41
        XCTAssertEqual(selectDevice(42, 42, &oldDevice, 1), 42)
        XCTAssertEqual(selectDevice(42, 99, &oldDevice, 1), 41)
    }

    @available(macOS 14.2, *)
    func testInvalidRouteArgumentsDoNotStopExistingRoute() {
        let engine = StopRecordingAudioRouteEngine()

        XCTAssertThrowsError(
            try engine.startRoute(
                withIdentifier: "speakers",
                outputDeviceUID: "device",
                processObjectIDs: [],
                gains: []
            )
        )
        XCTAssertEqual(engine.stoppedRouteIdentifiers, [])
    }

    @available(macOS 14.2, *)
    func testMissingOutputDeviceReportsResolutionStage() {
        let engine = TBAudioRouteEngine()

        XCTAssertThrowsError(
            try engine.startRoute(
                withIdentifier: "missing-output",
                outputDeviceUID: "com.youtonghy.toolbox.tests.missing-output",
                processObjectIDs: [1],
                gains: [1]
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Resolve output device"))
            XCTAssertFalse(error.localizedDescription.contains("Start audio route"))
        }
    }

    @available(macOS 14.2, *)
    func testEngineDeallocationStopsAllRoutes() {
        let recorder = EngineDeallocationRecorder()
        var engine: TBAudioRouteEngine? = DeallocationRecordingAudioRouteEngine(recorder: recorder)

        XCTAssertNotNil(engine)
        engine = nil

        XCTAssertEqual(recorder.stopAllCallCount, 1)
    }

    func testPermanentLeaseArenaReusesRetiredSlots() throws {
        typealias ReuseCheck = @convention(c) (UInt32, UInt32) -> Bool
        let reuseCheck: ReuseCheck = try loadTestSymbol(
            named: "TBAudioCallbackLeaseTestRunPermanentArenaReuse",
            as: ReuseCheck.self
        )

        XCTAssertTrue(reuseCheck(2, 100))
    }

    func testDetachedCallbackLeaseRejectsLateCallbacks() throws {
        let lease = try XCTUnwrap(TBAudioCallbackLeaseTestCreate())
        defer { TBAudioCallbackLeaseTestDestroy(lease) }

        XCTAssertTrue(TBAudioCallbackLeaseTestAcquire(lease))
        XCTAssertEqual(TBAudioCallbackLeaseTestInFlight(lease), 1)

        TBAudioCallbackLeaseTestDetach(lease)

        XCTAssertFalse(TBAudioCallbackLeaseTestAcquire(lease))
        XCTAssertEqual(TBAudioCallbackLeaseTestInFlight(lease), 1)
        TBAudioCallbackLeaseTestRelease(lease)
        XCTAssertEqual(TBAudioCallbackLeaseTestInFlight(lease), 0)
    }

    func testCallbackLeaseRetirementIsStableAcrossOneHundredCycles() throws {
        for _ in 0..<100 {
            let lease = try XCTUnwrap(TBAudioCallbackLeaseTestCreate())
            XCTAssertTrue(TBAudioCallbackLeaseTestAcquire(lease))
            TBAudioCallbackLeaseTestRelease(lease)
            TBAudioCallbackLeaseTestDetach(lease)
            XCTAssertFalse(TBAudioCallbackLeaseTestAcquire(lease))
            XCTAssertEqual(TBAudioCallbackLeaseTestInFlight(lease), 0)
            TBAudioCallbackLeaseTestDestroy(lease)
        }
    }

    func testDetachAndAcquireRaceNeverPublishesContextAfterDetachCompletes() {
        XCTAssertTrue(TBAudioCallbackLeaseTestRunDetachRace(50_000))
    }

    private func loadTestSymbol<Symbol>(named name: String, as _: Symbol.Type) throws -> Symbol {
        let handle = try XCTUnwrap(dlopen(nil, RTLD_NOW))
        let symbol = try XCTUnwrap(dlsym(handle, name), "Missing test symbol \(name)")
        return unsafeBitCast(symbol, to: Symbol.self)
    }
}

@available(macOS 14.2, *)
private final class StopRecordingAudioRouteEngine: TBAudioRouteEngine {
    private(set) var stoppedRouteIdentifiers: [String] = []

    override func stopRoute(withIdentifier identifier: String) -> Bool {
        stoppedRouteIdentifiers.append(identifier)
        return true
    }
}

@available(macOS 14.2, *)
private final class DeallocationRecordingAudioRouteEngine: TBAudioRouteEngine {
    private let recorder: EngineDeallocationRecorder

    init(recorder: EngineDeallocationRecorder) {
        self.recorder = recorder
        super.init()
    }

    override func stopAllRoutes() -> Bool {
        recorder.stopAllCallCount += 1
        return true
    }
}

@available(macOS 14.2, *)
private final class EngineDeallocationRecorder {
    var stopAllCallCount = 0
}
