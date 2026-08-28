import CoreGraphics
import XCTest
@testable import ToolBoxCore

@MainActor
final class DisplayControlMenuModelTests: XCTestCase {
    func testOpenSystemDisplaySettingsReportsSuccess() {
        let opener = RecordingDisplaySettingsOpener(result: true)
        let service = DisplayControlService(provider: RecordingDisplayControlProvider(snapshot: Self.snapshot), timing: .immediateForTests)
        service.setSnapshotForTesting(Self.snapshot)
        let model = DisplayControlMenuModel(service: service, displaySettingsOpener: opener)
        model.start()

        XCTAssertTrue(model.openSystemDisplaySettings())
        XCTAssertEqual(opener.openCount, 1)
        XCTAssertNil(model.systemSettingsErrorText)
    }

    func testOpenSystemDisplaySettingsExposesFailure() {
        let opener = RecordingDisplaySettingsOpener(result: false)
        let service = DisplayControlService(provider: RecordingDisplayControlProvider(snapshot: Self.snapshot), timing: .immediateForTests)
        service.setSnapshotForTesting(Self.snapshot)
        let model = DisplayControlMenuModel(service: service, displaySettingsOpener: opener)

        XCTAssertFalse(model.openSystemDisplaySettings())
        XCTAssertEqual(model.systemSettingsErrorText, "无法打开系统显示设置")
    }

    func testSelectedDisplayStatusDescribesWriteOnlyDDC() {
        let service = DisplayControlService(provider: RecordingDisplayControlProvider(snapshot: Self.snapshot), timing: .immediateForTests)
        service.setSnapshotForTesting(Self.snapshot)
        let model = DisplayControlMenuModel(service: service)
        model.start()

        XCTAssertEqual(model.selectedDisplayStatusText, "DDC 只写 · 当前值为估算")
    }

    func testCanceledPendingClearDoesNotRemoveReplacementValue() async throws {
        let provider = RecordingDisplayControlProvider(snapshot: Self.snapshot)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.refresh()

        for _ in 0..<100 where service.snapshot.displays.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(service.snapshot.displays.count, 1)

        let model = DisplayControlMenuModel(service: service)
        model.start()
        XCTAssertEqual(model.statusText, "DDC write-only - current values estimated")
        model.setValue(kind: .brightness, value: 0.3)
        model.setValue(kind: .brightness, value: 0.7)

        try await Task.sleep(nanoseconds: 50_000_000)

        let brightness = try XCTUnwrap(model.sliderItems.first(where: { $0.kind == .brightness }))
        XCTAssertEqual(brightness.value, 0.7, accuracy: 0.0001)
    }

    func testPendingValueDoesNotRevertWhileHardwareWriteIsStillInFlight() async throws {
        let provider = RecordingDisplayControlProvider(snapshot: Self.snapshot)
        await provider.blockFirstWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.refresh()

        for _ in 0..<100 where service.snapshot.displays.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(service.snapshot.displays.count, 1)

        let model = DisplayControlMenuModel(
            service: service,
            pendingValueLifetimeNanos: 10_000_000
        )
        model.start()
        model.setValue(kind: .brightness, value: 0.7)
        await provider.waitUntilFirstWriteIsBlocked()

        try await Task.sleep(nanoseconds: 30_000_000)

        let brightness = try XCTUnwrap(model.sliderItems.first(where: { $0.kind == .brightness }))
        XCTAssertEqual(brightness.value, 0.7, accuracy: 0.0001)
        await provider.releaseFirstWrite()
    }

    func testSuccessfulTargetDoesNotRevertWhenImmediateReadbackIsStale() async throws {
        let provider = RecordingDisplayControlProvider(snapshot: Self.snapshot)
        await provider.blockFirstWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.refresh()

        for _ in 0..<100 where service.snapshot.displays.isEmpty {
            await Task.yield()
        }

        let model = DisplayControlMenuModel(
            service: service,
            pendingValueLifetimeNanos: 10_000_000
        )
        model.start()
        model.setValue(kind: .brightness, value: 0.7)
        await provider.waitUntilFirstWriteIsBlocked()
        await provider.releaseFirstWrite()

        for _ in 0..<100 {
            if await provider.recordedSnapshotCount() >= 2 {
                break
            }
            await Task.yield()
        }
        let snapshotCount = await provider.recordedSnapshotCount()
        XCTAssertGreaterThanOrEqual(snapshotCount, 2)
        try await Task.sleep(nanoseconds: 30_000_000)

        let brightness = try XCTUnwrap(model.sliderItems.first(where: { $0.kind == .brightness }))
        XCTAssertEqual(brightness.value, 0.7, accuracy: 0.0001)
    }

    func testSliderTargetIsQuantizedToReportedDDCResolution() async throws {
        let provider = RecordingDisplayControlProvider(snapshot: Self.coarseSnapshot)
        await provider.blockFirstWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.refresh()

        for _ in 0..<100 where service.snapshot.displays.isEmpty {
            await Task.yield()
        }

        let model = DisplayControlMenuModel(service: service)
        model.start()
        model.setValue(kind: .contrast, value: 0.53)
        await provider.waitUntilFirstWriteIsBlocked()

        let writes = await provider.recordedWrites()
        let writtenValue = try XCTUnwrap(writes.last?.1)
        let contrast = try XCTUnwrap(model.sliderItems.first(where: { $0.kind == .contrast }))
        XCTAssertEqual(writtenValue, 0.55, accuracy: 0.0001)
        XCTAssertEqual(contrast.value, 0.55, accuracy: 0.0001)
        await provider.releaseFirstWrite()
    }

    func testEnabledPresetFeatureProjectsAvailableOptions() {
        let provider = RecordingDisplayControlProvider(snapshot: Self.presetSnapshot)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.presetSnapshot)
        let model = DisplayControlMenuModel(
            service: service,

        )

        model.start()

        XCTAssertTrue(model.presetAvailable)
        XCTAssertEqual(model.presetItems.map(\.rawValue), [0x0B, 0x41])
        XCTAssertEqual(model.selectedPresetRawValue, 0x0B)
        XCTAssertNil(model.presetErrorText)
    }

    func testUnavailablePresetCapabilityDoesNotExposePicker() {
        let snapshot = Self.makePresetSnapshot(
            displays: [
                Self.makePresetDisplay(
                    id: 42,
                    currentRawValue: nil,
                    status: .unavailable,
                    options: []
                ),
            ]
        )
        let provider = RecordingDisplayControlProvider(snapshot: snapshot)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(snapshot)
        let model = DisplayControlMenuModel(
            service: service,

        )

        model.start()

        XCTAssertFalse(model.presetAvailable)
        XCTAssertTrue(model.presetItems.isEmpty)
        XCTAssertNil(model.selectedPresetRawValue)
    }

    func testUnmappedPresetCapabilityDoesNotExposePicker() {
        let snapshot = Self.makePresetSnapshot(
            displays: [
                Self.makePresetDisplay(
                    id: 42,
                    currentRawValue: 0x0B,
                    options: []
                ),
            ]
        )
        let provider = RecordingDisplayControlProvider(snapshot: snapshot)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(snapshot)
        let model = DisplayControlMenuModel(
            service: service,

        )

        model.start()

        XCTAssertFalse(model.presetAvailable)
        XCTAssertTrue(model.presetItems.isEmpty)
        XCTAssertNil(model.selectedPresetRawValue)
    }

    func testSelectingPresetImmediatelyPublishesPendingSelection() async {
        let provider = RecordingDisplayControlProvider(snapshot: Self.presetSnapshot)
        await provider.blockFirstPresetWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.presetSnapshot)
        let model = DisplayControlMenuModel(
            service: service,

        )
        model.start()

        model.setColorPreset(rawValue: 0x41)

        XCTAssertEqual(model.selectedPresetRawValue, 0x41)
        await provider.waitUntilFirstPresetWriteIsBlocked()
        await provider.releaseFirstPresetWrite()
    }

    func testPresetFailureRestoresSelectionAndExposesError() async {
        let provider = RecordingDisplayControlProvider(snapshot: Self.presetSnapshot)
        await provider.failPresetWrite(rawValue: 0x41)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(Self.presetSnapshot)
        let model = DisplayControlMenuModel(
            service: service,

        )
        model.start()

        model.setColorPreset(rawValue: 0x41)
        await provider.waitUntilPresetWriteCount(1)
        for _ in 0..<100 where model.presetErrorText == nil {
            await Task.yield()
        }

        XCTAssertEqual(model.selectedPresetRawValue, 0x0B)
        XCTAssertEqual(model.presetErrorText, "The color preset could not be read back.")
    }

    func testSwitchingDisplaysProjectsIndependentPresetOptions() {
        let snapshot = Self.makePresetSnapshot(
            displays: [
                Self.makePresetDisplay(id: 42, currentRawValue: 0x0B),
                Self.makePresetDisplay(
                    id: 77,
                    currentRawValue: 0x41,
                    options: [DisplayColorPresetOption(rawValue: 0x41, name: "HDR Preview")]
                ),
            ]
        )
        let provider = RecordingDisplayControlProvider(snapshot: snapshot)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(snapshot)
        let model = DisplayControlMenuModel(
            service: service,

        )
        model.start()

        model.select(displayID: 42)
        XCTAssertEqual(model.presetItems.map(\.rawValue), [0x0B, 0x41])
        XCTAssertEqual(model.selectedPresetRawValue, 0x0B)

        model.select(displayID: 77)
        XCTAssertEqual(model.presetItems.map(\.rawValue), [0x41])
        XCTAssertEqual(model.selectedPresetRawValue, 0x41)
    }

    func testNoDisplayStateDoesNotExposePresetProjection() {
        let snapshot = DisplayControlSnapshot(timestamp: Date(), displays: [])
        let provider = RecordingDisplayControlProvider(snapshot: snapshot)
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setSnapshotForTesting(snapshot)
        let model = DisplayControlMenuModel(
            service: service,

        )

        model.start()

        XCTAssertFalse(model.hasExternalDisplay)
        XCTAssertFalse(model.presetAvailable)
        XCTAssertTrue(model.presetItems.isEmpty)
        XCTAssertNil(model.selectedPresetRawValue)
        XCTAssertNil(model.presetErrorText)
    }

    private static let snapshot = DisplayControlSnapshot(
        timestamp: Date(),
        displays: [
            DisplayControlDisplay(
                id: 42,
                name: "Test Display",
                vendorNumber: nil,
                modelNumber: nil,
                serialNumber: nil,
                isBuiltIn: false,
                isVirtual: false,
                supportsHardwareDDC: true,
                backendName: "Test DDC",
                unavailableReason: nil,
                controls: [
                    DisplayControlCapability(
                        kind: .brightness,
                        status: .writeOnly,
                        value: DisplayControlValue(
                            kind: .brightness,
                            timestamp: Date(),
                            rawCurrent: 50,
                            rawMinimum: 0,
                            rawMaximum: 100,
                            normalized: 0.5
                        ),
                        unavailableReason: nil
                    ),
                ]
            ),
        ]
    )

    private static let coarseSnapshot = DisplayControlSnapshot(
        timestamp: Date(),
        displays: [
            DisplayControlDisplay(
                id: 42,
                name: "Coarse Display",
                vendorNumber: nil,
                modelNumber: nil,
                serialNumber: nil,
                isBuiltIn: false,
                isVirtual: false,
                supportsHardwareDDC: true,
                backendName: "Test DDC",
                unavailableReason: nil,
                controls: [
                    DisplayControlCapability(
                        kind: .contrast,
                        status: .available,
                        value: DisplayControlValue(
                            kind: .contrast,
                            timestamp: Date(),
                            rawCurrent: 10,
                            rawMinimum: 0,
                            rawMaximum: 20,
                            normalized: 0.5
                        ),
                        unavailableReason: nil
                    ),
                ]
            ),
        ]
    )

    private static let presetSnapshot = makePresetSnapshot(
        displays: [makePresetDisplay(id: 42, currentRawValue: 0x0B)]
    )

    private static func makePresetSnapshot(
        displays: [DisplayControlDisplay]
    ) -> DisplayControlSnapshot {
        DisplayControlSnapshot(timestamp: Date(), displays: displays)
    }

    private static func makePresetDisplay(
        id: CGDirectDisplayID,
        currentRawValue: UInt8?,
        status: DisplayColorPresetStatus = .available,
        options: [DisplayColorPresetOption] = [
            DisplayColorPresetOption(rawValue: 0x0B, name: "sRGB"),
            DisplayColorPresetOption(rawValue: 0x41, name: "HDR Preview"),
        ]
    ) -> DisplayControlDisplay {
        DisplayControlDisplay(
            id: id,
            name: "Preset Display \(id)",
            vendorNumber: 1,
            modelNumber: 2,
            serialNumber: id,
            isBuiltIn: false,
            isVirtual: false,
            supportsHardwareDDC: true,
            backendName: "Test DDC",
            unavailableReason: nil,
            controls: [],
            colorPreset: DisplayColorPresetCapability(
                status: status,
                currentRawValue: currentRawValue,
                options: options,
                advertisedRawValues: options.map(\.rawValue),
                unavailableReason: status == .available ? nil : "Capability unavailable"
            )
        )
    }
}

private final class RecordingDisplaySettingsOpener: DisplaySettingsOpening {
    let result: Bool
    private(set) var openCount = 0

    init(result: Bool) {
        self.result = result
    }

    func openDisplaySettings() -> Bool {
        openCount += 1
        return result
    }
}
