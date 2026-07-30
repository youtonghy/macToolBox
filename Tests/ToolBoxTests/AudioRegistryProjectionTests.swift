import CoreAudio
import XCTest
@testable import ToolBox

final class AudioRegistryProjectionTests: XCTestCase {
    @MainActor
    func testCoreAudioRegistryQueriesRunOutsideMainActor() async {
        let executor = CoreAudioRegistryQueryExecutor()

        let ranOnMainThread = await executor.run { Thread.isMainThread }

        XCTAssertFalse(ranOnMainThread)
    }

    func testProcessRegistryWaitsForNewHALProcessesToSettle() {
        XCTAssertEqual(AudioProcessRegistry.processListSettleDelay, .seconds(5))
    }

    func testDeviceRegistryWaitsForRouteConfigurationToSettle() {
        XCTAssertEqual(AudioDeviceRegistry.routeSettleDelay, .seconds(1))
    }

    func testRouteConfigurationTrackerIgnoresDuplicateHALNotifications() {
        var tracker = AudioDeviceRouteConfigurationTracker()
        let initial = AudioDeviceRouteConfiguration(
            defaultOutputUID: "headset",
            devices: [
                HALAudioDeviceRouteSignature(
                    objectID: 42,
                    uid: "headset",
                    isAlive: true,
                    streamIDs: [7],
                    streamFormats: []
                )
            ]
        )

        XCTAssertFalse(tracker.observe(initial))
        XCTAssertFalse(tracker.observe(initial))

        let changed = AudioDeviceRouteConfiguration(
            defaultOutputUID: "headset",
            devices: [
                HALAudioDeviceRouteSignature(
                    objectID: 42,
                    uid: "headset",
                    isAlive: true,
                    streamIDs: [8],
                    streamFormats: []
                )
            ]
        )
        XCTAssertTrue(tracker.observe(changed))
        XCTAssertFalse(tracker.observe(changed))
    }

    func testOnlyBluetoothTransportUsesImmediateRouteSuspension() {
        XCTAssertTrue(
            HALAudioDeviceRecord(
                uid: "headset",
                name: "Headset",
                hasOutput: true,
                transportType: kAudioDeviceTransportTypeBluetooth
            ).isBluetooth
        )
        XCTAssertTrue(
            HALAudioDeviceRecord(
                uid: "headset-le",
                name: "Headset LE",
                hasOutput: true,
                transportType: kAudioDeviceTransportTypeBluetoothLE
            ).isBluetooth
        )
        XCTAssertFalse(
            HALAudioDeviceRecord(
                uid: "usb-dac",
                name: "USB DAC",
                hasOutput: true,
                transportType: kAudioDeviceTransportTypeUSB
            ).isBluetooth
        )
    }

    func testBluetoothRouteSuspensionIsIdempotentUntilStableRecovery() throws {
        let devices = [
            AudioOutputDevice(
                uid: "headset",
                name: "Headset",
                isAvailable: true,
                sampleRate: 44_100
            )
        ]

        let suspended = try XCTUnwrap(
            AudioDeviceRegistry.suspendingBluetoothRoute(in: devices, uid: "headset")
        )
        XCTAssertEqual(suspended[0].compatibilityIssue, .bluetoothProfileChanging)
        XCTAssertNil(suspended[0].sampleRate)
        XCTAssertNil(AudioDeviceRegistry.suspendingBluetoothRoute(in: suspended, uid: "headset"))
    }

    @MainActor
    func testAppIconResolverReusesRenderedImage() {
        let first = AppIconResolver.icon(for: "com.example.missing-app", pointSize: 24)
        let second = AppIconResolver.icon(for: "com.example.missing-app", pointSize: 24)

        XCTAssertTrue(first === second)
    }

    func testDisplayNameCacheLoadsBundleMetadataOncePerProcessAndURL() {
        var loadCount = 0
        let cache = AudioProcessDisplayNameCache { _ in
            loadCount += 1
            return "Cached Name"
        }
        let bundleURL = URL(fileURLWithPath: "/Applications/Example.app")

        XCTAssertEqual(
            cache.preferredDisplayName(
                pid: 42,
                bundleURL: bundleURL,
                bundleID: "com.example.app",
                workspaceName: "Example"
            ),
            "Cached Name"
        )
        XCTAssertEqual(
            cache.preferredDisplayName(
                pid: 42,
                bundleURL: bundleURL,
                bundleID: "com.example.app",
                workspaceName: "Changed"
            ),
            "Cached Name"
        )
        XCTAssertEqual(loadCount, 1)
    }

    func testRegistrySessionRejectsEventsAfterStopAndRestart() throws {
        var session = AudioRegistrySession()
        let first = try XCTUnwrap(session.start())

        XCTAssertTrue(session.accepts(first))
        XCTAssertNil(session.start())

        session.stop()
        XCTAssertFalse(session.accepts(first))

        let second = try XCTUnwrap(session.start())
        XCTAssertNotEqual(second, first)
        XCTAssertFalse(session.accepts(first))
        XCTAssertTrue(session.accepts(second))
    }

    func testPartialHALReadKeepsValidObjectsWhenOneDisappears() {
        enum ReadError: Error { case disappeared }

        let result = CoreAudioPropertyReader.readAvailableObjects([1, 2, 3]) { id in
            if id == 2 { throw ReadError.disappeared }
            return "device-\(id)"
        }

        XCTAssertEqual(result.objects.map(\.id), [1, 3])
        XCTAssertEqual(result.objects.map(\.value), ["device-1", "device-3"])
        XCTAssertEqual(result.failureCount, 1)
    }

    @MainActor
    func testRegistryEventCoalescerRunsOnlyLatestAction() async throws {
        let coalescer = AudioRegistryEventCoalescer(delay: .milliseconds(10))
        var values: [Int] = []

        coalescer.schedule { values.append(1) }
        coalescer.schedule { values.append(2) }
        coalescer.schedule { values.append(3) }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(values, [3])
    }

    @MainActor
    func testRegistryEventCoalescerRunsWithinMaximumDelayDuringSustainedChurn() async throws {
        let coalescer = AudioRegistryEventCoalescer(
            delay: .milliseconds(100),
            maximumDelay: .milliseconds(120)
        )
        var runCount = 0

        // A pure debounce would keep deferring for as long as events keep arriving.
        for _ in 0..<10 {
            coalescer.schedule { runCount += 1 }
            try await Task.sleep(for: .milliseconds(30))
        }

        XCTAssertGreaterThanOrEqual(runCount, 1)
    }

    @MainActor
    func testRegistryEventCoalescerWithoutMaximumDelayWaitsForChurnToSettle() async throws {
        let coalescer = AudioRegistryEventCoalescer(delay: .milliseconds(60))
        var runCount = 0

        for _ in 0..<10 {
            coalescer.schedule { runCount += 1 }
            try await Task.sleep(for: .milliseconds(30))
        }

        XCTAssertEqual(runCount, 0)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(runCount, 1)
    }

    @MainActor
    func testRegistryEventCoalescerCancellationDropsPendingAction() async throws {
        let coalescer = AudioRegistryEventCoalescer(delay: .milliseconds(10))
        var didRun = false

        coalescer.schedule { didRun = true }
        coalescer.cancel()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(didRun)
    }

    func testProcessProjectionDropsRecordsWithoutStableBundleID() {
        let records = [
            HALAudioProcessRecord(objectID: 1, pid: 11, bundleID: "us.zoom.xos", name: "Zoom", isRunningOutput: true),
            HALAudioProcessRecord(objectID: 2, pid: 12, bundleID: "", name: "Helper", isRunningOutput: true)
        ]

        XCTAssertEqual(AudioProcessRegistry.project(records: records).map(\.bundleID), ["us.zoom.xos"])
    }

    func testProcessProjectionDropsIgnoredSystemDaemons() {
        let records = [
            HALAudioProcessRecord(
                objectID: 1, pid: 11, bundleID: "com.xingin.discover", name: "小红书", isRunningOutput: false
            ),
            HALAudioProcessRecord(
                objectID: 2, pid: 12, bundleID: "com.apple.audiomxd", name: "audiomxd", isRunningOutput: true
            ),
            HALAudioProcessRecord(
                objectID: 3, pid: 13, bundleID: "systemsoundserverd", name: "systemsoundserverd", isRunningOutput: true
            )
        ]

        XCTAssertEqual(
            AudioProcessRegistry.project(records: records).map(\.bundleID),
            ["com.xingin.discover"]
        )
    }

    func testProcessIdentityRecoversEmptyHALBundleIDFromWorkspace() {
        let resolved = AudioProcessIdentity.resolveBundleID(
            halBundleID: "",
            pid: 1,
            workspaceBundleID: "com.xingin.discover"
        )
        XCTAssertEqual(resolved, "com.xingin.discover")
        XCTAssertEqual(
            AudioProcessIdentity.resolveBundleID(
                halBundleID: "com.spotify.client",
                pid: 2,
                workspaceBundleID: "ignored"
            ),
            "com.spotify.client"
        )
    }

    func testProcessProjectionKeepsSilentAppsForListing() {
        let records = [
            HALAudioProcessRecord(
                objectID: 1, pid: 11, bundleID: "com.xingin.discover", name: "小红书", isRunningOutput: false
            ),
            HALAudioProcessRecord(
                objectID: 2, pid: 12, bundleID: "com.spotify.client", name: "Spotify", isRunningOutput: true
            )
        ]

        let projected = AudioProcessRegistry.project(records: records)
        let projectedByBundleID = Dictionary(uniqueKeysWithValues: projected.map { ($0.bundleID, $0) })
        XCTAssertEqual(Set(projected.map(\.bundleID)), ["com.spotify.client", "com.xingin.discover"])
        XCTAssertEqual(projectedByBundleID["com.spotify.client"]?.isRunningOutput, true)
        XCTAssertEqual(projectedByBundleID["com.xingin.discover"]?.isRunningOutput, false)
    }

    func testProcessProjectionTreatsIsRunningAsHALActive() {
        let records = [
            HALAudioProcessRecord(
                objectID: 1,
                pid: 11,
                bundleID: "com.spotify.client",
                name: "Spotify",
                isRunningOutput: false,
                isRunning: true
            ),
            HALAudioProcessRecord(
                objectID: 2,
                pid: 12,
                bundleID: "com.apple.Music",
                name: "Music",
                isRunningOutput: false,
                isRunning: false
            )
        ]

        let projected = AudioProcessRegistry.project(records: records)
        let projectedByBundleID = Dictionary(uniqueKeysWithValues: projected.map { ($0.bundleID, $0) })
        XCTAssertEqual(projected.map(\.bundleID), ["com.apple.Music", "com.spotify.client"])
        XCTAssertEqual(projectedByBundleID["com.spotify.client"]?.isHALActive, true)
        XCTAssertEqual(projectedByBundleID["com.apple.Music"]?.isHALActive, false)
        XCTAssertTrue(try XCTUnwrap(projectedByBundleID["com.spotify.client"]).isRunning)
        XCTAssertFalse(try XCTUnwrap(projectedByBundleID["com.spotify.client"]).isRunningOutput)
    }

    func testProcessProjectionOrderDoesNotDependOnActivityFlags() {
        let initiallyActiveZulu = [
            HALAudioProcessRecord(
                objectID: 1,
                pid: 11,
                bundleID: "com.example.alpha",
                name: "Alpha",
                isRunningOutput: false
            ),
            HALAudioProcessRecord(
                objectID: 2,
                pid: 12,
                bundleID: "com.example.zulu",
                name: "Zulu",
                isRunningOutput: true
            )
        ]
        let laterActiveAlpha = [
            HALAudioProcessRecord(
                objectID: 1,
                pid: 11,
                bundleID: "com.example.alpha",
                name: "Alpha",
                isRunningOutput: true
            ),
            HALAudioProcessRecord(
                objectID: 2,
                pid: 12,
                bundleID: "com.example.zulu",
                name: "Zulu",
                isRunningOutput: false
            )
        ]

        XCTAssertEqual(
            AudioProcessRegistry.project(records: initiallyActiveZulu).map(\.bundleID),
            ["com.example.alpha", "com.example.zulu"]
        )
        XCTAssertEqual(
            AudioProcessRegistry.project(records: laterActiveAlpha).map(\.bundleID),
            ["com.example.alpha", "com.example.zulu"]
        )
    }

    func testActivityPatchUpdatesOnlyTargetWithoutReorderingSnapshot() throws {
        let snapshots = [
            AudioProcessSnapshot(
                objectID: 1,
                pid: 11,
                bundleID: "com.example.alpha",
                name: "Alpha",
                isRunningOutput: false
            ),
            AudioProcessSnapshot(
                objectID: 2,
                pid: 12,
                bundleID: "com.example.zulu",
                name: "Zulu",
                isRunningOutput: true
            )
        ]

        let updated = try XCTUnwrap(
            AudioProcessRegistry.updatingActivity(
                in: snapshots,
                objectID: 1,
                isRunning: true,
                isRunningOutput: false
            )
        )

        XCTAssertEqual(updated.map(\.bundleID), ["com.example.alpha", "com.example.zulu"])
        XCTAssertTrue(updated[0].isRunning)
        XCTAssertEqual(updated[1], snapshots[1])
    }

    func testActivityPatchReturnsNilForUnknownOrFilteredObject() {
        let snapshots = [
            AudioProcessSnapshot(
                objectID: 1,
                pid: 11,
                bundleID: "com.example.alpha",
                name: "Alpha",
                isRunningOutput: false
            )
        ]

        XCTAssertNil(
            AudioProcessRegistry.updatingActivity(
                in: snapshots,
                objectID: 99,
                isRunning: true,
                isRunningOutput: true
            )
        )
    }

    func testAppListVisibilityKeepsRecentlyActiveApps() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(
            AudioAppListVisibility.shouldShow(
                isHALActive: false,
                isRouteActive: false,
                hasSavedRule: false,
                lastActiveAt: now.addingTimeInterval(-5),
                now: now,
                recentlyActiveWindow: 12
            )
        )
        XCTAssertFalse(
            AudioAppListVisibility.shouldShow(
                isHALActive: false,
                isRouteActive: false,
                hasSavedRule: false,
                lastActiveAt: now.addingTimeInterval(-20),
                now: now,
                recentlyActiveWindow: 12
            )
        )
        XCTAssertTrue(
            AudioAppListVisibility.shouldShow(
                isHALActive: false,
                isRouteActive: false,
                hasSavedRule: true,
                lastActiveAt: nil,
                now: now
            )
        )
    }

    func testDeviceProjectionKeepsRememberedUnavailableDevice() {
        let records = [HALAudioDeviceRecord(uid: "speakers", name: "Speakers", hasOutput: true)]

        let devices = AudioDeviceRegistry.project(records: records, rememberedUIDs: ["headset"])

        XCTAssertEqual(devices.map(\.uid), ["headset", "speakers"])
        XCTAssertFalse(devices[0].isAvailable)
        XCTAssertTrue(devices[1].isAvailable)
    }

    func testDeviceProjectionDropsInputOnlyDevices() {
        let records = [
            HALAudioDeviceRecord(uid: "mic", name: "Microphone", hasOutput: false),
            HALAudioDeviceRecord(uid: "output", name: "Output", hasOutput: true)
        ]

        XCTAssertEqual(AudioDeviceRegistry.project(records: records, rememberedUIDs: []).map(\.uid), ["output"])
    }

    func testDeviceProjectionMarksDeadOutputAsUnavailable() {
        let records = [
            HALAudioDeviceRecord(
                uid: "headset",
                name: "Headset",
                hasOutput: true,
                isAlive: false
            )
        ]

        let device = AudioDeviceRegistry.project(records: records, rememberedUIDs: []).first

        XCTAssertEqual(device?.uid, "headset")
        XCTAssertEqual(device?.isAvailable, false)
        XCTAssertEqual(device?.isRoutable, false)
    }

    func testOnlySystemDefaultOutputEventDirectlyInvalidatesAudioRoutes() {
        let defaultOutput = AudioDeviceRegistry.eventEffects(
            for: [kAudioHardwarePropertyDefaultOutputDevice]
        )
        let deviceList = AudioDeviceRegistry.eventEffects(for: [kAudioHardwarePropertyDevices])
        let serviceRestart = AudioDeviceRegistry.eventEffects(
            for: [kAudioHardwarePropertyServiceRestarted]
        )

        XCTAssertTrue(defaultOutput.routeConfigurationChanged)
        XCTAssertFalse(deviceList.routeConfigurationChanged)
        XCTAssertFalse(serviceRestart.routeConfigurationChanged)
        XCTAssertTrue(serviceRestart.serviceRestarted)
    }

    func testOnlyDefaultAndRuleReferencedDevicesReceiveRouteListeners() {
        let records = [
            HALAudioDeviceRecord(uid: "speakers", name: "Speakers", hasOutput: true),
            HALAudioDeviceRecord(uid: "headset", name: "Headset", hasOutput: true),
            HALAudioDeviceRecord(uid: "unrelated-hdmi", name: "Display", hasOutput: true)
        ]

        XCTAssertEqual(
            AudioDeviceRegistry.monitoredUIDs(
                records: records,
                defaultOutputUID: "speakers",
                rememberedUIDs: ["headset"]
            ),
            ["speakers", "headset"]
        )
    }


    func testDeadRememberedDeviceKeepsAliveListenerForRecovery() {
        let records = [
            HALAudioDeviceRecord(
                uid: "headset",
                name: "Headset",
                hasOutput: true,
                isAlive: false
            )
        ]

        XCTAssertEqual(
            AudioDeviceRegistry.monitoredUIDs(
                records: records,
                defaultOutputUID: "headset",
                rememberedUIDs: ["headset"]
            ),
            ["headset"]
        )
    }
}
