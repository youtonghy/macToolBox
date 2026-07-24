import Combine
import CoreAudio

struct HALAudioDeviceRecord: Equatable, Sendable {
    let uid: String
    let name: String
    let hasOutput: Bool
    let isAlive: Bool
    let compatibilityIssue: AudioOutputCompatibilityIssue?
    let sampleRate: Double?

    init(
        uid: String,
        name: String,
        hasOutput: Bool,
        isAlive: Bool = true,
        compatibilityIssue: AudioOutputCompatibilityIssue? = nil,
        sampleRate: Double? = nil
    ) {
        self.uid = uid
        self.name = name
        self.hasOutput = hasOutput
        self.isAlive = isAlive
        self.compatibilityIssue = compatibilityIssue
        self.sampleRate = sampleRate
    }
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
    @Published private(set) var snapshot: [AudioOutputDevice] = []
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var lastError: String?
    @Published private(set) var serviceGeneration = 0
    @Published private(set) var routeGeneration = 0

    var rememberedUIDs: Set<String> = [] {
        didSet {
            if rememberedUIDs != oldValue { reload() }
        }
    }

    private var listener: AudioObjectPropertyListenerBlock?
    private var devicesAddress = CoreAudioPropertyReader.address(kAudioHardwarePropertyDevices)
    private var defaultAddress = CoreAudioPropertyReader.address(kAudioHardwarePropertyDefaultOutputDevice)
    private var serviceRestartedAddress = CoreAudioPropertyReader.address(kAudioHardwarePropertyServiceRestarted)
    private var routeListeners: [HALAudioListenerRegistration] = []
    private let reloadCoalescer = AudioRegistryEventCoalescer()
    private var session = AudioRegistrySession()
    private var pendingServiceRestart = false
    private var pendingRouteChange = false
    private var partialReloadRetryCount = 0

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

    func start() {
        guard let registrationSessionID = session.start() else { return }
        let callback: AudioObjectPropertyListenerBlock = { [weak self] addressCount, addresses in
            let serviceRestarted = UnsafeBufferPointer(
                start: addresses, count: Int(addressCount)
            ).contains {
                $0.mSelector == kAudioHardwarePropertyServiceRestarted
            }
            Task { @MainActor [weak self] in
                self?.scheduleReload(
                    sessionID: registrationSessionID,
                    serviceRestarted: serviceRestarted,
                    routeChanged: false,
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
        reload()
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
        removeRouteListeners()
        snapshot = []
        defaultOutputUID = nil
    }

    func reload() {
        guard session.isActive else { return }
        do {
            let system = AudioObjectID(kAudioObjectSystemObject)
            let ids = try CoreAudioPropertyReader.objectIDs(objectID: system, selector: kAudioHardwarePropertyDevices)
            let result = CoreAudioPropertyReader.readAvailableObjects(ids) { id in
                let isAliveValue: UInt32 = try CoreAudioPropertyReader.value(
                    objectID: id,
                    selector: kAudioDevicePropertyDeviceIsAlive,
                    initial: 0
                )
                let isAlive = isAliveValue != 0
                let hasOutput = try CoreAudioPropertyReader.hasStreams(
                    objectID: id,
                    scope: kAudioObjectPropertyScopeOutput
                )
                let compatibilityIssue: AudioOutputCompatibilityIssue?
                let sampleRate: Double?
                if hasOutput && isAlive {
                    do {
                        let formats = try CoreAudioPropertyReader.streamFormats(
                            objectID: id,
                            scope: kAudioObjectPropertyScopeOutput
                        )
                        compatibilityIssue = AudioOutputCompatibility.evaluate(
                            streamFormats: formats
                        )
                        sampleRate = formats.count == 1 ? formats[0].sampleRate : nil
                    } catch {
                        compatibilityIssue = .formatQueryFailed
                        sampleRate = nil
                    }
                } else {
                    compatibilityIssue = nil
                    sampleRate = nil
                }
                return HALAudioDeviceRecord(
                    uid: try CoreAudioPropertyReader.string(objectID: id, selector: kAudioDevicePropertyDeviceUID),
                    name: try CoreAudioPropertyReader.string(objectID: id, selector: kAudioObjectPropertyName),
                    hasOutput: hasOutput,
                    isAlive: isAlive,
                    compatibilityIssue: compatibilityIssue,
                    sampleRate: sampleRate
                )
            }
            let records = result.objects.map(\.value)
            let defaultID: AudioObjectID = try CoreAudioPropertyReader.value(
                objectID: system, selector: kAudioHardwarePropertyDefaultOutputDevice,
                initial: AudioObjectID(kAudioObjectUnknown)
            )
            let resolvedDefaultUID = defaultID == kAudioObjectUnknown ? nil : try CoreAudioPropertyReader.string(
                objectID: defaultID, selector: kAudioDevicePropertyDeviceUID
            )
            let captureSampleRate = records.first(where: { $0.uid == resolvedDefaultUID })?.sampleRate
            snapshot = Self.project(
                records: records,
                rememberedUIDs: rememberedUIDs,
                captureSampleRate: captureSampleRate
            )
            defaultOutputUID = resolvedDefaultUID
            let monitoredUIDs = Self.monitoredUIDs(
                records: records,
                defaultOutputUID: resolvedDefaultUID,
                rememberedUIDs: rememberedUIDs
            )
            let monitoredDeviceIDs = result.objects.compactMap { object in
                monitoredUIDs.contains(object.value.uid) ? object.id : nil
            }
            replaceRouteListeners(deviceIDs: monitoredDeviceIDs)
            if result.failureCount == 0 {
                partialReloadRetryCount = 0
                lastError = nil
            } else {
                lastError = "\(result.failureCount) 个输出设备在刷新时已失效，已跳过。"
                schedulePartialReloadRetry()
            }
        } catch {
            lastError = error.localizedDescription
            schedulePartialReloadRetry()
        }
    }

    private func replaceRouteListeners(deviceIDs: [AudioObjectID]) {
        removeRouteListeners()
        let registrationSessionID = session.currentID
        let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleReload(
                    sessionID: registrationSessionID,
                    serviceRestarted: false,
                    routeChanged: true,
                    resetRetryBudget: true
                )
            }
        }
        for deviceID in deviceIDs {
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
            let streamIDs = (try? CoreAudioPropertyReader.objectIDs(
                objectID: deviceID,
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeOutput
            )) ?? []
            for streamID in streamIDs {
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
        resetRetryBudget: Bool = false
    ) {
        guard session.accepts(sessionID) else { return }
        if resetRetryBudget { partialReloadRetryCount = 0 }
        pendingServiceRestart = pendingServiceRestart || serviceRestarted
        pendingRouteChange = pendingRouteChange || routeChanged
        reloadCoalescer.schedule { [weak self] in
            guard let self, self.session.accepts(sessionID) else { return }
            let shouldAdvanceServiceGeneration = self.pendingServiceRestart
            let shouldAdvanceRouteGeneration = self.pendingRouteChange
            self.pendingServiceRestart = false
            self.pendingRouteChange = false
            if shouldAdvanceServiceGeneration { self.serviceGeneration += 1 }
            self.reload()
            if shouldAdvanceRouteGeneration { self.routeGeneration += 1 }
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
