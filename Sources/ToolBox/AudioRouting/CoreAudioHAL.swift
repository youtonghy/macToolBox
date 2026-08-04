import CoreAudio
import Foundation

protocol CoreAudioHALPort: AnyObject {
    func observe(_ request: HALObservationRequest) throws -> HALObservationSnapshot
    func execute(_ transaction: HALTransaction) throws -> HALTransactionReceipt
    func updateParameters(_ intent: AudioRuntimeIntent) throws
    func changes(for observations: Set<HALObservation>) -> AsyncStream<HALChange>
    func diagnostics() -> [AudioRouteDiagnosticsSnapshot]
    func performMaintenance() -> HALRollbackResult
}

extension CoreAudioHALPort {
    func diagnostics() -> [AudioRouteDiagnosticsSnapshot] { [] }
    func performMaintenance() -> HALRollbackResult { .succeeded }
}

enum CoreAudioHALError: Error, Equatable {
    case status(OSStatus, AudioObjectPropertySelector)
    case missingValue(AudioObjectID, AudioObjectPropertySelector)
}

final class HALListenerReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        lock.lock()
        let cancellation = self.cancellation
        self.cancellation = nil
        lock.unlock()
        cancellation?()
    }

    deinit {
        cancel()
    }
}

protocol CoreAudioPropertyAccess: AnyObject {
    func deviceID(forUID uid: String) throws -> AudioObjectID
    func deviceUID(forID deviceID: AudioObjectID) throws -> String
    func dataSize(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> UInt32
    func readData(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws -> UInt32
    func addListener(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        handler: @escaping @Sendable () -> Void
    ) throws -> HALListenerReceipt
}

final class SystemCoreAudioPropertyAccess: CoreAudioPropertyAccess {
    private let listenerQueue = DispatchQueue(
        label: "com.youtonghy.toolbox.audio-routing.hal-listeners"
    )

    func deviceID(forUID uid: String) throws -> AudioObjectID {
        var address = CoreAudioPropertyReader.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier: CFString? = uid as CFString
        var result = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.stride)
        let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString?>.stride),
                qualifierPointer,
                &size,
                &result
            )
        }
        guard status == noErr else {
            throw CoreAudioHALError.status(status, address.mSelector)
        }
        guard result != kAudioObjectUnknown else {
            throw CoreAudioHALError.missingValue(
                AudioObjectID(kAudioObjectSystemObject),
                address.mSelector
            )
        }
        return result
    }

    func deviceUID(forID deviceID: AudioObjectID) throws -> String {
        var address = CoreAudioPropertyReader.address(kAudioDevicePropertyDeviceUID)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.stride)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                pointer
            )
        }
        guard status == noErr else {
            throw CoreAudioHALError.status(status, address.mSelector)
        }
        return value as String
    }

    func dataSize(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> UInt32 {
        var address = address
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else {
            throw CoreAudioHALError.status(status, address.mSelector)
        }
        return size
    }

    func readData(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws -> UInt32 {
        guard !buffer.isEmpty, let baseAddress = buffer.baseAddress else { return 0 }
        var address = address
        var size = UInt32(buffer.count)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            baseAddress
        )
        guard status == noErr else {
            throw CoreAudioHALError.status(status, address.mSelector)
        }
        return size
    }

    func addListener(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        handler: @escaping @Sendable () -> Void
    ) throws -> HALListenerReceipt {
        var address = address
        let queue = listenerQueue
        let listener: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, listener)
        guard status == noErr else {
            throw CoreAudioHALError.status(status, address.mSelector)
        }
        let registeredAddress = address
        return HALListenerReceipt {
            var removalAddress = registeredAddress
            AudioObjectRemovePropertyListenerBlock(
                objectID,
                &removalAddress,
                queue,
                listener
            )
        }
    }
}

struct HALTapResource: Sendable {
    let objectID: AudioObjectID
    let uid: String
}

final class HALKernelResource: @unchecked Sendable {
    fileprivate var pointer: OpaquePointer?

    init(pointer: OpaquePointer?) {
        self.pointer = pointer
    }
}

final class HALIOProcResource: @unchecked Sendable {
    let deviceID: AudioObjectID
    fileprivate var ioProcID: AudioDeviceIOProcID?
    fileprivate var lease: OpaquePointer?

    init(
        deviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID?,
        lease: OpaquePointer?
    ) {
        self.deviceID = deviceID
        self.ioProcID = ioProcID
        self.lease = lease
    }
}

@available(macOS 14.2, *)
protocol CoreAudioResourceAccess: AnyObject {
    func createKernel(
        generation: UInt64,
        sourceFormats: [AudioFormatFingerprint],
        outputFormat: AudioFormatFingerprint,
        targetFrames: UInt32,
        rampFrames: UInt32,
        gains: [Float]
    ) throws -> HALKernelResource
    func detachKernel(_ kernel: HALKernelResource)
    func destroyKernel(_ kernel: HALKernelResource)
    func createProcessTap(
        routeID: String,
        processObjectID: AudioObjectID,
        deviceUID: String?
    ) throws -> HALTapResource
    func destroyProcessTap(_ tap: HALTapResource) -> OSStatus
    func createAggregate(
        routeID: String,
        outputDeviceUID: String,
        tapUID: String
    ) throws -> AudioObjectID
    func destroyAggregate(_ aggregateID: AudioObjectID) -> OSStatus
    func createCaptureIOProc(
        deviceID: AudioObjectID,
        kernel: HALKernelResource,
        generation: UInt64,
        sourceIndex: UInt32
    ) throws -> HALIOProcResource
    func createOutputIOProc(
        deviceID: AudioObjectID,
        kernel: HALKernelResource,
        generation: UInt64
    ) throws -> HALIOProcResource
    func setSourceGain(_ gain: Float, index: UInt32, kernel: HALKernelResource)
    func setSourceMuted(
        _ muted: Bool,
        index: UInt32,
        rampFrames: UInt32,
        kernel: HALKernelResource
    )
    func snapshot(_ kernel: HALKernelResource) -> TBAudioRealtimeSnapshot?
    func start(_ ioProc: HALIOProcResource) -> OSStatus
    func detach(_ ioProc: HALIOProcResource)
    func stop(_ ioProc: HALIOProcResource) -> OSStatus
    func destroyIOProc(_ ioProc: HALIOProcResource) -> OSStatus
    func destroyLease(_ ioProc: HALIOProcResource) -> OSStatus
}

@available(macOS 14.2, *)
final class SystemCoreAudioResourceAccess: CoreAudioResourceAccess {
    func createKernel(
        generation: UInt64,
        sourceFormats: [AudioFormatFingerprint],
        outputFormat: AudioFormatFingerprint,
        targetFrames: UInt32,
        rampFrames: UInt32,
        gains: [Float]
    ) throws -> HALKernelResource {
        do {
            for sourceFormat in sourceFormats {
                _ = try AudioFormatContract.negotiate(
                    source: sourceFormat.streamDescription,
                    output: outputFormat.streamDescription
                )
            }
        } catch {
            throw AudioRuntimeFailure.prepareFailed(
                routeID: "",
                stage: .prepareKernel,
                status: kAudioDeviceUnsupportedFormatError
            )
        }
        let sourceRealtimeFormats = sourceFormats.map(Self.realtimeFormat)
        guard !sourceRealtimeFormats.isEmpty else {
            throw AudioRuntimeFailure.invalidIntent("An audio route needs at least one source.")
        }
        let pointer = gains.withUnsafeBufferPointer { gainsBuffer in
            sourceRealtimeFormats.withUnsafeBufferPointer { buffer in
                TBAudioRealtimeKernelCreate(
                    generation,
                    buffer.baseAddress!,
                    UInt32(buffer.count),
                    Self.realtimeFormat(outputFormat),
                    targetFrames,
                    1 << 16,
                    rampFrames,
                    gainsBuffer.baseAddress
                )
            }
        }
        guard let pointer else {
            throw AudioRuntimeFailure.prepareFailed(
                routeID: "",
                stage: .prepareKernel,
                status: kAudioHardwareUnspecifiedError
            )
        }
        return HALKernelResource(pointer: pointer)
    }

    func destroyKernel(_ kernel: HALKernelResource) {
        TBAudioRealtimeKernelDestroy(kernel.pointer)
        kernel.pointer = nil
    }

    func detachKernel(_ kernel: HALKernelResource) {
        TBAudioRealtimeKernelDetach(kernel.pointer)
    }

    func createProcessTap(
        routeID: String,
        processObjectID: AudioObjectID,
        deviceUID: String?
    ) throws -> HALTapResource {
        let description: CATapDescription
        if let deviceUID {
            description = CATapDescription(
                processes: [processObjectID],
                deviceUID: deviceUID,
                stream: 0
            )
        } else {
            description = CATapDescription(
                stereoMixdownOfProcesses: [processObjectID]
            )
        }
        description.name = "ToolBox \(routeID) \(processObjectID)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        if #available(macOS 26.0, *) {
            description.isProcessRestoreEnabled = true
        }
        var objectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(description, &objectID)
        guard status == noErr else {
            throw AudioRuntimeFailure.prepareFailed(
                routeID: routeID,
                stage: .createTap,
                status: status
            )
        }
        return HALTapResource(objectID: objectID, uid: description.uuid.uuidString)
    }

    func destroyProcessTap(_ tap: HALTapResource) -> OSStatus {
        AudioHardwareDestroyProcessTap(tap.objectID)
    }

    func createAggregate(
        routeID: String,
        outputDeviceUID: String,
        tapUID: String
    ) throws -> AudioObjectID {
        let aggregateUID = "com.youtonghy.toolbox.capture.\(UUID().uuidString)"
        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true,
        ]
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ToolBox Capture \(routeID)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [tapEntry],
            kAudioAggregateDeviceClockDeviceKey: outputDeviceUID,
        ]
        var objectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(
            composition as CFDictionary,
            &objectID
        )
        guard status == noErr else {
            throw AudioRuntimeFailure.prepareFailed(
                routeID: routeID,
                stage: .createAggregate,
                status: status
            )
        }
        return objectID
    }

    func destroyAggregate(_ aggregateID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(aggregateID)
    }

    func createCaptureIOProc(
        deviceID: AudioObjectID,
        kernel: HALKernelResource,
        generation: UInt64,
        sourceIndex: UInt32
    ) throws -> HALIOProcResource {
        guard let kernelPointer = kernel.pointer else {
            throw AudioRuntimeFailure.prepareFailed(
                routeID: "",
                stage: .createIOProc,
                status: kAudioHardwareIllegalOperationError
            )
        }
        var ioProcID: AudioDeviceIOProcID?
        var lease: OpaquePointer?
        let status = TBAudioCreateCaptureIOProc(
            deviceID,
            kernelPointer,
            generation,
            sourceIndex,
            &ioProcID,
            &lease
        )
        guard status == noErr else {
            throw AudioRuntimeFailure.prepareFailed(
                routeID: "",
                stage: .createIOProc,
                status: status
            )
        }
        return HALIOProcResource(deviceID: deviceID, ioProcID: ioProcID, lease: lease)
    }

    func createOutputIOProc(
        deviceID: AudioObjectID,
        kernel: HALKernelResource,
        generation: UInt64
    ) throws -> HALIOProcResource {
        guard let kernelPointer = kernel.pointer else {
            throw AudioRuntimeFailure.prepareFailed(
                routeID: "",
                stage: .createIOProc,
                status: kAudioHardwareIllegalOperationError
            )
        }
        var ioProcID: AudioDeviceIOProcID?
        var lease: OpaquePointer?
        let status = TBAudioCreateOutputIOProc(
            deviceID,
            kernelPointer,
            generation,
            &ioProcID,
            &lease
        )
        guard status == noErr else {
            throw AudioRuntimeFailure.prepareFailed(
                routeID: "",
                stage: .createIOProc,
                status: status
            )
        }
        return HALIOProcResource(deviceID: deviceID, ioProcID: ioProcID, lease: lease)
    }

    func snapshot(_ kernel: HALKernelResource) -> TBAudioRealtimeSnapshot? {
        var value = TBAudioRealtimeSnapshot()
        return TBAudioRealtimeKernelCopySnapshot(kernel.pointer, &value) ? value : nil
    }

    func setSourceGain(_ gain: Float, index: UInt32, kernel: HALKernelResource) {
        TBAudioRealtimeKernelSetSourceGain(kernel.pointer, index, gain)
    }

    func setSourceMuted(
        _ muted: Bool,
        index: UInt32,
        rampFrames: UInt32,
        kernel: HALKernelResource
    ) {
        TBAudioRealtimeKernelSetSourceMuted(kernel.pointer, index, muted, rampFrames)
    }

    func start(_ ioProc: HALIOProcResource) -> OSStatus {
        guard let ioProcID = ioProc.ioProcID else { return kAudioHardwareBadObjectError }
        return AudioDeviceStart(ioProc.deviceID, ioProcID)
    }

    func detach(_ ioProc: HALIOProcResource) {
        TBAudioDetachIOProcLease(ioProc.lease)
    }

    func stop(_ ioProc: HALIOProcResource) -> OSStatus {
        guard let ioProcID = ioProc.ioProcID else { return noErr }
        return AudioDeviceStop(ioProc.deviceID, ioProcID)
    }

    func destroyIOProc(_ ioProc: HALIOProcResource) -> OSStatus {
        guard let ioProcID = ioProc.ioProcID else { return noErr }
        let status = AudioDeviceDestroyIOProcID(ioProc.deviceID, ioProcID)
        if TBAudioObjectDestructionComplete(status) {
            ioProc.ioProcID = nil
        }
        return status
    }

    func destroyLease(_ ioProc: HALIOProcResource) -> OSStatus {
        guard TBAudioIOProcLeaseInFlight(ioProc.lease) == 0 else {
            return kAudioHardwareNotRunningError
        }
        guard TBAudioDestroyIOProcLease(ioProc.lease) else {
            return kAudioHardwareUnspecifiedError
        }
        ioProc.lease = nil
        return noErr
    }

    private static func realtimeFormat(
        _ format: AudioFormatFingerprint
    ) -> TBAudioRealtimeFormat {
        TBAudioRealtimeFormat(
            sampleRate: format.sampleRate,
            formatID: format.formatID,
            formatFlags: format.formatFlags,
            bytesPerPacket: format.bytesPerPacket,
            framesPerPacket: format.framesPerPacket,
            bytesPerFrame: format.bytesPerFrame,
            channelsPerFrame: format.channelsPerFrame,
            bitsPerChannel: format.bitsPerChannel
        )
    }
}

@available(macOS 14.2, *)
final class SystemCoreAudioHAL: CoreAudioHALPort, @unchecked Sendable {
    private final class SourceResources: @unchecked Sendable {
        var tap: HALTapResource?
        var aggregateID: AudioObjectID?
        var captureIOProc: HALIOProcResource?
        var processObjectID: UInt32 = 0
        var captureDeviceUID: String? = nil
    }

    /// Identity of a process tap: a tap is reusable across output-device switches
    /// only when both the captured process and its capture device binding match.
    /// In the common REDIRECT case `selectCaptureDevice` binds the tap to the app's
    /// original output device, which is independent of the route's target output,
    /// so the binding is identical across switches and the tap can be reused.
    private struct TapKey: Hashable {
        let processObjectID: UInt32
        let captureDeviceUID: String?
    }

    private final class RouteResources: @unchecked Sendable {
        let lock = NSLock()
        let routeID: String
        var generation: UInt64
        var rampFrames: UInt32 = 1
        var kernel: HALKernelResource?
        var outputIOProc: HALIOProcResource?
        var sources: [SourceResources] = []

        init(routeID: String, generation: UInt64) {
            self.routeID = routeID
            self.generation = generation
        }
    }

    private final class ListenerBag: @unchecked Sendable {
        private let lock = NSLock()
        private var receipts: [HALListenerReceipt] = []

        func append(_ receipt: HALListenerReceipt) {
            lock.lock()
            receipts.append(receipt)
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            let receipts = self.receipts
            self.receipts = []
            lock.unlock()
            for receipt in receipts {
                receipt.cancel()
            }
        }
    }

    private let propertyAccess: any CoreAudioPropertyAccess
    private let resourceAccess: any CoreAudioResourceAccess
    private let generationLock = NSLock()
    private let realizationLock = NSLock()
    private var audioServerGeneration: UInt64 = 0
    private var activeRoutes: [String: RouteResources] = [:]
    private var pendingCleanupRoutes: [String: RouteResources] = [:]

    init(
        propertyAccess: any CoreAudioPropertyAccess = SystemCoreAudioPropertyAccess(),
        resourceAccess: any CoreAudioResourceAccess = SystemCoreAudioResourceAccess()
    ) {
        self.propertyAccess = propertyAccess
        self.resourceAccess = resourceAccess
    }

    func observe(_ request: HALObservationRequest) throws -> HALObservationSnapshot {
        var routes: [String: HALRouteObservation] = [:]
        for routeID in request.intent.plansByID.keys.sorted() {
            do {
                guard let plan = request.intent.plansByID[routeID] else { continue }
                let activeRoute = activeRoute(for: routeID)
                let outputID = try propertyAccess.deviceID(forUID: plan.outputDeviceUID)
                let outputAlive: UInt32 = try value(
                    objectID: outputID,
                    selector: kAudioDevicePropertyDeviceIsAlive,
                    initial: UInt32(0)
                )
                guard outputAlive != 0 else {
                    throw AudioRuntimeFailure.objectUnavailable(
                        kind: .outputIOProc,
                        id: outputID
                    )
                }
                let outputFormat = try firstStreamFormat(
                    deviceID: outputID,
                    scope: kAudioObjectPropertyScopeOutput
                )
                let nominalRate: Float64 = try value(
                    objectID: outputID,
                    selector: kAudioDevicePropertyNominalSampleRate,
                    initial: Float64(0)
                )
                guard TBAudioSampleRatesCompatible(nominalRate, outputFormat.mSampleRate) else {
                    throw AudioRuntimeFailure.unsupportedFormat(
                        routeID: routeID,
                        observed: AudioFormatFingerprint(outputFormat)
                    )
                }

                var processDevices: [UInt32: [AudioObjectID]] = [:]
                var tapFormats: [UInt32: AudioFormatFingerprint] = [:]
                var aggregateFormats: [UInt32: AudioFormatFingerprint] = [:]
                for (sourceIndex, source) in plan.sources.enumerated() {
                    let devices: [AudioObjectID] = try values(
                        objectID: source.processObjectID,
                        selector: kAudioProcessPropertyDevices,
                        scope: kAudioObjectPropertyScopeOutput
                    )
                    processDevices[source.processObjectID] = devices
                    let captureDeviceID =
                        selectCaptureDevice(
                            processObjectID: source.processObjectID,
                            outputDeviceID: outputID,
                            processDeviceIDs: devices
                        ) ?? outputID
                    if let activeRoute,
                        activeRoute.sources.indices.contains(sourceIndex),
                        let tap = activeRoute.sources[sourceIndex].tap,
                        let aggregateID = activeRoute.sources[sourceIndex].aggregateID
                    {
                        let tapFormat: AudioStreamBasicDescription = try value(
                            objectID: tap.objectID,
                            selector: kAudioTapPropertyFormat,
                            initial: AudioStreamBasicDescription()
                        )
                        let aggregateFormat = try captureFormat(
                            aggregateID: aggregateID,
                            fallback: tapFormat
                        )
                        tapFormats[source.processObjectID] = AudioFormatFingerprint(tapFormat)
                        aggregateFormats[source.processObjectID] =
                            AudioFormatFingerprint(aggregateFormat)
                    } else {
                        let format = try firstStreamFormat(
                            deviceID: captureDeviceID,
                            scope: kAudioObjectPropertyScopeOutput
                        )
                        let fingerprint = AudioFormatFingerprint(format)
                        tapFormats[source.processObjectID] = fingerprint
                        aggregateFormats[source.processObjectID] = fingerprint
                    }
                }

                routes[routeID] = HALRouteObservation(
                    outputDeviceID: outputID,
                    outputFormat: AudioFormatFingerprint(outputFormat),
                    processDeviceIDsByObjectID: processDevices,
                    tapFormatsByProcessObjectID: tapFormats,
                    aggregateFormatsByProcessObjectID: aggregateFormats
                )
            } catch {
                throw attributed(error, to: routeID, stage: .observe)
            }
        }
        return HALObservationSnapshot(
            audioServerGeneration: currentAudioServerGeneration(),
            routesByID: routes
        )
    }

    func execute(_ transaction: HALTransaction) throws -> HALTransactionReceipt {
        if case .deferred(let failures) = performMaintenance() {
            throw AudioRuntimeFailure.cleanupDeferred(
                routeID: failures.first?.routeID ?? transaction.routeID,
                failures: failures
            )
        }
        if transaction.intent.plansByID.isEmpty {
            let routes = takeActiveRoutes()
            let result = cleanup(routes: Array(routes.values))
            if case .deferred(let failures) = result {
                retainPendingCleanup(routes)
                throw AudioRuntimeFailure.cleanupDeferred(
                    routeID: transaction.routeID,
                    failures: failures
                )
            }
            return HALTransactionReceipt(
                realizedKeysByRouteID: [:],
                activeOutputUIDs: [],
                rollback: { .succeeded }
            )
        }

        let realizedKeys = try realizationKeys(
            intent: transaction.intent,
            observation: transaction.observation
        )
        realizationLock.lock()
        let currentRouteIDs = Set(activeRoutes.keys)
        realizationLock.unlock()
        let desiredRouteIDs = Set(transaction.intent.plansByID.keys)
        let replacingRouteIDs = desiredRouteIDs.filter { routeID in
            transaction.replacingKeysByRouteID[routeID] != realizedKeys[routeID]
                || !currentRouteIDs.contains(routeID)
        }
        let removedRouteIDs = currentRouteIDs.subtracting(desiredRouteIDs)
        let replacedRoutes = takeActiveRoutes(
            routeIDs: replacingRouteIDs.union(removedRouteIDs)
        )
        // Harvest reusable process taps from the routes we are about to tear down.
        // A tap survives the output-device switch (its process + capture device are
        // unchanged) so it can be claimed by the replacing route instead of being
        // destroyed and recreated — skipping the slow create/destroy and the
        // unmute glitch from `mutedWhenTapped` toggling.
        var harvested: [TapKey: HALTapResource] = [:]
        var spared: Set<AudioObjectID> = []
        for route in replacedRoutes.values {
            for source in route.sources {
                guard let tap = source.tap else { continue }
                let key = TapKey(
                    processObjectID: source.processObjectID,
                    captureDeviceUID: source.captureDeviceUID
                )
                harvested[key] = tap
                spared.insert(tap.objectID)
            }
        }
        if !replacedRoutes.isEmpty {
            let result = cleanup(routes: Array(replacedRoutes.values), sparingTaps: spared)
            if case .deferred(let failures) = result {
                retainPendingCleanup(replacedRoutes)
                // The spared taps were detached from their routes (source.tap = nil)
                // above but never destroyed, and no replacing route will claim them
                // now that the transaction is aborting — destroy them here or they
                // leak as live Core Audio process taps.
                for (_, tap) in harvested {
                    _ = resourceAccess.destroyProcessTap(tap)
                }
                throw AudioRuntimeFailure.cleanupDeferred(
                    routeID: transaction.routeID,
                    failures: failures
                )
            }
        }

        var candidates: [String: RouteResources] = [:]
        do {
            for routeID in replacingRouteIDs.sorted() {
                guard let plan = transaction.intent.plansByID[routeID],
                    let observation = transaction.observation.routesByID[routeID]
                else {
                    throw AudioRuntimeFailure.invalidIntent(
                        "HAL observation is incomplete for route \(routeID)."
                    )
                }
                candidates[routeID] = try prepareRoute(
                    routeID: routeID,
                    plan: plan,
                    observation: observation,
                    generation: transaction.intent.generation,
                    muted: transaction.intent.mutedRouteIDs.contains(routeID),
                    reusableTaps: &harvested
                )
            }
            try updateParameters(
                transaction.intent,
                routeIDs: desiredRouteIDs.subtracting(replacingRouteIDs)
            )
        } catch {
            let result = cleanup(routes: Array(candidates.values))
            if case .deferred = result {
                retainPendingCleanup(candidates)
            }
            // Destroy any harvested taps that no replacing route claimed before
            // propagating the failure. A reused tap is removed from `harvested`
            // when consumed, so candidate cleanup (which now owns it) destroys it —
            // there is no double-destroy.
            for (_, tap) in harvested {
                _ = resourceAccess.destroyProcessTap(tap)
            }
            throw error
        }
        // All replacing routes succeeded: any tap still in `harvested` was not
        // claimed (e.g. its process moved to a different capture device), so
        // destroy it now.
        for (_, tap) in harvested {
            _ = resourceAccess.destroyProcessTap(tap)
        }

        realizationLock.lock()
        activeRoutes.merge(candidates) { _, candidate in candidate }
        let committedRoutes = activeRoutes
        realizationLock.unlock()
        for route in committedRoutes.values {
            route.lock.lock()
            route.generation = transaction.intent.generation
            route.lock.unlock()
        }
        let candidateRouteIDs = Set(candidates.keys)
        return HALTransactionReceipt(
            realizedKeysByRouteID: realizedKeys,
            activeOutputUIDs: Set(
                transaction.intent.plansByID.values.map(\.outputDeviceUID)
            ),
            rollback: { [weak self] in
                guard let self else {
                    return .deferred(failures: [
                        HALCleanupFailure(
                            routeID: transaction.routeID,
                            resource: .realtimeKernel,
                            objectID: nil,
                            stage: .destroyKernel,
                            status: kAudioHardwareUnspecifiedError
                        )
                    ])
                }
                let routes = self.takeActiveRoutes(routeIDs: candidateRouteIDs)
                let result = self.cleanup(routes: Array(routes.values))
                if case .deferred = result {
                    self.retainPendingCleanup(routes)
                }
                return result
            }
        )
    }

    private func realizationKeys(
        intent: AudioRuntimeIntent,
        observation: HALObservationSnapshot
    ) throws -> [String: RealizationKey] {
        try intent.plansByID.keys.reduce(into: [String: RealizationKey]()) { result, routeID in
            guard let key = RealizationKey(
                routeID: routeID,
                intent: intent,
                observation: observation
            ) else {
                throw AudioRuntimeFailure.invalidIntent(
                    "HAL observation is incomplete for route \(routeID)."
                )
            }
            result[routeID] = key
        }
    }

    func updateParameters(_ intent: AudioRuntimeIntent) throws {
        try updateParameters(intent, routeIDs: Set(intent.plansByID.keys))
    }

    private func updateParameters(
        _ intent: AudioRuntimeIntent,
        routeIDs: Set<String>
    ) throws {
        realizationLock.lock()
        let routes = activeRoutes
        realizationLock.unlock()

        for routeID in routeIDs.sorted() {
            guard let plan = intent.plansByID[routeID],
                  let route = routes[routeID] else {
                throw AudioRuntimeFailure.invalidIntent(
                    "Missing active route \(routeID) for parameter update."
                )
            }
            route.lock.lock()
            defer { route.lock.unlock() }
            guard let kernel = route.kernel,
                  route.sources.count == plan.sources.count else {
                throw AudioRuntimeFailure.invalidIntent(
                    "Active route \(routeID) no longer matches its parameter layout."
                )
            }
            for (index, source) in plan.sources.enumerated() {
                resourceAccess.setSourceGain(
                    source.linearGain,
                    index: UInt32(index),
                    kernel: kernel
                )
                resourceAccess.setSourceMuted(
                    intent.mutedRouteIDs.contains(routeID),
                    index: UInt32(index),
                    rampFrames: route.rampFrames,
                    kernel: kernel
                )
            }
        }
    }

    func changes(for observations: Set<HALObservation>) -> AsyncStream<HALChange> {
        AsyncStream { continuation in
            let bag = ListenerBag()
            do {
                for observation in observations {
                    let registration = listenerRegistration(for: observation)
                    let receipt = try propertyAccess.addListener(
                        objectID: registration.objectID,
                        address: registration.address
                    ) { [weak self] in
                        if registration.isAudioServerRestart {
                            self?.advanceAudioServerGeneration()
                            continuation.yield(.audioServerRestarted)
                        } else {
                            continuation.yield(.propertyChanged)
                        }
                    }
                    bag.append(receipt)
                }
            } catch {
                bag.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in bag.cancel() }
        }
    }

    func diagnostics() -> [AudioRouteDiagnosticsSnapshot] {
        realizationLock.lock()
        let routes = activeRoutes.values.sorted { $0.routeID < $1.routeID }
        realizationLock.unlock()

        return routes.compactMap { route in
            route.lock.lock()
            defer { route.lock.unlock() }
            guard let kernel = route.kernel,
                  let snapshot = resourceAccess.snapshot(kernel) else {
                return nil
            }
            let callbacksInFlight =
                route.sources.reduce(
                    route.outputIOProc.map {
                        UInt64(TBAudioIOProcLeaseInFlight($0.lease))
                    } ?? 0
                ) { count, source in
                    count + (source.captureIOProc.map {
                        UInt64(TBAudioIOProcLeaseInFlight($0.lease))
                    } ?? 0)
                }
            return AudioRouteDiagnosticsSnapshot(
                routeID: route.routeID,
                generation: route.generation,
                captureCallbackCount: snapshot.captureCallbackCount,
                captureFrameCount: snapshot.captureFrameCount,
                outputCallbackCount: snapshot.outputCallbackCount,
                outputFrameCount: snapshot.outputFrameCount,
                ringOccupancyFrames: snapshot.ringOccupancyFrames,
                ringHighWaterFrames: snapshot.ringHighWaterFrames,
                warmupFrameCount: snapshot.warmupFrameCount,
                underrunFrameCount: snapshot.underrunFrameCount,
                overrunFrameCount: snapshot.overrunFrameCount,
                forcedResyncCount: snapshot.forcedResyncCount,
                formatMismatchCount: snapshot.formatMismatchCount,
                nonFiniteSampleCount: snapshot.nonFiniteSampleCount,
                clippedSampleCount: snapshot.clippedSampleCount,
                callbacksInFlight: callbacksInFlight,
                sourceFatalCount: snapshot.sourceFatalCount,
                fatalCallbackMismatch: snapshot.outputFatalCount > 0
            )
        }
    }

    func performMaintenance() -> HALRollbackResult {
        let routes = takePendingCleanup()
        guard !routes.isEmpty else { return .succeeded }
        let result = cleanup(routes: Array(routes.values))
        if case .deferred = result {
            retainPendingCleanup(routes)
        }
        return result
    }

    private func firstStreamFormat(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> AudioStreamBasicDescription {
        let streamIDs: [AudioObjectID] = try values(
            objectID: deviceID,
            selector: kAudioDevicePropertyStreams,
            scope: scope
        )
        guard let streamID = streamIDs.first else {
            throw CoreAudioHALError.missingValue(deviceID, kAudioDevicePropertyStreams)
        }
        return try value(
            objectID: streamID,
            selector: kAudioStreamPropertyVirtualFormat,
            initial: AudioStreamBasicDescription()
        )
    }

    private func captureFormat(
        aggregateID: AudioObjectID,
        fallback tapFormat: AudioStreamBasicDescription
    ) throws -> AudioStreamBasicDescription {
        do {
            return try firstStreamFormat(
                deviceID: aggregateID,
                scope: kAudioObjectPropertyScopeInput
            )
        } catch CoreAudioHALError.missingValue(let objectID, let selector)
            where objectID == aggregateID && selector == kAudioDevicePropertyStreams
        {
            // A newly-created Process Tap aggregate can temporarily expose no input
            // streams while macOS is presenting system-audio capture consent. The
            // Tap format is authoritative enough to create the kernel and IOProc so
            // AudioDeviceStart can trigger that consent flow.
            return tapFormat
        }
    }

    private func selectCaptureDevice(
        processObjectID: UInt32,
        outputDeviceID: AudioObjectID,
        processDeviceIDs: [AudioObjectID]
    ) -> AudioObjectID? {
        if processDeviceIDs.contains(outputDeviceID) { return outputDeviceID }
        if processDeviceIDs.count == 1, let deviceID = processDeviceIDs.first { return deviceID }
        return nil
    }

    private func prepareRoute(
        routeID: String,
        plan: AudioRoutePlan,
        observation: HALRouteObservation,
        generation: UInt64,
        muted: Bool,
        reusableTaps: inout [TapKey: HALTapResource]
    ) throws -> RouteResources {
        let resources = RouteResources(routeID: routeID, generation: generation)
        var prepared = false
        defer {
            if !prepared {
                let result = cleanup(routes: [resources])
                if case .deferred = result {
                    retainPendingCleanup([routeID: resources])
                }
            }
        }
        do {
            let verifiedOutputFormat = try firstStreamFormat(
                deviceID: observation.outputDeviceID,
                scope: kAudioObjectPropertyScopeOutput
            )
            guard AudioFormatFingerprint(verifiedOutputFormat) == observation.outputFormat else {
                throw AudioRuntimeFailure.unsupportedFormat(
                    routeID: routeID,
                    observed: AudioFormatFingerprint(verifiedOutputFormat)
                )
            }
            let bufferFrames: UInt32 =
                (try? value(
                    objectID: observation.outputDeviceID,
                    selector: kAudioDevicePropertyBufferFrameSize,
                    initial: UInt32(0)
                )) ?? 0
            let latencyFrames: UInt32 =
                (try? value(
                    objectID: observation.outputDeviceID,
                    selector: kAudioDevicePropertyLatency,
                    scope: kAudioObjectPropertyScopeOutput,
                    initial: UInt32(0)
                )) ?? 0
            let safetyFrames: UInt32 =
                (try? value(
                    objectID: observation.outputDeviceID,
                    selector: kAudioDevicePropertySafetyOffset,
                    scope: kAudioObjectPropertyScopeOutput,
                    initial: UInt32(0)
                )) ?? 0
            let targetFrames = TBAudioRecommendedTargetFrames(
                bufferFrames,
                latencyFrames,
                safetyFrames
            )
            let rampFrames = max(
                UInt32(1),
                UInt32(observation.outputFormat.sampleRate * 0.010)
            )
            resources.rampFrames = rampFrames
            var sourceFormats: [AudioFormatFingerprint] = []
            sourceFormats.reserveCapacity(plan.sources.count)
            for source in plan.sources {
                let sourceResources = SourceResources()
                resources.sources.append(sourceResources)
                let processDevices =
                    observation.processDeviceIDsByObjectID[
                        source.processObjectID
                    ] ?? []
                let selectedDevice = selectCaptureDevice(
                    processObjectID: source.processObjectID,
                    outputDeviceID: observation.outputDeviceID,
                    processDeviceIDs: processDevices
                )
                let deviceUID = try selectedDevice.map(propertyAccess.deviceUID(forID:))
                sourceResources.processObjectID = source.processObjectID
                sourceResources.captureDeviceUID = deviceUID
                let tapKey = TapKey(
                    processObjectID: source.processObjectID,
                    captureDeviceUID: deviceUID
                )
                let tap: HALTapResource
                if let reused = reusableTaps.removeValue(forKey: tapKey) {
                    tap = reused
                } else {
                    tap = try resourceAccess.createProcessTap(
                        routeID: routeID,
                        processObjectID: source.processObjectID,
                        deviceUID: deviceUID
                    )
                }
                sourceResources.tap = tap
                let aggregateID = try resourceAccess.createAggregate(
                    routeID: routeID,
                    outputDeviceUID: plan.outputDeviceUID,
                    tapUID: tap.uid
                )
                sourceResources.aggregateID = aggregateID

                let tapFormat: AudioStreamBasicDescription = try value(
                    objectID: tap.objectID,
                    selector: kAudioTapPropertyFormat,
                    initial: AudioStreamBasicDescription()
                )
                let aggregateFormat = try captureFormat(
                    aggregateID: aggregateID,
                    fallback: tapFormat
                )
                sourceFormats.append(AudioFormatFingerprint(aggregateFormat))
            }
            do {
                resources.kernel = try resourceAccess.createKernel(
                    generation: generation,
                    sourceFormats: sourceFormats,
                    outputFormat: observation.outputFormat,
                    targetFrames: targetFrames,
                    rampFrames: rampFrames,
                    gains: plan.sources.map(\.linearGain)
                )
            } catch {
                throw attributed(error, to: routeID)
            }

            guard let kernel = resources.kernel else {
                preconditionFailure("Kernel receipt missing")
            }
            for index in plan.sources.indices {
                resourceAccess.setSourceMuted(
                    muted,
                    index: UInt32(index),
                    rampFrames: rampFrames,
                    kernel: kernel
                )
            }
            for (index, sourceResources) in resources.sources.enumerated() {
                guard let aggregateID = sourceResources.aggregateID else {
                    throw AudioRuntimeFailure.invalidIntent(
                        "Missing capture aggregate for source \(index)."
                    )
                }
                do {
                    sourceResources.captureIOProc = try resourceAccess.createCaptureIOProc(
                        deviceID: aggregateID,
                        kernel: kernel,
                        generation: generation,
                        sourceIndex: UInt32(index)
                    )
                } catch {
                    throw attributed(error, to: routeID)
                }
            }

            do {
                resources.outputIOProc = try resourceAccess.createOutputIOProc(
                    deviceID: observation.outputDeviceID,
                    kernel: kernel,
                    generation: generation
                )
            } catch {
                throw attributed(error, to: routeID)
            }
            if let outputIOProc = resources.outputIOProc {
                let status = resourceAccess.start(outputIOProc)
                guard status == noErr else {
                    throw AudioRuntimeFailure.prepareFailed(
                        routeID: routeID,
                        stage: .startOutput,
                        status: status
                    )
                }
            }
            for source in resources.sources {
                guard let captureIOProc = source.captureIOProc else { continue }
                let status = resourceAccess.start(captureIOProc)
                guard status == noErr else {
                    throw AudioRuntimeFailure.prepareFailed(
                        routeID: routeID,
                        stage: .startCapture,
                        status: status
                    )
                }
            }
            prepared = true
            return resources
        } catch {
            throw attributed(error, to: routeID, stage: .observe)
        }
    }

    private func cleanup(
        routes: [RouteResources],
        sparingTaps spared: Set<AudioObjectID> = []
    ) -> HALRollbackResult {
        var failures: [HALCleanupFailure] = []
        for route in routes.reversed() {
            route.lock.lock()
            defer { route.lock.unlock() }
            if let kernel = route.kernel {
                resourceAccess.detachKernel(kernel)
            }
            route.outputIOProc.map(resourceAccess.detach)
            route.sources.reversed().compactMap(\.captureIOProc).forEach(resourceAccess.detach)

            if let output = route.outputIOProc {
                let stopStatus = resourceAccess.stop(output)
                let destroyStatus = resourceAccess.destroyIOProc(output)
                let teardownComplete = ioProcTeardownComplete(
                    stopStatus: stopStatus,
                    destroyStatus: destroyStatus
                )
                let leaseStatus =
                    teardownComplete
                    ? resourceAccess.destroyLease(output)
                    : kAudioHardwareNotRunningError
                if !teardownComplete {
                    failures.append(
                        HALCleanupFailure(
                            routeID: route.routeID,
                            resource: .outputIOProc,
                            objectID: output.deviceID,
                            stage: TBAudioObjectDestructionComplete(destroyStatus)
                                ? .stopIOProc
                                : .destroyIOProc,
                            status: TBAudioObjectDestructionComplete(destroyStatus)
                                ? stopStatus
                                : destroyStatus
                        ))
                } else if leaseStatus != noErr {
                    failures.append(
                        HALCleanupFailure(
                            routeID: route.routeID,
                            resource: .outputIOProc,
                            objectID: output.deviceID,
                            stage: .drainCallbacks,
                            status: leaseStatus
                        ))
                } else {
                    route.outputIOProc = nil
                }
            }
            for source in route.sources.reversed() {
                if let capture = source.captureIOProc {
                    let stopStatus = resourceAccess.stop(capture)
                    let destroyStatus = resourceAccess.destroyIOProc(capture)
                    let teardownComplete = ioProcTeardownComplete(
                        stopStatus: stopStatus,
                        destroyStatus: destroyStatus
                    )
                    let leaseStatus =
                        teardownComplete
                        ? resourceAccess.destroyLease(capture)
                        : kAudioHardwareNotRunningError
                    if !teardownComplete {
                        failures.append(
                            HALCleanupFailure(
                                routeID: route.routeID,
                                resource: .captureIOProc,
                                objectID: capture.deviceID,
                                stage: TBAudioObjectDestructionComplete(destroyStatus)
                                    ? .stopIOProc
                                    : .destroyIOProc,
                                status: TBAudioObjectDestructionComplete(destroyStatus)
                                    ? stopStatus
                                    : destroyStatus
                            ))
                    } else if leaseStatus != noErr {
                        failures.append(
                            HALCleanupFailure(
                                routeID: route.routeID,
                                resource: .captureIOProc,
                                objectID: capture.deviceID,
                                stage: .drainCallbacks,
                                status: leaseStatus
                            ))
                    } else {
                        source.captureIOProc = nil
                    }
                }
                if source.captureIOProc == nil, let aggregateID = source.aggregateID {
                    let status = resourceAccess.destroyAggregate(aggregateID)
                    if TBAudioObjectDestructionComplete(status) {
                        source.aggregateID = nil
                    } else {
                        failures.append(
                            HALCleanupFailure(
                                routeID: route.routeID,
                                resource: .aggregateDevice,
                                objectID: aggregateID,
                                stage: .destroyAggregate,
                                status: status
                            ))
                    }
                }
                if source.captureIOProc == nil,
                    source.aggregateID == nil,
                    let tap = source.tap
                {
                    if spared.contains(tap.objectID) {
                        // The tap is being migrated to a replacing route; release
                        // it from this source without destroying it so it can be
                        // claimed (and stays muted) during the switch.
                        source.tap = nil
                    } else {
                        let status = resourceAccess.destroyProcessTap(tap)
                        if TBAudioObjectDestructionComplete(status) {
                            source.tap = nil
                        } else {
                            failures.append(
                                HALCleanupFailure(
                                    routeID: route.routeID,
                                    resource: .processTap,
                                    objectID: tap.objectID,
                                    stage: .destroyTap,
                                    status: status
                                ))
                        }
                    }
                }
            }
            let sourceResourcesReleased = route.sources.allSatisfy {
                $0.captureIOProc == nil && $0.aggregateID == nil && $0.tap == nil
            }
            if route.outputIOProc == nil, sourceResourcesReleased, let kernel = route.kernel {
                resourceAccess.destroyKernel(kernel)
                route.kernel = nil
            }
        }
        let uniqueFailures = Array(Set(failures)).sorted {
            if $0.routeID != $1.routeID {
                return $0.routeID < $1.routeID
            }
            if $0.resource.rawValue != $1.resource.rawValue {
                return $0.resource.rawValue < $1.resource.rawValue
            }
            if $0.objectID != $1.objectID {
                return ($0.objectID ?? 0) < ($1.objectID ?? 0)
            }
            if $0.stage.rawValue != $1.stage.rawValue {
                return $0.stage.rawValue < $1.stage.rawValue
            }
            return $0.status < $1.status
        }
        return uniqueFailures.isEmpty
            ? .succeeded
            : .deferred(failures: uniqueFailures)
    }

    private func attributed(
        _ error: Error,
        to routeID: String,
        stage fallbackStage: HALStage? = nil
    ) -> Error {
        if case AudioRuntimeFailure.prepareFailed(let existingRouteID, let stage, let status) =
            error,
            existingRouteID.isEmpty
        {
            return AudioRuntimeFailure.prepareFailed(
                routeID: routeID,
                stage: stage,
                status: status
            )
        }
        if case CoreAudioHALError.status(let status, _) = error {
            return AudioRuntimeFailure.prepareFailed(
                routeID: routeID,
                stage: fallbackStage ?? .observe,
                status: status
            )
        }
        if case CoreAudioHALError.missingValue = error {
            return AudioRuntimeFailure.prepareFailed(
                routeID: routeID,
                stage: fallbackStage ?? .observe,
                status: kAudioHardwareBadObjectError
            )
        }
        return error
    }

    private func ioProcTeardownComplete(
        stopStatus: OSStatus,
        destroyStatus: OSStatus
    ) -> Bool {
        (TBAudioIOProcTeardownDisposition(stopStatus, destroyStatus) & 1) != 0
    }

    private func takeActiveRoutes() -> [String: RouteResources] {
        realizationLock.lock()
        let routes = activeRoutes
        activeRoutes = [:]
        realizationLock.unlock()
        return routes
    }

    private func takeActiveRoutes(
        routeIDs: Set<String>
    ) -> [String: RouteResources] {
        realizationLock.lock()
        var routes: [String: RouteResources] = [:]
        for routeID in routeIDs {
            routes[routeID] = activeRoutes.removeValue(forKey: routeID)
        }
        realizationLock.unlock()
        return routes
    }

    private func activeRoute(for routeID: String) -> RouteResources? {
        realizationLock.lock()
        defer { realizationLock.unlock() }
        return activeRoutes[routeID]
    }

    private func takePendingCleanup() -> [String: RouteResources] {
        realizationLock.lock()
        let routes = pendingCleanupRoutes
        pendingCleanupRoutes = [:]
        realizationLock.unlock()
        return routes
    }

    private func retainPendingCleanup(_ routes: [String: RouteResources]) {
        realizationLock.lock()
        pendingCleanupRoutes.merge(routes) { current, _ in current }
        realizationLock.unlock()
    }

    private func value<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) throws -> T {
        var result = initial
        let address = CoreAudioPropertyReader.address(selector, scope: scope)
        let actualSize = try withUnsafeMutableBytes(of: &result) { buffer in
            try propertyAccess.readData(objectID: objectID, address: address, into: buffer)
        }
        guard actualSize == MemoryLayout<T>.size else {
            throw CoreAudioHALError.missingValue(objectID, selector)
        }
        return result
    }

    private func values<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> [T] {
        let address = CoreAudioPropertyReader.address(selector, scope: scope)
        let size = try propertyAccess.dataSize(objectID: objectID, address: address)
        guard size > 0 else { return [] }
        guard size % UInt32(MemoryLayout<T>.stride) == 0 else {
            throw CoreAudioHALError.missingValue(objectID, selector)
        }
        var values = [T](
            unsafeUninitializedCapacity: Int(size) / MemoryLayout<T>.stride
        ) { _, count in
            count = Int(size) / MemoryLayout<T>.stride
        }
        let actualSize = try values.withUnsafeMutableBytes { buffer in
            try propertyAccess.readData(objectID: objectID, address: address, into: buffer)
        }
        guard actualSize == size else {
            throw CoreAudioHALError.missingValue(objectID, selector)
        }
        return values
    }

    private func listenerRegistration(
        for observation: HALObservation
    ) -> (objectID: AudioObjectID, address: AudioObjectPropertyAddress, isAudioServerRestart: Bool)
    {
        switch observation {
        case .processDevices(let objectID):
            return (
                objectID,
                CoreAudioPropertyReader.address(
                    kAudioProcessPropertyDevices,
                    scope: kAudioObjectPropertyScopeOutput
                ),
                false
            )
        case .tapFormat(let objectID):
            return (objectID, CoreAudioPropertyReader.address(kAudioTapPropertyFormat), false)
        case .aggregateInputStreams(let objectID):
            return (
                objectID,
                CoreAudioPropertyReader.address(
                    kAudioDevicePropertyStreams,
                    scope: kAudioObjectPropertyScopeInput
                ),
                false
            )
        case .aggregateInputFormat(let objectID), .outputStreamFormat(let objectID):
            return (
                objectID,
                CoreAudioPropertyReader.address(kAudioStreamPropertyVirtualFormat),
                false
            )
        case .outputAlive(let objectID):
            return (
                objectID,
                CoreAudioPropertyReader.address(kAudioDevicePropertyDeviceIsAlive),
                false
            )
        case .outputStreams(let objectID):
            return (
                objectID,
                CoreAudioPropertyReader.address(
                    kAudioDevicePropertyStreams,
                    scope: kAudioObjectPropertyScopeOutput
                ),
                false
            )
        case .outputNominalRate(let objectID):
            return (
                objectID,
                CoreAudioPropertyReader.address(kAudioDevicePropertyNominalSampleRate),
                false
            )
        case .audioServerGeneration:
            return (
                AudioObjectID(kAudioObjectSystemObject),
                CoreAudioPropertyReader.address(kAudioHardwarePropertyServiceRestarted),
                true
            )
        }
    }

    private func currentAudioServerGeneration() -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return audioServerGeneration
    }

    private func advanceAudioServerGeneration() {
        generationLock.lock()
        audioServerGeneration &+= 1
        generationLock.unlock()
    }
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
    case deferred(failures: [HALCleanupFailure])
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
