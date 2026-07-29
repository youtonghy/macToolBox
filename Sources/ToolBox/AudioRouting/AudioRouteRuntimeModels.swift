import CoreAudio
import Foundation

struct AudioFormatFingerprint: Hashable, Sendable {
    let sampleRateBits: UInt64
    let formatID: UInt32
    let formatFlags: UInt32
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channelsPerFrame: UInt32
    let bitsPerChannel: UInt32

    var sampleRate: Double { Double(bitPattern: sampleRateBits) }

    init(_ value: AudioStreamBasicDescription) {
        sampleRateBits = value.mSampleRate.bitPattern
        formatID = value.mFormatID
        formatFlags = value.mFormatFlags
        bytesPerPacket = value.mBytesPerPacket
        framesPerPacket = value.mFramesPerPacket
        bytesPerFrame = value.mBytesPerFrame
        channelsPerFrame = value.mChannelsPerFrame
        bitsPerChannel = value.mBitsPerChannel
    }
}

struct HALRouteObservation: Equatable, Sendable {
    let outputDeviceID: AudioObjectID
    let outputFormat: AudioFormatFingerprint
    let processDeviceIDsByObjectID: [UInt32: [AudioObjectID]]
    let tapFormatsByProcessObjectID: [UInt32: AudioFormatFingerprint]
    let aggregateFormatsByProcessObjectID: [UInt32: AudioFormatFingerprint]
}

struct HALObservationSnapshot: Equatable, Sendable {
    let audioServerGeneration: UInt64
    let routesByID: [String: HALRouteObservation]
}

struct AudioRuntimeIntent: Equatable, Sendable {
    let generation: UInt64
    let plansByID: [String: AudioRoutePlan]
    let mutedRouteIDs: Set<String>
    let graphFingerprint: Int
    let parameterFingerprint: Int

    init(
        generation: UInt64,
        plansByID: [String: AudioRoutePlan],
        mutedRouteIDs: Set<String>
    ) {
        self.generation = generation
        self.plansByID = plansByID
        self.mutedRouteIDs = mutedRouteIDs
        graphFingerprint = Self.hashGraph(plansByID)
        parameterFingerprint = Self.hashParameters(plansByID, mutedRouteIDs)
    }

    private static func hashGraph(_ plansByID: [String: AudioRoutePlan]) -> Int {
        var hasher = Hasher()

        for routeID in plansByID.keys.sorted() {
            guard let plan = plansByID[routeID] else { continue }

            hasher.combine(routeID)
            hasher.combine(plan.outputDeviceUID)
            hasher.combine(plan.deviceConfigurationGeneration)
            hasher.combine(plan.sources.count)
            for (index, source) in plan.sources.enumerated() {
                hasher.combine(index)
                hasher.combine(source.processObjectID)
            }
        }

        return hasher.finalize()
    }

    private static func hashParameters(
        _ plansByID: [String: AudioRoutePlan],
        _ mutedRouteIDs: Set<String>
    ) -> Int {
        var hasher = Hasher()

        for routeID in plansByID.keys.sorted() {
            guard let plan = plansByID[routeID] else { continue }

            hasher.combine(routeID)
            hasher.combine(plan.sources.count)
            for (index, source) in plan.sources.enumerated() {
                hasher.combine(index)
                hasher.combine(source.processObjectID)
                hasher.combine(source.linearGain.bitPattern)
            }
        }

        for routeID in mutedRouteIDs.sorted() {
            hasher.combine(routeID)
        }

        return hasher.finalize()
    }
}

struct RealizationKey: Hashable, Sendable {
    let graphFingerprint: Int
    let processDeviceFingerprint: Int
    let outputFormat: AudioFormatFingerprint
    let tapFormatFingerprint: Int
    let aggregateFormatFingerprint: Int
    let audioServerGeneration: UInt64

    init?(
        routeID: String,
        intent: AudioRuntimeIntent,
        observation: HALObservationSnapshot
    ) {
        guard intent.plansByID[routeID] != nil,
              let routeObservation = observation.routesByID[routeID]
        else {
            return nil
        }

        graphFingerprint = intent.graphFingerprint
        processDeviceFingerprint = Self.hashProcessDeviceIDs(
            routeObservation.processDeviceIDsByObjectID
        )
        outputFormat = routeObservation.outputFormat
        tapFormatFingerprint = Self.hashFormats(
            routeObservation.tapFormatsByProcessObjectID
        )
        aggregateFormatFingerprint = Self.hashFormats(
            routeObservation.aggregateFormatsByProcessObjectID
        )
        audioServerGeneration = observation.audioServerGeneration
    }

    private static func hashProcessDeviceIDs(
        _ processDeviceIDsByObjectID: [UInt32: [AudioObjectID]]
    ) -> Int {
        var hasher = Hasher()

        for processObjectID in processDeviceIDsByObjectID.keys.sorted() {
            guard let deviceIDs = processDeviceIDsByObjectID[processObjectID] else { continue }

            hasher.combine(processObjectID)
            for deviceID in deviceIDs.sorted() {
                hasher.combine(deviceID)
            }
        }

        return hasher.finalize()
    }

    private static func hashFormats(
        _ formatsByProcessObjectID: [UInt32: AudioFormatFingerprint]
    ) -> Int {
        var hasher = Hasher()

        for processObjectID in formatsByProcessObjectID.keys.sorted() {
            guard let format = formatsByProcessObjectID[processObjectID] else { continue }

            hasher.combine(processObjectID)
            hasher.combine(format)
        }

        return hasher.finalize()
    }
}

enum HALStage: String, Sendable {
    case observe, prepareKernel, createTap, createAggregate, createIOProc
    case startCapture, startOutput, commit, stopIOProc, destroyAggregate, destroyTap
}

enum HALResourceKind: String, Sendable {
    case processTap, aggregateDevice, captureIOProc, outputIOProc, realtimeKernel
}

enum AudioRuntimeFailure: Error, Equatable, Sendable {
    case invalidIntent(String)
    case objectUnavailable(kind: HALResourceKind, id: UInt32)
    case unsupportedFormat(routeID: String, observed: AudioFormatFingerprint)
    case prepareFailed(routeID: String, stage: HALStage, status: OSStatus)
    case commitFailed(
        routeID: String,
        stage: HALStage,
        status: OSStatus,
        rollbackSucceeded: Bool
    )
    case cleanupDeferred(routeID: String, resources: [HALResourceKind])
    case audioServerRestarted
}
