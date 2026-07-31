import CoreGraphics
import XCTest
@testable import ToolBox

final class ScrollDriverTests: XCTestCase {
    func testAutomaticDriverPostsPixelStepAtROICenter() async throws {
        let access = FakeScrollEventAccess(isAllowed: true)
        let poster = FakeScrollEventPoster()
        let driver = AutomaticScrollDriver(
            access: access,
            poster: poster,
            stepPixels: 120,
            cadence: .zero
        )

        let result = try await driver.scroll(target: snapshot(), validate: {})

        XCTAssertEqual(result, .movementRequested)
        XCTAssertEqual(poster.events, [.init(location: CGPoint(x: 70, y: 70), deltaY: -120)])
        XCTAssertEqual(access.requestCount, 0)
    }

    func testDeniedAutomaticAccessFallsBackWithoutPostingOrPrompting() async throws {
        let access = FakeScrollEventAccess(isAllowed: false)
        let poster = FakeScrollEventPoster()
        let driver = AutomaticScrollDriver(access: access, poster: poster, cadence: .zero)

        let result = try await driver.scroll(target: snapshot(), validate: {})

        XCTAssertEqual(result, .manualRequired)
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertEqual(access.requestCount, 0)
    }

    func testValidationRunsBeforePostingAndManualDriverPostsNothing() async throws {
        let poster = FakeScrollEventPoster()
        let automatic = AutomaticScrollDriver(
            access: FakeScrollEventAccess(isAllowed: true),
            poster: poster,
            cadence: .zero
        )
        await XCTAssertThrowsErrorAsync(
            try await automatic.scroll(target: snapshot(), validate: { throw TestError.invalid })
        )
        XCTAssertTrue(poster.events.isEmpty)

        let manual = ManualScrollDriver()
        let result = try await manual.scroll(target: snapshot(), validate: {})
        XCTAssertEqual(result, .waitingForManualMovement)
    }

    private func snapshot() -> ScrollCaptureTargetSnapshot {
        ScrollCaptureTargetSnapshot(
            ownerPID: 42,
            windowID: 7,
            displayID: 1,
            topologyGeneration: 9,
            roiGlobal: CGRect(x: 20, y: 30, width: 100, height: 80),
            windowGlobalFrame: CGRect(x: 0, y: 0, width: 400, height: 500)
        )
    }

    private enum TestError: Error { case invalid }
}

private final class FakeScrollEventAccess: ScrollEventAccessProviding {
    let isAllowed: Bool
    private(set) var requestCount = 0
    init(isAllowed: Bool) { self.isAllowed = isAllowed }
    func preflight() -> Bool { isAllowed }
    func request() -> Bool { requestCount += 1; return isAllowed }
}

private final class FakeScrollEventPoster: ScrollEventPosting {
    struct Event: Equatable { let location: CGPoint; let deltaY: Int32 }
    private(set) var events: [Event] = []
    func postPixelScroll(at location: CGPoint, deltaY: Int32) throws {
        events.append(Event(location: location, deltaY: deltaY))
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
