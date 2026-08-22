import CoreGraphics
import XCTest
@testable import ToolBoxCore

@MainActor
final class AXRegionProjectionTests: XCTestCase {
    func testChildAndParentsProjectFromTopLeftAndPreserveOrder() async throws {
        let records = [
            AXRegionRecord(ownerPID: 55, role: "AXButton", title: "Save", position: CGPoint(x: 10, y: 20), size: CGSize(width: 30, height: 10), hierarchyIndex: 0),
            AXRegionRecord(ownerPID: 55, role: "AXGroup", title: nil, position: CGPoint(x: 5, y: 10), size: CGSize(width: 100, height: 80), hierarchyIndex: 1),
            AXRegionRecord(ownerPID: 55, role: "AXWindow", title: "Editor", position: CGPoint(x: 0, y: 0), size: CGSize(width: 200, height: 120), hierarchyIndex: 2),
        ]
        let provider = AXRegionProvider(
            ownPID: 99,
            primaryScreenTop: { 1_000 },
            visibleScreenFrames: axTestScreenFrames,
            currentGeneration: { 7 },
            lookup: { _ in .success(records) }
        )

        let candidates = try await provider.regions(at: CGPoint(x: 20, y: 970), generation: 7)

        XCTAssertEqual(candidates.map(\.role), ["AXButton", "AXGroup", "AXWindow"])
        XCTAssertEqual(candidates[0].globalRect, CGRect(x: 10, y: 970, width: 30, height: 10))
        XCTAssertEqual(candidates.map(\.hierarchyIndex), [0, 1, 2])
    }

    func testZeroAreaAndOwnPIDRecordsAreFiltered() async throws {
        let records = [
            AXRegionRecord(ownerPID: 99, role: "AXButton", title: nil, position: .zero, size: CGSize(width: 10, height: 10), hierarchyIndex: 0),
            AXRegionRecord(ownerPID: 55, role: "AXGroup", title: nil, position: .zero, size: CGSize(width: 0, height: 10), hierarchyIndex: 1),
            AXRegionRecord(ownerPID: 55, role: "AXWindow", title: nil, position: .zero, size: CGSize(width: 20, height: 20), hierarchyIndex: 2),
        ]
        let provider = AXRegionProvider(
            ownPID: 99,
            primaryScreenTop: { 100 },
            visibleScreenFrames: axTestScreenFrames,
            currentGeneration: { 1 },
            lookup: { _ in .success(records) }
        )
        let candidates = try await provider.regions(at: .zero, generation: 1)
        XCTAssertEqual(candidates.map(\.role), ["AXWindow"])
    }

    func testTimeoutAndStaleGenerationAreClassified() async {
        let timeout = AXRegionProvider(
            primaryScreenTop: { 100 },
            currentGeneration: { 1 },
            lookup: { _ in .failure(.timeout) }
        )
        await XCTAssertThrowsErrorAsync(try await timeout.regions(at: .zero, generation: 1)) {
            XCTAssertEqual($0 as? AXRegionError, .timeout)
        }

        let stale = AXRegionProvider(
            primaryScreenTop: { 100 },
            currentGeneration: { 2 },
            lookup: { _ in .success([]) }
        )
        await XCTAssertThrowsErrorAsync(try await stale.regions(at: .zero, generation: 1)) {
            XCTAssertEqual($0 as? AXRegionError, .staleGeneration)
        }
    }

    func testLookupTargetsWindowOwnerAndKeepsWindowAsFinalFallback() async throws {
        let capturedRequest = LockedAXLookupRequest()
        let window = SelectionCandidate(
            providerIdentity: "window",
            source: .window,
            ownerPID: 55,
            windowID: 71,
            displayID: 1,
            topologyGeneration: 7,
            role: "AXWindow",
            title: "Editor",
            hierarchyIndex: 0,
            globalRect: CGRect(x: 0, y: 880, width: 200, height: 120)
        )
        let records = [
            AXRegionRecord(
                ownerPID: 55,
                role: "AXButton",
                title: "Save",
                position: CGPoint(x: 10, y: 20),
                size: CGSize(width: 30, height: 10),
                hierarchyIndex: 0
            ),
            AXRegionRecord(
                ownerPID: 55,
                role: "AXWindow",
                title: "Editor",
                position: .zero,
                size: CGSize(width: 200, height: 120),
                hierarchyIndex: 1
            ),
        ]
        let provider = AXRegionProvider(
            ownPID: 99,
            primaryScreenTop: { 1_000 },
            visibleScreenFrames: axTestScreenFrames,
            currentGeneration: { 7 },
            lookup: { request in
                capturedRequest.set(request)
                return .success(records)
            }
        )

        let candidates = try await provider.regions(
            at: CGPoint(x: 20, y: 970),
            generation: 7,
            targetWindow: window
        )

        XCTAssertEqual(capturedRequest.value?.targetPID, 55)
        XCTAssertEqual(capturedRequest.value?.point, CGPoint(x: 20, y: 30))
        XCTAssertEqual(candidates.map(\.source), [.accessibility, .window])
        XCTAssertEqual(candidates.map(\.role), ["AXButton", "AXWindow"])
        XCTAssertEqual(candidates.last?.windowID, 71)
    }

    func testRegionsRejectElementsOutsideEveryVisibleScreen() async throws {
        let records = [
            AXRegionRecord(
                ownerPID: 55,
                role: "AXButton",
                title: nil,
                position: CGPoint(x: 2_000, y: 2_000),
                size: CGSize(width: 20, height: 20),
                hierarchyIndex: 0
            ),
        ]
        let provider = AXRegionProvider(
            ownPID: 99,
            primaryScreenTop: { 1_000 },
            visibleScreenFrames: { [CGRect(x: 0, y: 0, width: 1_000, height: 1_000)] },
            currentGeneration: { 1 },
            lookup: { _ in .success(records) }
        )

        let candidates = try await provider.regions(at: .zero, generation: 1)

        XCTAssertTrue(candidates.isEmpty)
    }

    func testQueuedLookupCoalescesToNewestPointerPosition() async throws {
        let releaseFirst = DispatchSemaphore(value: 0)
        let capturedRequests = LockedAXLookupRequests()
        let provider = AXRegionProvider(
            primaryScreenTop: { 100 },
            currentGeneration: { 1 },
            lookup: { request in
                capturedRequests.append(request)
                if request.point.x == 1 {
                    releaseFirst.wait()
                }
                return .success([])
            }
        )

        let first = Task { try await provider.regions(at: CGPoint(x: 1, y: 90), generation: 1) }
        for _ in 0..<100 where capturedRequests.values.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(capturedRequests.values.map(\.point.x), [1])
        let second = Task { try await provider.regions(at: CGPoint(x: 2, y: 90), generation: 1) }
        await Task.yield()
        let newest = Task { try await provider.regions(at: CGPoint(x: 3, y: 90), generation: 1) }
        await Task.yield()
        releaseFirst.signal()

        _ = try await first.value
        _ = try? await second.value
        _ = try await newest.value

        XCTAssertEqual(capturedRequests.values.map(\.point.x), [1, 3])
    }

    func testDeduplicationMergesNearIdenticalRects() async throws {
        let records = [
            // AXButton and AXGroup have the same position and nearly identical size
            // (width 30 vs 31, within 2pt tolerance) — they should be merged.
            AXRegionRecord(ownerPID: 55, role: "AXButton", title: "Save", position: CGPoint(x: 10, y: 20), size: CGSize(width: 30, height: 10), hierarchyIndex: 0),
            AXRegionRecord(ownerPID: 55, role: "AXGroup", title: nil, position: CGPoint(x: 10, y: 20), size: CGSize(width: 31, height: 10), hierarchyIndex: 1),
            AXRegionRecord(ownerPID: 55, role: "AXWindow", title: "Editor", position: CGPoint(x: 0, y: 0), size: CGSize(width: 200, height: 120), hierarchyIndex: 2),
        ]
        let provider = AXRegionProvider(
            ownPID: 99,
            primaryScreenTop: { 1_000 },
            visibleScreenFrames: axTestScreenFrames,
            currentGeneration: { 7 },
            lookup: { _ in .success(records) }
        )

        let candidates = try await provider.regions(at: CGPoint(x: 20, y: 970), generation: 7)

        // The AXButton (hierarchyIndex 0) and AXGroup (hierarchyIndex 1) have
        // near-identical rects (within 2pt tolerance) — the AXButton should be kept
        // and the AXGroup should be deduplicated away.
        XCTAssertEqual(candidates.map(\.role), ["AXButton", "AXWindow"])
    }

    func testDeduplicationPreservesDistinctRects() async throws {
        let records = [
            AXRegionRecord(ownerPID: 55, role: "AXButton", title: "Save", position: CGPoint(x: 10, y: 20), size: CGSize(width: 30, height: 10), hierarchyIndex: 0),
            AXRegionRecord(ownerPID: 55, role: "AXWindow", title: "Editor", position: CGPoint(x: 0, y: 0), size: CGSize(width: 200, height: 120), hierarchyIndex: 1),
        ]
        let provider = AXRegionProvider(
            ownPID: 99,
            primaryScreenTop: { 1_000 },
            visibleScreenFrames: axTestScreenFrames,
            currentGeneration: { 7 },
            lookup: { _ in .success(records) }
        )

        let candidates = try await provider.regions(at: CGPoint(x: 20, y: 970), generation: 7)

        // Distinct rects should all be preserved
        XCTAssertEqual(candidates.map(\.role), ["AXButton", "AXWindow"])
    }

    func testDockFullScreenOverlayDoesNotSwallowApplicationWindowHits() async throws {
        // Reproduces the shipped bug: the Dock publishes a window covering the whole
        // screen at layer 20 and sits ahead of ordinary windows in front-to-back
        // order, so an unfiltered scan resolved EVERY point to the Dock.
        let records = [
            WindowRegionRecord(
                ownerPID: 300,
                windowID: 8,
                title: nil,
                bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                layer: 20
            ),
            WindowRegionRecord(
                ownerPID: 55,
                windowID: 71,
                title: "Editor",
                bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
                layer: 0
            ),
        ]
        let provider = WindowRegionProvider(
            ownPID: 99,
            primaryScreenTop: { 1_080 },
            windowList: { records }
        )

        // A point inside the application window (flipped y = 1080 - 700 = 380).
        let candidate = try await provider.region(at: CGPoint(x: 500, y: 500), generation: 1)

        XCTAssertEqual(candidate?.ownerPID, 55, "must resolve to the app window, not the Dock")
        XCTAssertEqual(candidate?.windowID, 71)
    }

    func testMenuBarAndDockLayersAreNeverSelectable() async throws {
        let records = [
            WindowRegionRecord(ownerPID: 300, windowID: 8, title: nil, bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080), layer: 20),
            WindowRegionRecord(ownerPID: 301, windowID: 9, title: nil, bounds: CGRect(x: 0, y: 0, width: 1_920, height: 30), layer: 24),
            WindowRegionRecord(ownerPID: 302, windowID: 10, title: nil, bounds: CGRect(x: 0, y: 0, width: 200, height: 30), layer: 25),
        ]
        let provider = WindowRegionProvider(
            ownPID: 99,
            primaryScreenTop: { 1_080 },
            windowList: { records }
        )

        let candidate = try await provider.region(at: CGPoint(x: 500, y: 500), generation: 1)

        XCTAssertNil(candidate, "shell layers must not be selectable window targets")
    }

    func testNegativeLayerWindowsAreRejected() async throws {
        // Notification Center uses a large negative layer.
        let records = [
            WindowRegionRecord(
                ownerPID: 400,
                windowID: 11,
                title: nil,
                bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                layer: -2_147_483_601
            ),
        ]
        let provider = WindowRegionProvider(
            ownPID: 99,
            primaryScreenTop: { 1_080 },
            windowList: { records }
        )

        let candidate = try await provider.region(at: CGPoint(x: 500, y: 500), generation: 1)

        XCTAssertNil(candidate)
    }

    func testFloatingPanelLayerRemainsSelectable() async throws {
        // Genuine floating panels sit just above layer 0 and must stay usable.
        let records = [
            WindowRegionRecord(
                ownerPID: 55,
                windowID: 71,
                title: "Inspector",
                bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
                layer: 3
            ),
        ]
        let provider = WindowRegionProvider(
            ownPID: 99,
            primaryScreenTop: { 1_080 },
            windowList: { records }
        )

        let candidate = try await provider.region(at: CGPoint(x: 200, y: 800), generation: 1)

        XCTAssertEqual(candidate?.windowID, 71)
    }

    func testWindowProviderSkipsOwnOverlayAndUsesFrontToBackOrder() async throws {
        let records = [
            WindowRegionRecord(
                ownerPID: 99,
                windowID: 100,
                title: "ToolBox overlay",
                bounds: CGRect(x: 0, y: 0, width: 200, height: 200)
            ),
            WindowRegionRecord(
                ownerPID: 55,
                windowID: 71,
                title: "Front",
                bounds: CGRect(x: 20, y: 20, width: 100, height: 100)
            ),
            WindowRegionRecord(
                ownerPID: 66,
                windowID: 72,
                title: "Back",
                bounds: CGRect(x: 0, y: 0, width: 200, height: 200)
            ),
        ]
        let provider = WindowRegionProvider(
            ownPID: 99,
            primaryScreenTop: { 200 },
            windowList: { records }
        )

        let candidate = try await provider.region(at: CGPoint(x: 40, y: 140), generation: 8)

        XCTAssertEqual(candidate?.ownerPID, 55)
        XCTAssertEqual(candidate?.windowID, 71)
        XCTAssertEqual(candidate?.title, "Front")
        XCTAssertEqual(candidate?.globalRect, CGRect(x: 20, y: 80, width: 100, height: 100))
    }
}

private let axTestScreenFrames: () -> [CGRect] = {
    [CGRect(x: 0, y: 0, width: 4_000, height: 4_000)]
}

private final class LockedAXLookupRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: AXLookupRequest?

    var value: AXLookupRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: AXLookupRequest) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private final class LockedAXLookupRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [AXLookupRequest] = []

    var values: [AXLookupRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: AXLookupRequest) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
