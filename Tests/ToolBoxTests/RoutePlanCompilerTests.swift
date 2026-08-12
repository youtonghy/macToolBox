import XCTest
@testable import ToolBox

final class RoutePlanCompilerTests: XCTestCase {
    func testDefaultPolicyRejectsToolBoxSelfCapture() {
        let compilation = RoutePlanCompiler.compile(
            rules: [AppAudioRule(bundleID: "com.youtonghy.toolbox", volumePercent: 150)],
            processes: [
                AudioProcessSnapshot(
                    objectID: 99,
                    pid: 999,
                    bundleID: "com.youtonghy.toolbox",
                    name: "ToolBox",
                    isRunningOutput: true
                )
            ],
            devices: [AudioOutputDevice(uid: "speakers", name: "Speakers", isAvailable: true)],
            defaultOutputUID: "speakers"
        )

        XCTAssertTrue(compilation.plans.isEmpty)
        XCTAssertEqual(
            compilation.resolutions,
            [
                AudioRuleResolution(
                    bundleID: "com.youtonghy.toolbox",
                    state: .rejected(.excludedProcess(objectID: 99))
                )
            ]
        )
    }

    private let processes = [
        AudioProcessSnapshot(
            objectID: 42,
            pid: 1234,
            bundleID: "us.zoom.xos",
            name: "zoom.us",
            isRunningOutput: true
        )
    ]
    private let devices = [
        AudioOutputDevice(uid: "speakers", name: "MacBook Speakers", isAvailable: true),
        AudioOutputDevice(uid: "headset", name: "USB Headset", isAvailable: true)
    ]

    func testNativeRuleOnDefaultOutputDoesNotCreateTap() {
        let plans = RoutePlanCompiler.compile(
            rules: [AppAudioRule(bundleID: "us.zoom.xos")],
            processes: processes,
            devices: devices,
            defaultOutputUID: "speakers"
        ).plans

        XCTAssertEqual(plans, [])
    }

    func testGainOverrideCreatesRouteOnDefaultDevice() {
        let plans = RoutePlanCompiler.compile(
            rules: [AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 300)],
            processes: processes,
            devices: devices,
            defaultOutputUID: "speakers"
        ).plans

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].outputDeviceUID, "speakers")
        XCTAssertEqual(plans[0].sources[0].processObjectID, 42)
        XCTAssertEqual(plans[0].sources[0].linearGain, 3.0, accuracy: 0.0001)
    }

    func testOutputOverrideCreatesRouteAtNativeGain() {
        let plans = RoutePlanCompiler.compile(
            rules: [
                AppAudioRule(
                    bundleID: "us.zoom.xos",
                    volumePercent: 100,
                    outputDeviceUID: "headset"
                )
            ],
            processes: processes,
            devices: devices,
            defaultOutputUID: "speakers"
        ).plans

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].outputDeviceUID, "headset")
        XCTAssertEqual(plans[0].sources[0].linearGain, 1.0, accuracy: 0.0001)
    }

    func testUnavailableSelectedDeviceFallsBackWithoutCreatingRedundantTap() {
        let plans = RoutePlanCompiler.compile(
            rules: [
                AppAudioRule(
                    bundleID: "us.zoom.xos",
                    outputDeviceUID: "missing-headset"
                )
            ],
            processes: processes,
            devices: devices,
            defaultOutputUID: "speakers"
        ).plans

        XCTAssertEqual(plans, [])
    }

    func testExistingSilentProcessWaitsForOutputBeforeCreatingGainRoute() {
        let silent = [
            AudioProcessSnapshot(
                objectID: 42,
                pid: 1234,
                bundleID: "us.zoom.xos",
                name: "zoom.us",
                isRunningOutput: false
            )
        ]

        let compilation = RoutePlanCompiler.compile(
            rules: [AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 200)],
            processes: silent,
            devices: devices,
            defaultOutputUID: "speakers"
        )

        XCTAssertEqual(compilation.plans, [])
        XCTAssertEqual(
            compilation.resolutions,
            [
                AudioRuleResolution(
                    bundleID: "us.zoom.xos",
                    state: .waiting(.processNotProducingOutput)
                )
            ]
        )
    }

    func testMultipleProcessesForOneBundleShareTheSameDevicePlan() {
        let helper = AudioProcessSnapshot(
            objectID: 43,
            pid: 1235,
            bundleID: "us.zoom.xos",
            name: "Zoom Helper",
            isRunningOutput: true
        )

        let plans = RoutePlanCompiler.compile(
            rules: [AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 150)],
            processes: processes + [helper],
            devices: devices,
            defaultOutputUID: "speakers"
        ).plans

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].sources.map(\.processObjectID), [42, 43])
        XCTAssertEqual(plans[0].sources.map(\.linearGain), [1.5, 1.5])
    }

    func testGainRouteFiltersInactiveSiblingProcesses() {
        let helper = AudioProcessSnapshot(
            objectID: 43,
            pid: 1235,
            bundleID: "us.zoom.xos",
            name: "Zoom Helper",
            isRunningOutput: false
        )

        let plans = RoutePlanCompiler.compile(
            rules: [AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 150)],
            processes: processes + [helper],
            devices: devices,
            defaultOutputUID: "speakers"
        ).plans

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].sources.map(\.processObjectID), [42])
    }

    func testGainOnlyChangePreservesRouteTopology() {
        let original = AudioRoutePlan(
            outputDeviceUID: "headset",
            sources: [AudioRouteSource(bundleID: "us.zoom.xos", processObjectID: 42, linearGain: 1)]
        )
        let updated = AudioRoutePlan(
            outputDeviceUID: "headset",
            sources: [AudioRouteSource(bundleID: "us.zoom.xos", processObjectID: 42, linearGain: 3)]
        )

        XCTAssertTrue(original.hasSameTopology(as: updated))
    }

    func testDeviceOrProcessChangeDoesNotPreserveRouteTopology() {
        let original = AudioRoutePlan(
            outputDeviceUID: "headset",
            sources: [AudioRouteSource(bundleID: "us.zoom.xos", processObjectID: 42, linearGain: 1)]
        )
        let newDevice = AudioRoutePlan(
            outputDeviceUID: "speakers",
            sources: original.sources
        )
        let newProcess = AudioRoutePlan(
            outputDeviceUID: "headset",
            sources: [AudioRouteSource(bundleID: "us.zoom.xos", processObjectID: 43, linearGain: 1)]
        )

        XCTAssertFalse(original.hasSameTopology(as: newDevice))
        XCTAssertFalse(original.hasSameTopology(as: newProcess))
    }

    func testMissingDefaultOutputReturnsTypedRejection() {
        let compilation = RoutePlanCompiler.compile(
            rules: [AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 200)],
            processes: processes,
            devices: devices,
            defaultOutputUID: nil
        )

        XCTAssertEqual(compilation.plans, [])
        XCTAssertEqual(
            compilation.resolutions,
            [
                AudioRuleResolution(
                    bundleID: "us.zoom.xos",
                    state: .rejected(.missingDefaultOutputDevice)
                )
            ]
        )
    }

    func testUnavailableOutputReturnsDegradedResolution() {
        let compilation = RoutePlanCompiler.compile(
            rules: [
                AppAudioRule(
                    bundleID: "us.zoom.xos",
                    volumePercent: 200,
                    outputDeviceUID: "missing-headset"
                )
            ],
            processes: processes,
            devices: devices,
            defaultOutputUID: "speakers"
        )

        XCTAssertEqual(compilation.plans, [])
        XCTAssertEqual(
            compilation.resolutions,
            [
                AudioRuleResolution(
                    bundleID: "us.zoom.xos",
                    state: .degraded(.outputDeviceUnavailable(uid: "missing-headset"))
                )
            ]
        )
    }

    func testExistingSilentProcessReturnsWaitingResolution() {
        let silent = [
            AudioProcessSnapshot(
                objectID: 42,
                pid: 1234,
                bundleID: "us.zoom.xos",
                name: "zoom.us",
                isRunningOutput: false
            )
        ]

        let compilation = RoutePlanCompiler.compile(
            rules: [AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 200)],
            processes: silent,
            devices: devices,
            defaultOutputUID: "speakers"
        )

        XCTAssertEqual(compilation.plans, [])
        XCTAssertEqual(
            compilation.resolutions,
            [
                AudioRuleResolution(
                    bundleID: "us.zoom.xos",
                    state: .waiting(.processNotProducingOutput)
                )
            ]
        )
    }

    func testNativeRuleReturnsPlannedResolutionWithoutRoute() {
        let compilation = RoutePlanCompiler.compile(
            rules: [AppAudioRule(bundleID: "us.zoom.xos")],
            processes: processes,
            devices: devices,
            defaultOutputUID: "speakers"
        )

        XCTAssertEqual(compilation.plans, [])
        XCTAssertEqual(
            compilation.resolutions,
            [
                AudioRuleResolution(
                    bundleID: "us.zoom.xos",
                    state: .planned(routeID: nil)
                )
            ]
        )
    }

    func testRouteOverNativeSourceCapacityIsRejectedWithoutPartialCapture() {
        let manyProcesses = (0..<33).map { index in
            AudioProcessSnapshot(
                objectID: UInt32(100 + index),
                pid: pid_t(1000 + index),
                bundleID: "us.zoom.xos",
                name: "Zoom Helper \(index)",
                isRunningOutput: true
            )
        }

        let compilation = RoutePlanCompiler.compile(
            rules: [AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 200)],
            processes: manyProcesses,
            devices: devices,
            defaultOutputUID: "speakers"
        )

        XCTAssertEqual(compilation.plans, [])
        XCTAssertEqual(
            compilation.resolutions,
            [
                AudioRuleResolution(
                    bundleID: "us.zoom.xos",
                    state: .rejected(.sourceCapacityExceeded(limit: 32, requested: 33))
                )
            ]
        )
    }

    func testExcludedProcessIsRejectedByCompilationPolicy() {
        let compilation = RoutePlanCompiler.compile(
            rules: [AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 200)],
            processes: processes,
            devices: devices,
            defaultOutputUID: "speakers",
            policy: AudioRouteCompilationPolicy(excludedProcessObjectIDs: [42])
        )

        XCTAssertEqual(compilation.plans, [])
        XCTAssertEqual(
            compilation.resolutions,
            [
                AudioRuleResolution(
                    bundleID: "us.zoom.xos",
                    state: .rejected(.excludedProcess(objectID: 42))
                )
            ]
        )
    }

    func testUnsupportedOutputDeviceIsRejectedBeforeCreatingTap() {
        let compilation = RoutePlanCompiler.compile(
            rules: [
                AppAudioRule(
                    bundleID: "us.zoom.xos",
                    volumePercent: 200,
                    outputDeviceUID: "headset"
                )
            ],
            processes: processes,
            devices: devices,
            defaultOutputUID: "speakers",
            policy: AudioRouteCompilationPolicy(
                unsupportedOutputDeviceReasons: ["headset": "Unsupported channel layout"]
            )
        )

        XCTAssertEqual(compilation.plans, [])
        XCTAssertEqual(
            compilation.resolutions,
            [
                AudioRuleResolution(
                    bundleID: "us.zoom.xos",
                    state: .rejected(
                        .unsupportedOutputDevice(
                            uid: "headset",
                            reason: "Unsupported channel layout"
                        )
                    )
                )
            ]
        )
    }

    func testDeviceCompatibilityIssueIsRejectedBeforeCreatingTap() {
        let incompatibleDevices = [
            AudioOutputDevice(
                uid: "headset",
                name: "USB Headset",
                isAvailable: true,
                compatibilityIssue: .requiresInterleavedStereo
            )
        ]
        let compilation = RoutePlanCompiler.compile(
            rules: [
                AppAudioRule(
                    bundleID: "us.zoom.xos",
                    volumePercent: 200,
                    outputDeviceUID: "headset"
                )
            ],
            processes: processes,
            devices: incompatibleDevices,
            defaultOutputUID: "headset"
        )

        XCTAssertTrue(compilation.plans.isEmpty)
        XCTAssertEqual(
            compilation.resolutions,
            [
                AudioRuleResolution(
                    bundleID: "us.zoom.xos",
                    state: .rejected(
                        .unsupportedOutputDevice(
                            uid: "headset",
                            reason: AudioOutputCompatibilityIssue.requiresInterleavedStereo.message
                        )
                    )
                )
            ]
        )
    }

    func testUnavailableDefaultOutputIsRejectedBeforeNativeStart() {
        let compilation = RoutePlanCompiler.compile(
            rules: [AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 200)],
            processes: processes,
            devices: [AudioOutputDevice(uid: "speakers", name: "Speakers", isAvailable: false)],
            defaultOutputUID: "speakers"
        )

        XCTAssertEqual(compilation.plans, [])
        XCTAssertEqual(
            compilation.resolutions,
            [
                AudioRuleResolution(
                    bundleID: "us.zoom.xos",
                    state: .rejected(.outputDeviceUnavailable(uid: "speakers"))
                )
            ]
        )
    }
}
