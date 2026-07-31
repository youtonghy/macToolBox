import Foundation

struct FrameStabilityDetector {
    private let configuration: ScrollMatchingConfiguration
    private var previousFrame: LumaFrame?
    private var previousTimestamp: TimeInterval?
    private var consecutiveQuietSamples = 0

    init(configuration: ScrollMatchingConfiguration = ScrollMatchingConfiguration()) {
        self.configuration = configuration
    }

    mutating func observe(_ frame: LumaFrame, timestamp: TimeInterval) throws -> FrameStability {
        guard timestamp.isFinite,
              previousTimestamp.map({ timestamp > $0 }) ?? true
        else {
            throw ScrollCaptureError.nonMonotonicTimestamp
        }
        guard let previousFrame else {
            consecutiveQuietSamples = 0
            self.previousFrame = frame
            previousTimestamp = timestamp
            return .moving(consecutiveQuietSamples: 0)
        }
        guard previousFrame.width == frame.width, previousFrame.height == frame.height else {
            consecutiveQuietSamples = 0
            throw ScrollCaptureError.frameDimensionsChanged
        }

        let totalDifference = zip(previousFrame.pixels, frame.pixels).reduce(0.0) { partial, pair in
            partial + Double(abs(Int(pair.0) - Int(pair.1)))
        }
        let meanDifference = totalDifference / Double(frame.pixels.count)
        if meanDifference <= configuration.stableMeanDifferenceThreshold {
            consecutiveQuietSamples += 1
        } else {
            consecutiveQuietSamples = 0
        }
        self.previousFrame = frame
        previousTimestamp = timestamp
        if consecutiveQuietSamples >= configuration.requiredStableSamples {
            return .stable
        }
        return .moving(consecutiveQuietSamples: consecutiveQuietSamples)
    }

    mutating func reset() {
        previousFrame = nil
        previousTimestamp = nil
        consecutiveQuietSamples = 0
    }
}
