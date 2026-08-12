import ApplicationServices
import XCTest
@testable import ToolBox

final class AXAccessibilityActivatorTests: XCTestCase {
    /// Records every write so tests can assert exactly what was touched.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var writes: [(name: String, value: Bool)] = []
        var initialValues: [String: Bool?] = [:]

        func read(_ name: String) -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return initialValues[name] ?? false
        }

        func write(_ name: String, _ value: Bool) -> Bool {
            lock.lock()
            writes.append((name, value))
            initialValues[name] = value
            lock.unlock()
            return true
        }
    }

    private func makeActivator(_ recorder: Recorder) -> AXAccessibilityActivator {
        AXAccessibilityActivator(
            setAttribute: { _, name, value in recorder.write(name, value) },
            readAttribute: { _, name in recorder.read(name) }
        )
    }

    private var dummyElement: AXUIElement { AXUIElementCreateApplication(1) }

    func testEnablesBothOptInAttributesWhenBothAreOff() {
        let recorder = Recorder()
        recorder.initialValues = [
            AXAccessibilityActivator.manualAccessibilityAttribute: false,
            AXAccessibilityActivator.enhancedUserInterfaceAttribute: false,
        ]
        let activator = makeActivator(recorder)

        let record = activator.activate(application: dummyElement, pid: 42)

        XCTAssertTrue(record.setManualAccessibility)
        XCTAssertTrue(record.setEnhancedUserInterface)
        XCTAssertEqual(recorder.writes.map(\.name).sorted(), [
            AXAccessibilityActivator.enhancedUserInterfaceAttribute,
            AXAccessibilityActivator.manualAccessibilityAttribute,
        ])
        XCTAssertTrue(recorder.writes.allSatisfy { $0.value })
    }

    func testDoesNotClaimAttributeAlreadyEnabledByAnotherClient() {
        let recorder = Recorder()
        // A screen reader already turned this on — we must not claim it, because
        // restoring it later would break that other client.
        recorder.initialValues = [
            AXAccessibilityActivator.manualAccessibilityAttribute: true,
            AXAccessibilityActivator.enhancedUserInterfaceAttribute: false,
        ]
        let activator = makeActivator(recorder)

        let record = activator.activate(application: dummyElement, pid: 42)

        XCTAssertFalse(record.setManualAccessibility)
        XCTAssertTrue(record.setEnhancedUserInterface)
        XCTAssertEqual(
            recorder.writes.map(\.name),
            [AXAccessibilityActivator.enhancedUserInterfaceAttribute]
        )
    }

    func testUnsupportedAttributeIsSkipped() {
        let recorder = Recorder()
        // nil means the attribute is absent -> app does not support it.
        recorder.initialValues = [
            AXAccessibilityActivator.manualAccessibilityAttribute: nil,
            AXAccessibilityActivator.enhancedUserInterfaceAttribute: false,
        ]
        let activator = makeActivator(recorder)

        let record = activator.activate(application: dummyElement, pid: 42)

        XCTAssertFalse(record.setManualAccessibility)
        XCTAssertTrue(record.setEnhancedUserInterface)
    }

    func testRepeatedActivationForSamePIDDoesNotWriteTwice() {
        let recorder = Recorder()
        recorder.initialValues = [
            AXAccessibilityActivator.manualAccessibilityAttribute: false,
            AXAccessibilityActivator.enhancedUserInterfaceAttribute: false,
        ]
        let activator = makeActivator(recorder)

        activator.activate(application: dummyElement, pid: 42)
        let writeCount = recorder.writes.count
        activator.activate(application: dummyElement, pid: 42)

        XCTAssertEqual(recorder.writes.count, writeCount, "second activation must be a no-op")
    }

    func testRestoreOnlyClearsFlagsThisProcessEnabled() {
        let recorder = Recorder()
        recorder.initialValues = [
            AXAccessibilityActivator.manualAccessibilityAttribute: true,
            AXAccessibilityActivator.enhancedUserInterfaceAttribute: false,
        ]
        let activator = makeActivator(recorder)
        activator.activate(application: dummyElement, pid: 42)

        activator.restoreAll { _ in AXUIElementCreateApplication(42) }

        // Only the enhanced flag was ours, so only it may be cleared.
        let clears = recorder.writes.filter { !$0.value }
        XCTAssertEqual(clears.map(\.name), [AXAccessibilityActivator.enhancedUserInterfaceAttribute])
        XCTAssertNil(activator.record(for: 42), "bookkeeping must be dropped after restore")
    }

    func testRestoreIsIdempotent() {
        let recorder = Recorder()
        recorder.initialValues = [
            AXAccessibilityActivator.manualAccessibilityAttribute: false,
            AXAccessibilityActivator.enhancedUserInterfaceAttribute: false,
        ]
        let activator = makeActivator(recorder)
        activator.activate(application: dummyElement, pid: 42)

        activator.restoreAll { _ in AXUIElementCreateApplication(42) }
        let afterFirst = recorder.writes.count
        activator.restoreAll { _ in AXUIElementCreateApplication(42) }

        XCTAssertEqual(recorder.writes.count, afterFirst, "second restore must be a no-op")
    }

    func testActivationIsTrackedPerPID() {
        let recorder = Recorder()
        recorder.initialValues = [
            AXAccessibilityActivator.manualAccessibilityAttribute: false,
            AXAccessibilityActivator.enhancedUserInterfaceAttribute: false,
        ]
        let activator = makeActivator(recorder)

        activator.activate(application: dummyElement, pid: 42)
        activator.activate(application: dummyElement, pid: 77)

        XCTAssertNotNil(activator.record(for: 42))
        XCTAssertNotNil(activator.record(for: 77))
    }
}
