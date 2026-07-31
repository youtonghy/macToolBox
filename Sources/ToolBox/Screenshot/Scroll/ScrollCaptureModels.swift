import Foundation

enum ScrollCaptureError: Error, Equatable {
    case invalidLumaFrame
    case frameDimensionsChanged
    case nonMonotonicTimestamp
    case insufficientComparableContent
    case invalidStrip
    case resourceLimitReached
    case storageFailure
    case corruptMetadata
}

struct ScrollMatchingConfiguration: Equatable, Sendable {
    var requiredStableSamples: Int
    var stableMeanDifferenceThreshold: Double
    var maximumOffsetRows: Int
    var minimumOverlapRows: Int
    var maximumNormalizedError: Double
    var minimumConfidenceMargin: Double
    var minimumTexture: Double
    var outlierFraction: Double

    init(
        requiredStableSamples: Int = 2,
        stableMeanDifferenceThreshold: Double = 1,
        maximumOffsetRows: Int = 16,
        minimumOverlapRows: Int = 8,
        maximumNormalizedError: Double = 0.08,
        minimumConfidenceMargin: Double = 0.01,
        minimumTexture: Double = 0.015,
        outlierFraction: Double = 0.05
    ) {
        self.requiredStableSamples = max(1, requiredStableSamples)
        self.stableMeanDifferenceThreshold = max(0, stableMeanDifferenceThreshold)
        self.maximumOffsetRows = max(1, maximumOffsetRows)
        self.minimumOverlapRows = max(1, minimumOverlapRows)
        self.maximumNormalizedError = max(0, maximumNormalizedError)
        self.minimumConfidenceMargin = max(0, minimumConfidenceMargin)
        self.minimumTexture = max(0, minimumTexture)
        self.outlierFraction = min(0.25, max(0, outlierFraction))
    }
}

struct LumaFrame: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) throws {
        guard width > 0,
              height > 0,
              !width.multipliedReportingOverflow(by: height).overflow,
              pixels.count == width * height
        else {
            throw ScrollCaptureError.invalidLumaFrame
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    subscript(x: Int, y: Int) -> UInt8 {
        pixels[y * width + x]
    }
}

enum FrameStability: Equatable, Sendable {
    case moving(consecutiveQuietSamples: Int)
    case stable
}

enum OverlapClassification: Equatable, Sendable {
    case forward
    case noMovement
    case reverse
    case lowConfidence
}

struct OverlapMatch: Equatable, Sendable {
    let classification: OverlapClassification
    let overlapRowCount: Int
    let newRowCount: Int
    let confidence: Double
    let normalizedError: Double
}
