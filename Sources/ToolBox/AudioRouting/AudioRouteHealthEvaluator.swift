import Foundation

struct AudioRouteHealthPolicy: Equatable, Sendable {
    let watchdogInterval: Duration = .milliseconds(250)
    let stalledTickLimit = 2
    let nonFiniteTickLimit = 2
    let resyncLimitPerSecond: UInt64 = 2
    let overloadPeriodLimit: UInt64 = 2
    let degradedWindowLimit = 2
}

struct AudioRouteHealthSample: Equatable, Sendable {
    let captureFrameCount: UInt64
    let outputFrameCount: UInt64
    let underrunFrameCount: UInt64
    let overrunFrameCount: UInt64
    let forcedResyncCount: UInt64
    let formatMismatchCount: UInt64
    let nonFiniteSampleCount: UInt64
    let clippedSampleCount: UInt64
    let outputPeriodFrames: UInt64
    let sourceIsProducingOutput: Bool
}

enum AudioRouteHealthDecision: Equatable, Sendable {
    case healthy
    case observe(AudioRouteHealthReason)
    case degraded(AudioRouteHealthReason)
    case rebuild(AudioRouteHealthReason)
}

enum AudioRouteHealthReason: Equatable, Sendable {
    case formatContractViolation
    case callbackStall
    case nonFiniteInput
    case forcedResyncBurst
    case ringOverload
    case clipping
}

enum AudioRouteHealthEvaluator {
    static func evaluate(
        current: AudioRouteHealthSample,
        previous: AudioRouteHealthSample,
        consecutiveStalledTickCount: Int,
        consecutiveNonFiniteTickCount: Int,
        consecutiveOverloadWindowCount: Int,
        policy: AudioRouteHealthPolicy = .init()
    ) -> AudioRouteHealthDecision {
        if delta(current.formatMismatchCount, previous.formatMismatchCount) > 0 {
            return .rebuild(.formatContractViolation)
        }

        if delta(current.nonFiniteSampleCount, previous.nonFiniteSampleCount) > 0 {
            if consecutiveNonFiniteTickCount >= policy.nonFiniteTickLimit {
                return .rebuild(.nonFiniteInput)
            }
            return .degraded(.nonFiniteInput)
        }

        let outputProgress = delta(current.outputFrameCount, previous.outputFrameCount) > 0
        let legalSilence = !current.sourceIsProducingOutput && outputProgress
        if !legalSilence && consecutiveStalledTickCount > 0 {
            if consecutiveStalledTickCount >= policy.stalledTickLimit {
                return .rebuild(.callbackStall)
            }
            return .degraded(.callbackStall)
        }

        if delta(current.forcedResyncCount, previous.forcedResyncCount) >= policy.resyncLimitPerSecond {
            if consecutiveOverloadWindowCount >= policy.degradedWindowLimit {
                return .rebuild(.forcedResyncBurst)
            }
            return .degraded(.forcedResyncBurst)
        }

        let overloadedFrames = delta(current.underrunFrameCount, previous.underrunFrameCount)
            &+ delta(current.overrunFrameCount, previous.overrunFrameCount)
        let overloadThreshold = current.outputPeriodFrames &* policy.overloadPeriodLimit
        if overloadedFrames > overloadThreshold {
            if consecutiveOverloadWindowCount >= policy.degradedWindowLimit {
                return .rebuild(.ringOverload)
            }
            return .degraded(.ringOverload)
        }

        if delta(current.clippedSampleCount, previous.clippedSampleCount) > 0 {
            return .observe(.clipping)
        }

        return .healthy
    }

    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current &- previous
    }
}
