import CoreGraphics
import XCTest
@testable import ToolBox

final class DisplayCapabilityStoreTests: XCTestCase {
    func testReportIsReusedForSameConnectionToken() {
        var store = DisplayCapabilityStore()
        let key = makeKey(connectionToken: 10)
        let report = makeReport()

        store.record(report, for: key)

        XCTAssertEqual(store.report(for: key), report)
        XCTAssertEqual(store.count, 1)
    }

    func testConnectionTokenChangeInvalidatesCachedCapability() {
        var store = DisplayCapabilityStore()
        let oldKey = makeKey(connectionToken: 10)
        let newKey = makeKey(connectionToken: 11)
        store.record(makeReport(), for: oldKey)

        XCTAssertNil(store.report(for: newKey))
        XCTAssertNil(store.report(for: oldKey))
        XCTAssertEqual(store.count, 0)
    }

    func testDisconnectRemovesCachedCapability() {
        var store = DisplayCapabilityStore()
        let retained = makeKey(displayID: 1, connectionToken: 10)
        let disconnected = makeKey(displayID: 2, connectionToken: 20)
        store.record(makeReport(), for: retained)
        store.record(makeReport(), for: disconnected)

        store.retainConnections([retained])

        XCTAssertNotNil(store.report(for: retained))
        XCTAssertNil(store.report(for: disconnected))
        XCTAssertEqual(store.count, 1)
    }

    func testFailedCapabilityReadIsNotPermanentlyCached() {
        var store = DisplayCapabilityStore()
        let key = makeKey(connectionToken: 10)
        var readCount = 0

        func load() -> DDCCapabilityReport? {
            if let cached = store.report(for: key) {
                return cached
            }
            readCount += 1
            return nil
        }

        XCTAssertNil(load())
        XCTAssertNil(load())
        XCTAssertEqual(readCount, 2)
        XCTAssertEqual(store.count, 0)
    }

    func testExplicitDisplayInvalidationRemovesOnlyThatDisplay() {
        var store = DisplayCapabilityStore()
        let removed = makeKey(displayID: 1, connectionToken: 10)
        let retained = makeKey(displayID: 2, connectionToken: 20)
        store.record(makeReport(), for: removed)
        store.record(makeReport(), for: retained)

        store.invalidate(displayID: removed.displayID)

        XCTAssertNil(store.report(for: removed))
        XCTAssertNotNil(store.report(for: retained))
        XCTAssertEqual(store.count, 1)
    }

    private func makeKey(
        displayID: CGDirectDisplayID = 1,
        connectionToken: UInt64
    ) -> DisplayCapabilityCacheKey {
        DisplayCapabilityCacheKey(
            displayID: displayID,
            hardwareIdentity: DisplayHardwareIdentity(
                vendorNumber: 123,
                modelNumber: 456,
                serialNumber: 789
            ),
            backendName: "test",
            connectionToken: connectionToken
        )
    }

    private func makeReport() -> DDCCapabilityReport {
        DDCCapabilityReport(
            supportedVCPs: [0x14],
            enumValues: [0x14: [0x01, 0x02]],
            rawString: "vcp(14(01 02))"
        )
    }
}
