import CoreGraphics
import XCTest
@testable import ToolBox

@MainActor
final class DisplayControlMenuModelTests: XCTestCase {
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
}
