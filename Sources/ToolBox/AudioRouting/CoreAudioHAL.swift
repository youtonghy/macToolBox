import CoreAudio
import Foundation

protocol CoreAudioHALPort: AnyObject {
    func observe(_ request: HALObservationRequest) throws -> HALObservationSnapshot
    func execute(_ transaction: HALTransaction) throws -> HALTransactionReceipt
    func changes(for observations: Set<HALObservation>) -> AsyncStream<HALChange>
}

struct HALObservationRequest: Equatable, Sendable {
    let intent: AudioRuntimeIntent
}

enum HALObservation: Hashable, Sendable {
    case processDevices(AudioObjectID)
    case tapFormat(AudioObjectID)
    case aggregateInputStreams(AudioObjectID)
    case aggregateInputFormat(AudioObjectID)
    case outputAlive(AudioObjectID)
    case outputStreams(AudioObjectID)
    case outputNominalRate(AudioObjectID)
    case outputStreamFormat(AudioObjectID)
    case audioServerGeneration
}

enum HALChange: Equatable, Sendable {
    case propertyChanged
    case audioServerRestarted
}

enum HALTransactionKind: Equatable, Sendable {
    case muteOld
    case fadeOldToZero
    case prepareCandidate
    case startCandidateCapture
    case prerollCandidate
    case commitCandidate
    case fadeInCandidate
    case detachOld
    case stopOldCapture
    case drainOldCallbacks
    case destroyOld
    case destroyTap
    case shutdown
}

struct HALTransaction: Sendable {
    let kind: HALTransactionKind
    let routeID: String
    let sourceIDs: [UInt32]
    let intent: AudioRuntimeIntent
    let observation: HALObservationSnapshot
    let replacingKeysByRouteID: [String: RealizationKey]
}

enum HALRollbackResult: Equatable, Sendable {
    case succeeded
    case deferred(resources: [HALResourceKind])
}

struct HALTransactionReceipt: @unchecked Sendable {
    let realizedKeysByRouteID: [String: RealizationKey]
    let activeOutputUIDs: Set<String>
    let rollback: @Sendable () -> HALRollbackResult
}

enum AudioRuntimeApplyResult: Equatable, Sendable {
    case applied
    case unchanged
}

enum HALCapability: Hashable, Sendable {
    case parallelCapture
}

enum HALOperation: Equatable, Sendable {
    case muteOld(UInt32)
    case fadeOldToZero(UInt32)
    case prepareCandidate(UInt32)
    case startCandidateCapture(UInt32)
    case prerollCandidate(UInt32)
    case commitCandidate(UInt32)
    case fadeInCandidate(UInt32)
    case detachOld(UInt32)
    case stopOldCapture(UInt32)
    case drainOldCallbacks(UInt32)
    case destroyOld(UInt32)
    case destroyTap(UInt32)
}

protocol AudioRouteRuntimeControlling: AnyObject {
    func converge(to intent: AudioRuntimeIntent) throws -> AudioRuntimeApplyResult
    func snapshot() -> [AudioRouteDiagnosticsSnapshot]
    func performMaintenance() -> Bool
    func shutdown(reason: AudioRouteStopReason) -> AudioRouteStopReport
}
