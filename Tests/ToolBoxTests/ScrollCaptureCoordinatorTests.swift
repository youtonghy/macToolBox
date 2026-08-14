import CoreGraphics
import XCTest
@testable import ToolBox

@MainActor
final class ScrollCaptureCoordinatorTests: XCTestCase {
    func testForwardMatchesAppendOnlyNewRowsThenCompleteAfterThreeNoMovementFrames() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = FakeScrollFrameProvider(samples: [
            sample(rows: [.red, .green, .blue, .yellow], time: 1),
            sample(rows: [.blue, .yellow, .cyan, .magenta], time: 2),
            sample(rows: [.blue, .yellow, .cyan, .magenta], time: 3),
            sample(rows: [.blue, .yellow, .cyan, .magenta], time: 4),
            sample(rows: [.blue, .yellow, .cyan, .magenta], time: 5),
        ])
        let coordinator = ScrollCaptureCoordinator(
            frameProvider: frames,
            automaticDriver: FakeScrollDriver(results: Array(repeating: .movementRequested, count: 4)),
            manualDriver: ManualScrollDriver(),
            rootDirectory: root,
            match: { previous, current in
                previous == current
                    ? OverlapMatch(classification: .noMovement, overlapRowCount: 4, newRowCount: 0, confidence: 1, normalizedError: 0)
                    : OverlapMatch(classification: .forward, overlapRowCount: 2, newRowCount: 2, confidence: 1, normalizedError: 0)
            },
            validate: { _ in }
        )

        let result = try await coordinator.capture(target: target())

        XCTAssertEqual(coordinator.state, .completed(.bottomReached))
        XCTAssertEqual(result.source.pixelSize, CGSize(width: 2, height: 6))
        let image = try result.source.copyPixels(in: CGRect(x: 0, y: 0, width: 1, height: 6))
        XCTAssertEqual(try colors(in: image), [.red, .green, .blue, .yellow, .cyan, .magenta])
    }

    func testDeniedAutomaticDriverFallsBackToManual() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let automatic = FakeScrollDriver(results: [.manualRequired])
        let manual = FakeScrollDriver(results: Array(repeating: .waitingForManualMovement, count: 64))
        let stable = sample(rows: [.red, .green, .blue, .yellow], time: 1)
        let coordinator = ScrollCaptureCoordinator(
            frameProvider: FakeScrollFrameProvider(samples: Array(repeating: stable, count: 64)),
            automaticDriver: automatic,
            manualDriver: manual,
            rootDirectory: root,
            match: { _, _ in
                OverlapMatch(classification: .noMovement, overlapRowCount: 4, newRowCount: 0, confidence: 1, normalizedError: 0)
            },
            validate: { _ in }
        )

        let task = Task { try await coordinator.capture(target: target()) }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, coordinator.mode != .manual {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(coordinator.mode, .manual)
        coordinator.finishPartial()
        _ = try await task.value

        XCTAssertEqual(automatic.callCount, 1)
        XCTAssertGreaterThanOrEqual(manual.callCount, 1)
        XCTAssertEqual(coordinator.mode, .manual)
    }

    func testLowConfidencePausesUntilFinishPartial() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = FakeScrollFrameProvider(samples: [
            sample(rows: [.red, .green, .blue, .yellow], time: 1),
            sample(rows: [.green, .blue, .yellow, .cyan], time: 2),
        ])
        let coordinator = ScrollCaptureCoordinator(
            frameProvider: frames,
            automaticDriver: FakeScrollDriver(results: [.movementRequested]),
            manualDriver: ManualScrollDriver(),
            rootDirectory: root,
            match: { _, _ in
                OverlapMatch(classification: .lowConfidence, overlapRowCount: 0, newRowCount: 0, confidence: 0, normalizedError: 1)
            },
            validate: { _ in }
        )
        let task = Task { try await coordinator.capture(target: target()) }
        for _ in 0..<100 where coordinator.state != .paused(.lowConfidence) {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(coordinator.state, .paused(.lowConfidence))

        coordinator.finishPartial()
        let result = try await task.value

        XCTAssertEqual(result.completion, .userFinished)
        XCTAssertEqual(result.source.pixelSize.height, 4)
    }

    private func target() -> ScrollCaptureTargetSnapshot {
        ScrollCaptureTargetSnapshot(
            ownerPID: 42,
            windowID: 7,
            displayID: 1,
            topologyGeneration: 9,
            roiGlobal: CGRect(x: 0, y: 0, width: 2, height: 4),
            windowGlobalFrame: CGRect(x: 0, y: 0, width: 200, height: 300)
        )
    }

    private func sample(rows: [TestColor], time: TimeInterval) -> ScrollCaptureFrame {
        ScrollCaptureFrame(image: makeRows(width: 2, colors: rows), luma: try! LumaFrame(width: 1, height: rows.count, pixels: rows.map(\.luma)), timestamp: time)
    }

    private func makeRows(width: Int, colors: [TestColor]) -> CGImage {
        let context = CGContext(data: nil, width: width, height: colors.count, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (row, color) in colors.enumerated() {
            context.setFillColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
            context.fill(CGRect(x: 0, y: row, width: width, height: 1))
        }
        return context.makeImage()!
    }

    private func colors(in image: CGImage) throws -> [TestColor] {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { throw TestError.image }
        return (0..<image.height).map { visualRow in
            let providerRow = image.height - 1 - visualRow
            let offset = providerRow * image.bytesPerRow
            return TestColor(r: bytes[offset], g: bytes[offset + 1], b: bytes[offset + 2], luma: 0)
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scroll-coordinator-\(UUID().uuidString)")
    }

    private enum TestError: Error { case image }
}

private final class FakeScrollFrameProvider: ScrollCaptureFrameProviding {
    private var samples: [ScrollCaptureFrame]
    init(samples: [ScrollCaptureFrame]) { self.samples = samples }
    func captureInitialFrame(target: ScrollCaptureTargetSnapshot) async throws -> ScrollCaptureFrame { try next() }
    func captureStableFrame(target: ScrollCaptureTargetSnapshot) async throws -> ScrollCaptureFrame { try next() }
    private func next() throws -> ScrollCaptureFrame {
        guard !samples.isEmpty else { throw ScrollCaptureError.captureFailed }
        return samples.removeFirst()
    }
}

private final class FakeScrollDriver: ScrollDriving {
    private var results: [ScrollDriverResult]
    private(set) var callCount = 0
    init(results: [ScrollDriverResult]) { self.results = results }
    func scroll(target: ScrollCaptureTargetSnapshot, validate: () throws -> Void) async throws -> ScrollDriverResult {
        try validate()
        await Task.yield()
        callCount += 1
        guard !results.isEmpty else { throw ScrollCaptureError.captureFailed }
        return results.removeFirst()
    }
}

private struct TestColor: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let luma: UInt8
    static let red = TestColor(r: 255, g: 0, b: 0, luma: 10)
    static let green = TestColor(r: 0, g: 255, b: 0, luma: 20)
    static let blue = TestColor(r: 0, g: 0, b: 255, luma: 30)
    static let yellow = TestColor(r: 255, g: 255, b: 0, luma: 40)
    static let cyan = TestColor(r: 0, g: 255, b: 255, luma: 50)
    static let magenta = TestColor(r: 255, g: 0, b: 255, luma: 60)

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.r == rhs.r && lhs.g == rhs.g && lhs.b == rhs.b
    }
}
