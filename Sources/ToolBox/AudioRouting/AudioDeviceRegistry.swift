import Combine
import CoreAudio

struct HALAudioDeviceRecord: Equatable, Sendable {
    let uid: String
    let name: String
    let hasOutput: Bool
    let isAlive: Bool
    let compatibilityIssue: AudioOutputCompatibilityIssue?
    let sampleRate: Double?
    let transportType: UInt32

    init(
        uid: String,
        name: String,
        hasOutput: Bool,
        isAlive: Bool = true,
        compatibilityIssue: AudioOutputCompatibilityIssue? = nil,
        sampleRate: Double? = nil,
        transportType: UInt32 = kAudioDeviceTransportTypeUnknown
    ) {
        self.uid = uid
        self.name = name
        self.hasOutput = hasOutput
        self.isAlive = isAlive
        self.compatibilityIssue = compatibilityIssue
        self.sampleRate = sampleRate
        self.transportType = transportType
    }

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

struct HALAudioDeviceRouteSignature: Equatable, Sendable {
    let objectID: AudioObjectID
    let uid: String
    let isAlive: Bool
    let streamIDs: [AudioObjectID]
    let streamFormats: [HALAudioStreamFormatRecord]
}

struct AudioDeviceRouteConfiguration: Equatable, Sendable {
    let defaultOutputUID: String?
    let devices: [HALAudioDeviceRouteSignature]

    init(defaultOutputUID: String?, devices: [HALAudioDeviceRouteSignature]) {
        self.defaultOutputUID = defaultOutputUID
        self.devices = devices.sorted {
            if $0.uid != $1.uid { return $0.uid < $1.uid }
            return $0.objectID < $1.objectID
        }
    }
}

struct AudioDeviceRouteConfigurationTracker {
    private var previous: AudioDeviceRouteConfiguration?

    mutating func observe(_ configuration: AudioDeviceRouteConfiguration) -> Bool {
        defer { previous = configuration }
        guard let previous else { return false }
        return previous != configuration
    }

    mutating func reset() {
        previous = nil
    }
}

private struct HALAudioDeviceQueryObject: Sendable {
    let objectID: AudioObjectID
    let record: HALAudioDeviceRecord
    let routeSignature: HALAudioDeviceRouteSignature
}

private struct HALAudioDeviceQueryResult: Sendable {
    let objects: [HALAudioDeviceQueryObject]
    let defaultOutputUID: String?
    let failureCount: Int
}

private enum HALAudioDeviceQueryOutcome: Sendable {
    case success(HALAudioDeviceQueryResult)
    case failure(String)
}

private struct HALAudioListenerRegistration {
    let objectID: AudioObjectID
    var address: AudioObjectPropertyAddress
    let listener: AudioObjectPropertyListenerBlock
}

struct AudioRegistrySession {
    private(set) var currentID: UInt64 = 0
    private(set) var isActive = false

    mutating func start() -> UInt64? {
        guard !isActive else { return nil }
        currentID &+= 1
        isActive = true
        return currentID
    }

    mutating func stop() {
        guard isActive else { return }
        isActive = false
        currentID &+= 1
    }

    func accepts(_ sessionID: UInt64) -> Bool {
        isActive && currentID == sessionID
    }
}

@MainActor
final class AudioDeviceRegistry: ObservableObject {
    nonisolated static let routeSettleDelay: Duration = .seconds(1)

    @Published private(set) var snapshot: [AudioOutputDevice] = []
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var lastError: String?
    @Published private(set) var serviceGeneration = 0
    @Published private(set) var routeGeneration = 0

    var rememberedUIDs: Set<String> = [] {
        didSet {
            if rememberedUIDs != oldValue { beginReload() }
        }
    }

    private var listener: AudioObjectPropertyListenerBlock?
    private var devicesAddress = CoreAudioPropertyReader.address(kAudioHardwarePropertyDevices)
    private var defaultAddress = CoreAudioPropertyReader.address(kAudioHardwarePropertyDefaultOutputDevice)
    private var serviceRestartedAddress = CoreAudioPropertyReader.address(kAudioHardwarePropertyServiceRestarted)
    private var routeListeners: [HALAudioListenerRegistration] = []
    private let reloadCoalescer = AudioRegistryEventCoalescer(delay: routeSettleDelay)
    private let queryExecutor = CoreAudioRegistryQueryExecutor.shared
    private var session = AudioRegistrySession()
    private var pendingServiceRestart = false
    private var pendingRouteChange = false
    private var partialReloadRetryCount = 0
    private var reloadRequestID: UInt64 = 0
    private var routeConfigurationTracker = AudioDeviceRouteConfigurationTracker()
    private var routeListenerTopology: [AudioObjectID: [AudioObjectID]] = [:]

    private static let privateCaptureDeviceUIDPrefix = "com.youtonghy.toolbox.capture."

    nonisolated static func project(
        records: [HALAudioDeviceRecord],
        rememberedUIDs: Set<String>,
        captureSampleRate: Double? = nil
    ) -> [AudioOutputDevice] {
        var devices: [String: AudioOutputDevice] = [:]
        for record in records where record.hasOutput {
            var compatibilityIssue = record.compatibilityIssue
            if compatibilityIssue == nil,
               let captureSampleRate,
               let sampleRate = record.sampleRate,
               !TBAudioSampleRatesCompatible(captureSampleRate, sampleRate) {
                compatibilityIssue = .sampleRateMismatch
            }
            devices[record.uid] = AudioOutputDevice(
                uid: record.uid,
                name: record.name,
                isAvailable: record.isAlive,
                compatibilityIssue: compatibilityIssue,
                sampleRate: record.sampleRate
            )
        }
        for uid in rememberedUIDs where devices[uid] == nil {
            devices[uid] = AudioOutputDevice(uid: uid, name: "不可用的设备", isAvailable: false)
        }
        return devices.values.sorted {
            // Remembered unavailable devices stay first so the broken selection is visible.
            ($0.isAvailable == $1.isAvailable) ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : !$0.isAvailable
        }
    }

    nonisolated static func monitoredUIDs(
        records: [HALAudioDeviceRecord],
        defaultOutputUID: String?,
        rememberedUIDs: Set<String>
    ) -> Set<String> {
        let availableUIDs = Set(records.filter(\.hasOutput).map(\.uid))
        return rememberedUIDs.union(defaultOutputUID.map { [$0] } ?? []).intersection(availableUIDs)
    }

    nonisolated static func suspendingBluetoothRoute(
        in devices: [AudioOutputDevice],
        uid: String
    ) -> [AudioOutputDevice]? {
        guard let index = devices.firstIndex(where: { $0.uid == uid && $0.isRoutable }) else {
            return nil
        }
        var updated = devices
        updated[index].compatibilityIssue = .bluetoothProfileChanging
        updated[index].sampleRate = nil
        return updated
    }

    nonisolated static func eventEffects(
        for selectors: [AudioObjectPropertySelector]
    ) -> (serviceRestarted: Bool, routeConfigurationChanged: Bool) {
        (
            serviceRestarted: selectors.contains(kAudioHardwarePropertyServiceRestarted),
            routeConfigurationChanged: selectors.contains(kAudioHardwarePropertyDefaultOutputDevice)
        )
    }

    func start() {
        guard let registrationSessionID = session.start() else { return }
        let callback: AudioObjectPropertyListenerBlock = { [weak self] addressCount, addresses in
            let effects = Self.eventEffects(for: UnsafeBufferPointer(
                start: addresses, count: Int(addressCount)
            ).map(\.mSelector))
            Task { @MainActor [weak self] in
                self?.scheduleReload(
                    sessionID: registrationSessionID,
                    serviceRestarted: effects.serviceRestarted,
                    routeChanged: effects.routeConfigurationChanged,
                    resetRetryBudget: true
                )
            }
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectAddPropertyListenerBlock(system, &devicesAddress, .main, callback) == noErr else {
            session.stop()
            lastError = "无法监听 Core Audio 输出设备变化。"
            return
        }
        guard AudioObjectAddPropertyListenerBlock(system, &defaultAddress, .main, callback) == noErr else {
            AudioObjectRemovePropertyListenerBlock(system, &devicesAddress, .main, callback)
            session.stop()
            lastError = "无法监听 Core Audio 默认输出变化。"
            return
        }
        guard AudioObjectAddPropertyListenerBlock(system, &serviceRestartedAddress, .main, callback) == noErr else {
            AudioObjectRemovePropertyListenerBlock(system, &defaultAddress, .main, callback)
            AudioObjectRemovePropertyListenerBlock(system, &devicesAddress, .main, callback)
            session.stop()
            lastError = "无法监听 Core Audio 服务重启。"
            return
        }
        listener = callback
        beginReload(sessionID: registrationSessionID)
    }

    func stop() {
        session.stop()
        if let listener {
            let system = AudioObjectID(kAudioObjectSystemObject)
            AudioObjectRemovePropertyListenerBlock(system, &devicesAddress, .main, listener)
            AudioObjectRemovePropertyListenerBlock(system, &defaultAddress, .main, listener)
            AudioObjectRemovePropertyListenerBlock(system, &serviceRestartedAddress, .main, listener)
        }
        listener = nil
        reloadCoalescer.cancel()
        pendingServiceRestart = false
        pendingRouteChange = false
        partialReloadRetryCount = 0
        reloadRequestID &+= 1
        routeConfigurationTracker.reset()
        routeListenerTopology = [:]
        removeRouteListeners()
        snapshot = []
        defaultOutputUID = nil
    }

    private func beginReload(
        sessionID: UInt64? = nil,
        serviceRestarted: Bool = false,
        routeChanged: Bool = false
    ) {
        let sessionID = sessionID ?? session.currentID
        guard session.accepts(sessionID) else { return }
        reloadRequestID &+= 1
        let requestID = reloadRequestID
        let rememberedUIDs = rememberedUIDs
        Task { [weak self] in
            guard let self else { return }
            let outcome: HALAudioDeviceQueryOutcome = await queryExecutor.run {
                do {
                    return .success(try Self.querySnapshot())
                } catch {
                    return .failure(error.localizedDescription)
                }
            }
            guard session.accepts(sessionID), reloadRequestID == requestID else { return }
            apply(
                outcome,
                rememberedUIDs: rememberedUIDs,
                serviceRestarted: serviceRestarted,
                routeChanged: routeChanged
            )
        }
    }

    private nonisolated static func querySnapshot() throws -> HALAudioDeviceQueryResult {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let ids = try CoreAudioPropertyReader.objectIDs(
            objectID: system,
            selector: kAudioHardwarePropertyDevices
        )
        let result = CoreAudioPropertyReader.readAvailableObjects(ids) { id in
            let isAliveValue: UInt32 = try CoreAudioPropertyReader.value(
                objectID: id,
                selector: kAudioDevicePropertyDeviceIsAlive,
                initial: 0
            )
            let isAlive = isAliveValue != 0
            let streamIDs = try CoreAudioPropertyReader.objectIDs(
                objectID: id,
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeOutput
            )
            let transportType: UInt32 = (try? CoreAudioPropertyReader.value(
                objectID: id,
                selector: kAudioDevicePropertyTransportType,
                initial: UInt32(kAudioDeviceTransportTypeUnknown)
            )) ?? UInt32(kAudioDeviceTransportTypeUnknown)
            let isBluetooth = transportType == kAudioDeviceTransportTypeBluetooth
                || transportType == kAudioDeviceTransportTypeBluetoothLE
            let hasOutput = !streamIDs.isEmpty
            var streamFormats: [HALAudioStreamFormatRecord] = []
            var compatibilityIssue: AudioOutputCompatibilityIssue?
            var sampleRate: Double?
            if hasOutput && isAlive {
                do {
                    streamFormats = try streamIDs.map { streamID in
                        let format: AudioStreamBasicDescription = try CoreAudioPropertyReader.value(
                            objectID: streamID,
                            selector: kAudioStreamPropertyVirtualFormat,
                            initial: AudioStreamBasicDescription()
                        )
                        return HALAudioStreamFormatRecord(format)
                    }
                    compatibilityIssue = AudioOutputCompatibility.evaluate(streamFormats: streamFormats)
                    sampleRate = streamFormats.count == 1 ? streamFormats[0].sampleRate : nil
                } catch {
                    compatibilityIssue = .formatQueryFailed
                    sampleRate = nil
                }
            } else {
                compatibilityIssue = nil
                sampleRate = nil
            }
            if isBluetooth, compatibilityIssue != nil {
                compatibilityIssue = .bluetoothProfileChanging
                sampleRate = nil
            }
            let uid = try CoreAudioPropertyReader.string(
                objectID: id,
                selector: kAudioDevicePropertyDeviceUID
            )
            let record = HALAudioDeviceRecord(
                uid: uid,
                name: try CoreAudioPropertyReader.string(objectID: id, selector: kAudioObjectPropertyName),
                hasOutput: hasOutput,
                isAlive: isAlive,
                compatibilityIssue: compatibilityIssue,
                sampleRate: sampleRate,
                transportType: transportType
            )
            return HALAudioDeviceQueryObject(
                objectID: id,
                record: record,
                routeSignature: HALAudioDeviceRouteSignature(
                    objectID: id,
                    uid: uid,
                    isAlive: isAlive,
                    streamIDs: streamIDs,
                    streamFormats: streamFormats
                )
            )
        }
        let defaultID: AudioObjectID = try CoreAudioPropertyReader.value(
            objectID: system,
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            initial: AudioObjectID(kAudioObjectUnknown)
        )
        let defaultOutputUID = defaultID == kAudioObjectUnknown ? nil : try CoreAudioPropertyReader.string(
            objectID: defaultID,
            selector: kAudioDevicePropertyDeviceUID
        )
        return HALAudioDeviceQueryResult(
            objects: result.objects.map(\.value),
            defaultOutputUID: defaultOutputUID,
            failureCount: result.failureCount
        )
    }

    private func apply(
        _ outcome: HALAudioDeviceQueryOutcome,
        rememberedUIDs: Set<String>,
        serviceRestarted: Bool,
        routeChanged: Bool
    ) {
        guard case let .success(result) = outcome else {
            if case let .failure(message) = outcome { lastError = message }
            pendingServiceRestart = pendingServiceRestart || serviceRestarted
            pendingRouteChange = pendingRouteChange || routeChanged
            schedulePartialReloadRetry()
            return
        }
        guard result.failureCount == 0 else {
            lastError = "\(result.failureCount) 个输出设备在刷新时已失效，保留上次稳定状态。"
            pendingServiceRestart = pendingServiceRestart || serviceRestarted
            pendingRouteChange = pendingRouteChange || routeChanged
            schedulePartialReloadRetry()
            return
        }

        let records = result.objects.map(\.record)
        let captureSampleRate = records.first(where: { $0.uid == result.defaultOutputUID })?.sampleRate
        let updatedSnapshot = Self.project(
            records: records,
            rememberedUIDs: rememberedUIDs,
            captureSampleRate: captureSampleRate
        )
        let monitoredUIDs = Self.monitoredUIDs(
            records: records,
            defaultOutputUID: result.defaultOutputUID,
            rememberedUIDs: rememberedUIDs
        )
        let monitoredObjects = result.objects.filter { monitoredUIDs.contains($0.record.uid) }
        let routeConfiguration = AudioDeviceRouteConfiguration(
            defaultOutputUID: result.defaultOutputUID,
            devices: monitoredObjects
                .filter { !$0.record.uid.hasPrefix(Self.privateCaptureDeviceUIDPrefix) }
                .map(\.routeSignature)
        )
        let routeConfigurationChanged = routeConfigurationTracker.observe(routeConfiguration)
        let publishedModelChanged = snapshot != updatedSnapshot || defaultOutputUID != result.defaultOutputUID

        if snapshot != updatedSnapshot { snapshot = updatedSnapshot }
        if defaultOutputUID != result.defaultOutputUID { defaultOutputUID = result.defaultOutputUID }
        replaceRouteListeners(objects: monitoredObjects)

        if serviceRestarted {
            serviceGeneration += 1
        } else if routeChanged,
                  routeConfigurationChanged,
                  !publishedModelChanged,
                  !updatedSnapshot.contains(where: {
                      $0.compatibilityIssue == .bluetoothProfileChanging
                  }) {
            routeGeneration += 1
        }
        partialReloadRetryCount = 0
        lastError = nil
    }

    private func replaceRouteListeners(objects: [HALAudioDeviceQueryObject]) {
        let topology = Dictionary(uniqueKeysWithValues: objects.map {
            ($0.objectID, $0.routeSignature.streamIDs)
        })
        guard topology != routeListenerTopology else { return }
        removeRouteListeners()
        routeListenerTopology = topology
        let registrationSessionID = session.currentID
        for object in objects {
            let deviceID = object.objectID
            let bluetoothUID = object.record.isBluetooth ? object.record.uid : nil
            let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.scheduleReload(
                        sessionID: registrationSessionID,
                        serviceRestarted: false,
                        routeChanged: true,
                        resetRetryBudget: true,
                        suspendingBluetoothUID: bluetoothUID
                    )
                }
            }
            addRouteListener(
                objectID: deviceID,
                address: CoreAudioPropertyReader.address(kAudioDevicePropertyDeviceIsAlive),
                listener: callback
            )
            addRouteListener(
                objectID: deviceID,
                address: CoreAudioPropertyReader.address(
                    kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput
                ),
                listener: callback
            )
            addRouteListener(
                objectID: deviceID,
                address: CoreAudioPropertyReader.address(kAudioDevicePropertyNominalSampleRate),
                listener: callback
            )
            for streamID in object.routeSignature.streamIDs {
                addRouteListener(
                    objectID: streamID,
                    address: CoreAudioPropertyReader.address(kAudioStreamPropertyVirtualFormat),
                    listener: callback
                )
            }
        }
    }

    private func addRouteListener(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = address
        guard AudioObjectHasProperty(objectID, &address) else { return }
        guard AudioObjectAddPropertyListenerBlock(objectID, &address, .main, listener) == noErr else { return }
        routeListeners.append(
            HALAudioListenerRegistration(objectID: objectID, address: address, listener: listener)
        )
    }

    private func removeRouteListeners() {
        for var registration in routeListeners {
            AudioObjectRemovePropertyListenerBlock(
                registration.objectID, &registration.address, .main, registration.listener
            )
        }
        routeListeners.removeAll()
    }

    private func scheduleReload(
        sessionID: UInt64,
        serviceRestarted: Bool,
        routeChanged: Bool,
        resetRetryBudget: Bool = false,
        suspendingBluetoothUID: String? = nil
    ) {
        guard session.accepts(sessionID) else { return }
        if let suspendingBluetoothUID,
           let suspended = Self.suspendingBluetoothRoute(
               in: snapshot,
               uid: suspendingBluetoothUID
           ) {
            snapshot = suspended
        }
        if resetRetryBudget { partialReloadRetryCount = 0 }
        pendingServiceRestart = pendingServiceRestart || serviceRestarted
        pendingRouteChange = pendingRouteChange || routeChanged
        reloadCoalescer.schedule { [weak self] in
            guard let self, self.session.accepts(sessionID) else { return }
            let shouldAdvanceServiceGeneration = self.pendingServiceRestart
            let shouldAdvanceRouteGeneration = self.pendingRouteChange
            self.pendingServiceRestart = false
            self.pendingRouteChange = false
            self.beginReload(
                sessionID: sessionID,
                serviceRestarted: shouldAdvanceServiceGeneration,
                routeChanged: shouldAdvanceRouteGeneration
            )
        }
    }

    private func schedulePartialReloadRetry() {
        guard session.isActive, partialReloadRetryCount < 3 else { return }
        partialReloadRetryCount += 1
        scheduleReload(
            sessionID: session.currentID,
            serviceRestarted: false,
            routeChanged: false,
            resetRetryBudget: false
        )
    }
}
