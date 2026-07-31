import CoreGraphics
import XCTest
@testable import ToolBox

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
            currentGeneration: { 7 },
            lookup: { _, _ in .success(records) }
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
            currentGeneration: { 1 },
            lookup: { _, _ in .success(records) }
        )
        let candidates = try await provider.regions(at: .zero, generation: 1)
        XCTAssertEqual(candidates.map(\.role), ["AXWindow"])
    }

    func testTimeoutAndStaleGenerationAreClassified() async {
        let timeout = AXRegionProvider(
            primaryScreenTop: { 100 },
            currentGeneration: { 1 },
            lookup: { _, _ in .failure(.timeout) }
        )
        await XCTAssertThrowsErrorAsync(try await timeout.regions(at: .zero, generation: 1)) {
            XCTAssertEqual($0 as? AXRegionError, .timeout)
        }

        let stale = AXRegionProvider(
            primaryScreenTop: { 100 },
            currentGeneration: { 2 },
            lookup: { _, _ in .success([]) }
        )
        await XCTAssertThrowsErrorAsync(try await stale.regions(at: .zero, generation: 1)) {
            XCTAssertEqual($0 as? AXRegionError, .staleGeneration)
        }
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
