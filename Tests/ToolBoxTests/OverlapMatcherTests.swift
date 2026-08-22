import XCTest
@testable import ToolBoxCore

final class OverlapMatcherTests: XCTestCase {
    func testKnownForwardOffsetReturnsExactNewRows() throws {
        let sequence = try makeSequence(offset: 7)
        let match = try OverlapMatcher().match(previous: sequence.previous, current: sequence.current)

        XCTAssertEqual(match.classification, .forward)
        XCTAssertEqual(match.newRowCount, 7)
        XCTAssertEqual(match.overlapRowCount, 25)
        XCTAssertGreaterThan(match.confidence, 0.9)
    }

    func testAutomaticScrollConfigurationSearchesDefaultStepAtTypicalWidth() throws {
        let sequence = try makeSequence(offset: 34, height: 96)
        let configuration = ScrollMatchingConfiguration.automaticScroll(
            stepPixels: 160,
            roiWidth: 600
        )

        let match = try OverlapMatcher(configuration: configuration)
            .matchPersistentContent(previous: sequence.previous, current: sequence.current)

        XCTAssertEqual(match.classification, .forward)
        XCTAssertEqual(match.newRowCount, 34)
    }

    func testIdenticalFramesReturnNoNewContent() throws {
        let frame = try patternedFrame(startRow: 0)
        let match = try OverlapMatcher().match(previous: frame, current: frame)

        XCTAssertEqual(match.classification, .noMovement)
        XCTAssertEqual(match.newRowCount, 0)
    }

    func testFixedHeaderAndFooterDoNotBiasOffset() throws {
        var sequence = try makeSequence(offset: 6)
        sequence.previous = try replacingEdges(in: sequence.previous, edgeRows: 4, value: 220)
        sequence.current = try replacingEdges(in: sequence.current, edgeRows: 4, value: 220)
        let mask = try StableContentMask.detectPersistentRows(
            previous: sequence.previous,
            current: sequence.current,
            threshold: 0
        )

        let match = try OverlapMatcher().match(
            previous: sequence.previous,
            current: sequence.current,
            mask: mask
        )

        XCTAssertEqual(match.classification, .forward)
        XCTAssertEqual(match.newRowCount, 6)
    }

    func testSparseAnimationDoesNotHideForwardMatch() throws {
        var sequence = try makeSequence(offset: 5)
        var pixels = sequence.current.pixels
        for index in stride(from: 0, to: pixels.count, by: 97) {
            pixels[index] = 255 &- pixels[index]
        }
        sequence.current = try LumaFrame(
            width: sequence.current.width,
            height: sequence.current.height,
            pixels: pixels
        )

        let match = try OverlapMatcher().match(previous: sequence.previous, current: sequence.current)

        XCTAssertEqual(match.classification, .forward)
        XCTAssertEqual(match.newRowCount, 5)
    }

    func testReverseMotionIsClassifiedSeparately() throws {
        let sequence = try makeSequence(offset: 8)
        let match = try OverlapMatcher().match(previous: sequence.current, current: sequence.previous)

        XCTAssertEqual(match.classification, .reverse)
        XCTAssertEqual(match.newRowCount, 0)
    }

    func testLowTextureAndUnrelatedFramesReturnLowConfidence() throws {
        let flatA = try LumaFrame(width: 16, height: 32, pixels: Array(repeating: 40, count: 512))
        let flatB = try LumaFrame(width: 16, height: 32, pixels: Array(repeating: 41, count: 512))
        XCTAssertEqual(
            try OverlapMatcher().match(previous: flatA, current: flatB).classification,
            .lowConfidence
        )

        let first = try patternedFrame(startRow: 0)
        let unrelated = try patternedFrame(startRow: 200)
        XCTAssertEqual(
            try OverlapMatcher().match(previous: first, current: unrelated).classification,
            .lowConfidence
        )
    }

    func testDimensionMismatchFailsBeforeMatching() throws {
        let first = try LumaFrame(width: 2, height: 2, pixels: [1, 2, 3, 4])
        let second = try LumaFrame(width: 4, height: 1, pixels: [1, 2, 3, 4])
        XCTAssertThrowsError(try OverlapMatcher().match(previous: first, current: second)) {
            XCTAssertEqual($0 as? ScrollCaptureError, .frameDimensionsChanged)
        }
    }

    private func makeSequence(
        offset: Int,
        height: Int = 32
    ) throws -> (previous: LumaFrame, current: LumaFrame) {
        (
            previous: try patternedFrame(startRow: 0, height: height),
            current: try patternedFrame(startRow: offset, height: height)
        )
    }

    private func patternedFrame(startRow: Int, width: Int = 16, height: Int = 32) throws -> LumaFrame {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height)
        for y in startRow..<(startRow + height) {
            for x in 0..<width {
                var value = UInt64(y) &* 0x9E37_79B1_85EB_CA87
                value ^= UInt64(x) &* 0xC2B2_AE3D_27D4_EB4F
                value ^= value >> 29
                value &*= 0x1656_67B1_9E37_79F9
                value ^= value >> 32
                pixels.append(UInt8(truncatingIfNeeded: value >> 24))
            }
        }
        return try LumaFrame(width: width, height: height, pixels: pixels)
    }

    private func replacingEdges(
        in frame: LumaFrame,
        edgeRows: Int,
        value: UInt8
    ) throws -> LumaFrame {
        var pixels = frame.pixels
        for y in 0..<edgeRows {
            pixels.replaceSubrange((y * frame.width)..<((y + 1) * frame.width), with: repeatElement(value, count: frame.width))
        }
        for y in (frame.height - edgeRows)..<frame.height {
            pixels.replaceSubrange((y * frame.width)..<((y + 1) * frame.width), with: repeatElement(value, count: frame.width))
        }
        return try LumaFrame(width: frame.width, height: frame.height, pixels: pixels)
    }
}
