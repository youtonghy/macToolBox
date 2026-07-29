import Foundation
import IOKit
import IOKit.ps

struct CableRegistryJoin: Equatable, Sendable {
    let hpmUUID: String?
    let portType: Int
    let portNumber: Int?

    init(hpmUUID: String?, portType: Int, portNumber: Int?) {
        let normalizedUUID = hpmUUID?
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        self.hpmUUID = normalizedUUID?.count == 32 ? normalizedUUID : nil
        self.portType = portType
        self.portNumber = portNumber
    }

    func matches(_ other: CableRegistryJoin) -> Bool {
        guard let portNumber,
              let otherPortNumber = other.portNumber,
              portNumber == otherPortNumber else {
            return false
        }

        if let hpmUUID, let otherHPMUUID = other.hpmUUID, hpmUUID != otherHPMUUID {
            return false
        }
        // Some child nodes omit a controller UUID, so complete port identity remains a compatibility fallback.
        if portType == other.portType {
            return true
        }

        return hpmUUID != nil
            && hpmUUID == other.hpmUUID
            && (portType == 0 || other.portType == 0)
    }
}

final class DarwinCableSnapshotProvider: CableSnapshotProviding {
    private let reader = IOKitCableReader()

    func snapshot() async throws -> CableSnapshot {
        try reader.readSnapshot()
    }

    func watch(interval: TimeInterval = 1.0) -> AsyncThrowingStream<CableSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        continuation.yield(try await snapshot())
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }

                    let seconds = max(interval, 0.25)
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private final class IOKitCableReader {
    private let portClasses = [
        "AppleHPMInterfaceType10",
        "AppleHPMInterfaceType11",
        "AppleHPMInterfaceType12",
        "AppleHPMInterfaceType18",
        "AppleTCControllerType10",
        "AppleTCControllerType11",
        "IOPort",
    ]

    private let identityClasses = [
        "IOPortTransportComponentCCUSBPDSOP",
        "IOPortTransportComponentCCUSBPDSOPp",
        "IOPortTransportComponentCCUSBPDSOPpp",
    ]

    func readSnapshot() throws -> CableSnapshot {
        let adapter = readAdapter()
        let battery = readBatteryState()
        let portRecords = readPorts()
        let identityRecords = readIdentities()
        let powerRecords = readPowerSources()
        let usb3Records = readUSB3Transports()
        let cioRecords = readCIOCapabilities()
        let displayRecords = readDisplayTransports()

        let ports = portRecords.map { portRecord -> CablePortSnapshot in
            let identities = identityRecords
                .filter { $0.join.matches(portRecord.join) }
                .map(\.identity)
                .sorted { $0.endpoint.rawValue < $1.endpoint.rawValue }

            let capability = identities
                .compactMap { PDVDO.cableCapability(endpoint: $0.endpoint, vdos: $0.vdos) }
                .sorted { lhs, rhs in
                    (lhs.maxWatts ?? 0, lhs.speedGbps ?? 0) > (rhs.maxWatts ?? 0, rhs.speedGbps ?? 0)
                }
                .first

            let sourceRecord = powerRecords
                .filter { $0.join.matches(portRecord.join) }
                .max { lhs, rhs in
                    (lhs.winningOption?.maxPowerMW ?? lhs.options.first?.maxPowerMW ?? 0)
                    < (rhs.winningOption?.maxPowerMW ?? rhs.options.first?.maxPowerMW ?? 0)
                }

            let usb3Record = usb3Records
                .filter { $0.join.matches(portRecord.join) }
                .first

            let cioRecord = cioRecords
                .filter { $0.join.matches(portRecord.join) }
                .first

            let display = displayRecords
                .filter { $0.join.matches(portRecord.join) }
                .map(\.display)
                .sorted { ($0.active ? 0 : 1, $0.sinkCount ?? 0) < ($1.active ? 0 : 1, $1.sinkCount ?? 0) }
                .first

            var port = portRecord.port
            port.cableIdentities = identities
            port.cableCapability = capability
            port.powerNegotiation = buildPowerNegotiation(
                source: sourceRecord,
                adapter: adapter,
                cableCapability: capability
            )
            port.dataTransport = buildDataTransport(usb3: usb3Record, cio: cioRecord, capability: capability)
            port.displayTransport = display
            return port
        }

        return CableSnapshot(
            timestamp: Date(),
            ports: ports,
            adapter: adapter,
            isDesktopMac: battery.isDesktopMac,
            batteryFullyCharged: battery.fullyCharged,
            batteryIsCharging: battery.isCharging
        )
    }

    private func readPorts() -> [PortRecord] {
        var records: [PortRecord] = []
        var seenIDs = Set<UInt64>()

        for className in portClasses {
            enumerateServices(matching: className) { service in
                guard let record = makePortRecord(from: service),
                      !seenIDs.contains(record.port.id) else {
                    return
                }

                seenIDs.insert(record.port.id)
                records.append(record)
            }
        }

        return records.sorted { lhs, rhs in
            let lhsActive = lhs.port.connectionActive == true
            let rhsActive = rhs.port.connectionActive == true
            if lhsActive != rhsActive {
                return lhsActive
            }
            return lhs.port.name < rhs.port.name
        }
    }

    private func makePortRecord(from service: io_service_t) -> PortRecord? {
        guard let entryID = registryEntryID(service),
              let type = readString(service, "PortTypeDescription") else {
            return nil
        }

        let serviceName = registryEntryNameWithLocation(service)
        let isRealPort = (type == "USB-C" || type.hasPrefix("MagSafe")) && serviceName.hasPrefix("Port-")
        guard isRealPort else {
            return nil
        }

        let className = registryClassName(service) ?? "Unknown"
        let portNumber = readInt(service, "PortNumber")
        let supported = readStringArray(service, "TransportsSupported")
        let active = readStringArray(service, "TransportsActive")
        let provisioned = readStringArray(service, "TransportsProvisioned")
        let rawKeys = [
            "PortType",
            "PortTypeDescription",
            "PortDescription",
            "PortNumber",
            "ConnectionActive",
            "TransportsSupported",
            "TransportsActive",
            "TransportsProvisioned",
            "PlugOrientation",
            "DisplayPortPinAssignment",
            "IOAccessoryPowerCurrentLimits",
            "IOAccessoryUSBActive",
            "IOAccessoryUSBSuperSpeedActive",
            "IOAccessoryUSBModeType",
            "IOAccessoryUSBConnectString",
            "FeaturesEnabled",
        ]
        let raw = Dictionary(uniqueKeysWithValues: rawKeys.compactMap { key in
            readPropertyValue(service, key).map { (key, $0) }
        })

        let portType = readInt(service, "PortType") ?? defaultPortTypeCode(for: type)
        let join = CableRegistryJoin(
            hpmUUID: hpmControllerUUID(for: service),
            portType: portType,
            portNumber: portNumber
        )

        let port = CablePortSnapshot(
            id: entryID,
            name: readString(service, "PortDescription") ?? serviceName,
            className: className,
            type: type,
            portNumber: portNumber,
            connectionActive: readBool(service, "ConnectionActive"),
            pdCapable: supported.contains("CC"),
            transportsSupported: supported,
            transportsActive: active,
            transportsProvisioned: provisioned,
            plugOrientation: readInt(service, "PlugOrientation"),
            cableIdentities: [],
            cableCapability: nil,
            powerNegotiation: nil,
            dataTransport: nil,
            displayTransport: nil,
            rawProperties: raw
        )

        return PortRecord(port: port, join: join)
    }

    private func readIdentities() -> [IdentityRecord] {
        var records: [IdentityRecord] = []
        var seenIDs = Set<UInt64>()

        for className in identityClasses {
            enumerateServices(matching: className) { service in
                guard let record = makeIdentityRecord(from: service),
                      !seenIDs.contains(record.id) else {
                    return
                }

                seenIDs.insert(record.id)
                records.append(record)
            }
        }

        return records
    }

    private func makeIdentityRecord(from service: io_service_t) -> IdentityRecord? {
        guard let entryID = registryEntryID(service) else {
            return nil
        }

        let metadata = readDictionary(service, "Metadata")
        let parent = parentPortIdentity(service)
        let className = registryClassName(service)
        let endpoint = identityEndpoint(service: service, className: className)
        let rawVDOData = rawVDODataArray(from: metadata["VDOs"] ?? readProperty(service, "VDOs"))
        let vdos = rawVDOData.flatMap(PDVDO.vdos)
        let derivedIdentity = PDVDO.identityFields(from: vdos)
        let vendorID = intValue(metadata["Vendor ID"])
            ?? intValue(metadata["Vendor ID (SOP1)"])
            ?? readInt(service, "Vendor ID (SOP1)")
            ?? readInt(service, "Vendor ID")
            ?? derivedIdentity.vendorID
        let productID = intValue(metadata["Product ID"])
            ?? intValue(metadata["Product ID (SOP1)"])
            ?? readInt(service, "Product ID (SOP1)")
            ?? readInt(service, "Product ID")
            ?? derivedIdentity.productID
        let bcdDevice = intValue(metadata["bcdDevice"]) ?? derivedIdentity.bcdDevice
        let specRevision = readInt(service, "Specification Revision")

        let identity = CableIdentitySnapshot(
            endpoint: endpoint,
            vendorID: zeroToNil(vendorID),
            productID: zeroToNil(productID),
            vendorName: trimmedString(metadata["Vendor Name"] ?? metadata["VendorName"])
                ?? trimmedString(metadata["ManufacturerName"] ?? metadata["Manufacturer Name"])
                ?? readString(service, "Vendor Name")
                ?? readString(service, "VendorName"),
            productName: trimmedString(metadata["Product Name"] ?? metadata["ProductName"])
                ?? readString(service, "Product Name")
                ?? readString(service, "ProductName"),
            bcdDevice: zeroToNil(bcdDevice),
            specRevision: specRevision.map(pdRevisionLabel),
            vdos: vdos,
            rawVDOData: rawVDOData.isEmpty ? nil : rawVDOData.reduce(Data(), +)
        )

        return IdentityRecord(
            id: entryID,
            identity: identity,
            join: CableRegistryJoin(
                hpmUUID: hpmControllerUUID(for: service),
                portType: parent.type,
                portNumber: parent.number
            )
        )
    }

    private func readPowerSources() -> [PowerSourceRecord] {
        var records: [PowerSourceRecord] = []
        var seenIDs = Set<UInt64>()

        enumerateServices(matching: "IOPortFeaturePowerSource") { service in
            guard let record = makePowerSourceRecord(from: service),
                  !seenIDs.contains(record.id) else {
                return
            }

            seenIDs.insert(record.id)
            records.append(record)
        }

        return records
    }

    private func makePowerSourceRecord(from service: io_service_t) -> PowerSourceRecord? {
        guard let entryID = registryEntryID(service) else {
            return nil
        }

        let parent = parentPortIdentity(service)
        let options = parsePowerOptions(readProperty(service, "PowerSourceOptions"))
        let winning = parsePowerOption(readProperty(service, "WinningPowerSourceOption"))
        return PowerSourceRecord(
            id: entryID,
            sourceName: readString(service, "PowerSourceName"),
            options: options,
            winningOption: winning,
            join: CableRegistryJoin(
                hpmUUID: hpmControllerUUID(for: service),
                portType: parent.type,
                portNumber: parent.number
            )
        )
    }

    private func readUSB3Transports() -> [USB3Record] {
        var records: [USB3Record] = []
        var seenIDs = Set<UInt64>()

        enumerateServices(matching: "IOPortTransportStateUSB3") { service in
            guard let entryID = registryEntryID(service),
                  !seenIDs.contains(entryID) else {
                return
            }
            seenIDs.insert(entryID)

            let parent = parentPortIdentity(service)
            records.append(
                USB3Record(
                    id: entryID,
                    join: CableRegistryJoin(
                        hpmUUID: hpmControllerUUID(for: service),
                        portType: parent.type,
                        portNumber: parent.number
                    ),
                    active: readBool(service, "Active"),
                    signaling: readInt(service, "SuperSpeedSignaling"),
                    signalingDescription: readString(service, "SuperSpeedSignalingDescription"),
                    dataRole: readInt(service, "DataRole") ?? readInt(service, "PortDataRole"),
                    transportRestricted: readBool(service, "TRM_TransportRestricted")
                )
            )
        }

        return records
    }

    private func readCIOCapabilities() -> [CIORecord] {
        var records: [CIORecord] = []
        var seenIDs = Set<UInt64>()

        enumerateServices(matching: "IOPortTransportStateCIO") { service in
            guard let entryID = registryEntryID(service),
                  !seenIDs.contains(entryID) else {
                return
            }
            seenIDs.insert(entryID)

            let parent = parentPortIdentity(service)
            records.append(
                CIORecord(
                    id: entryID,
                    join: CableRegistryJoin(
                        hpmUUID: hpmControllerUUID(for: service),
                        portType: parent.type,
                        portNumber: parent.number
                    ),
                    cableSpeedCode: readInt(service, "CableSpeed") ?? readInt(service, "TRM_CableSpeed"),
                    cableGeneration: readInt(service, "CableGeneration") ?? readInt(service, "TRM_CableGeneration"),
                    asymmetricModeSupported: readBool(service, "AsymmetricModeSupported")
                        ?? readBool(service, "TRM_AsymmetricModeSupported"),
                    transportRestricted: readBool(service, "TRM_TransportRestricted")
                )
            )
        }

        return records
    }

    private func readDisplayTransports() -> [DisplayRecord] {
        var records: [DisplayRecord] = []
        var seenIDs = Set<UInt64>()

        enumerateServices(matching: "IOPortTransportStateDisplayPort") { service in
            guard let record = makeDisplayRecord(from: service),
                  !seenIDs.contains(record.id) else {
                return
            }

            seenIDs.insert(record.id)
            records.append(record)
        }

        return records
    }

    private func makeDisplayRecord(from service: io_service_t) -> DisplayRecord? {
        guard let entryID = registryEntryID(service) else {
            return nil
        }

        let parent = parentPortIdentity(service)
        let metadata = readDictionary(service, "Metadata")
        let linkRateDescription = readString(service, "LinkRateDescription")
        let laneCount = readInt(service, "LaneCount")
        let estimatedPayload = estimateDisplayPayloadGbps(
            laneCount: laneCount,
            linkRateDescription: linkRateDescription,
            linkRate: readInt(service, "LinkRate")
        )

        let monitor = DisplayMonitorSnapshot(
            name: readString(service, "DisplayName") ?? readString(service, "Name"),
            productName: readString(service, "ProductName") ?? stringValue(metadata["ProductName"]),
            vendorName: readString(service, "ManufacturerName") ?? stringValue(metadata["ManufacturerName"]),
            productID: readInt(service, "ProductID") ?? intValue(metadata["ProductID"]),
            vendorID: readInt(service, "VendorID") ?? intValue(metadata["VendorID"]),
            serialNumber: stringValue(readProperty(service, "SerialNumber")) ?? stringValue(metadata["SerialNumber"]),
            isVirtual: readBool(service, "Virtual") ?? readBool(service, "IsVirtual")
        )

        let display = DisplayTransportSnapshot(
            active: readBool(service, "Active") ?? false,
            tunneled: readBool(service, "Tunneled"),
            laneCount: laneCount,
            maxLaneCount: readInt(service, "MaxLaneCount"),
            linkRate: readInt(service, "LinkRate"),
            linkRateDescription: linkRateDescription,
            estimatedPayloadGbps: estimatedPayload,
            hpdState: readInt(service, "HPD_State"),
            role: readString(service, "RoleDescription") ?? readInt(service, "Role").map(String.init),
            sinkCount: readInt(service, "SinkCount"),
            monitors: monitor.hasAnyValue ? [monitor] : []
        )

        return DisplayRecord(
            id: entryID,
            display: display,
            join: CableRegistryJoin(
                hpmUUID: hpmControllerUUID(for: service),
                portType: parent.type,
                portNumber: parent.number
            )
        )
    }

    private func readAdapter() -> PowerAdapterSnapshot? {
        guard let info = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let raw = Dictionary(uniqueKeysWithValues: info.compactMap { key, value in
            propertyValue(from: value).map { (key, $0) }
        })

        return PowerAdapterSnapshot(
            name: trimmedString(info["Name"]),
            manufacturer: trimmedString(info["Manufacturer"]),
            model: trimmedString(info["Model"]),
            description: trimmedString(info["Description"]),
            watts: intValue(info["Watts"]),
            voltageMV: intValue(info["AdapterVoltage"]),
            currentMA: intValue(info["Current"]),
            adapterID: intValue(info["AdapterID"]),
            familyCode: intValue(info["FamilyCode"]),
            rawDetails: raw
        )
    }

    private func readBatteryState() -> (isDesktopMac: Bool, fullyCharged: Bool?, isCharging: Bool?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (true, nil, nil)
        }

        var hasBattery = false
        var fullyCharged: Bool?
        var isCharging: Bool?

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            hasBattery = true
            if let charged = description[kIOPSIsChargedKey as String] as? NSNumber {
                fullyCharged = charged.boolValue
            }
            if let charging = description[kIOPSIsChargingKey as String] as? NSNumber {
                isCharging = charging.boolValue
            }
        }

        return (!hasBattery, fullyCharged, isCharging)
    }
}

private extension IOKitCableReader {
    struct PortRecord {
        var port: CablePortSnapshot
        var join: CableRegistryJoin
    }

    struct IdentityRecord {
        var id: UInt64
        var identity: CableIdentitySnapshot
        var join: CableRegistryJoin
    }

    struct PowerSourceRecord {
        var id: UInt64
        var sourceName: String?
        var options: [PowerOptionSnapshot]
        var winningOption: PowerOptionSnapshot?
        var join: CableRegistryJoin
    }

    struct USB3Record {
        var id: UInt64
        var join: CableRegistryJoin
        var active: Bool?
        var signaling: Int?
        var signalingDescription: String?
        var dataRole: Int?
        var transportRestricted: Bool?
    }

    struct CIORecord {
        var id: UInt64
        var join: CableRegistryJoin
        var cableSpeedCode: Int?
        var cableGeneration: Int?
        var asymmetricModeSupported: Bool?
        var transportRestricted: Bool?
    }

    struct DisplayRecord {
        var id: UInt64
        var display: DisplayTransportSnapshot
        var join: CableRegistryJoin
    }
}

private extension IOKitCableReader {
    func enumerateServices(matching className: String, body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 {
                break
            }
            body(service)
            IOObjectRelease(service)
        }
    }

    func registryEntryID(_ service: io_service_t) -> UInt64? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else {
            return nil
        }
        return entryID
    }

    func registryClassName(_ service: io_service_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(service, &buffer) == KERN_SUCCESS else {
            return nil
        }
        return String(cString: buffer)
    }

    func registryEntryNameWithLocation(_ service: io_service_t) -> String {
        var nameBuffer = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(service, &nameBuffer)
        let baseName = String(cString: nameBuffer)

        var locationBuffer = [CChar](repeating: 0, count: 128)
        if IORegistryEntryGetLocationInPlane(service, kIOServicePlane, &locationBuffer) == KERN_SUCCESS {
            let location = String(cString: locationBuffer)
            if !location.isEmpty {
                return "\(baseName)@\(location)"
            }
        }

        return baseName
    }

    func readProperty(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    func readString(_ service: io_service_t, _ key: String) -> String? {
        trimmedString(readProperty(service, key))
    }

    func readInt(_ service: io_service_t, _ key: String) -> Int? {
        intValue(readProperty(service, key))
    }

    func readBool(_ service: io_service_t, _ key: String) -> Bool? {
        boolValue(readProperty(service, key))
    }

    func readStringArray(_ service: io_service_t, _ key: String) -> [String] {
        stringArrayValue(readProperty(service, key))
    }

    func readDictionary(_ service: io_service_t, _ key: String) -> [String: Any] {
        dictionaryValue(readProperty(service, key))
    }

    func readPropertyValue(_ service: io_service_t, _ key: String) -> CablePropertyValue? {
        propertyValue(from: readProperty(service, key))
    }

    func hpmControllerUUID(for service: io_service_t) -> String? {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<12 {
            if let className = registryClassName(current),
               className == "AppleHPMDevice" || className.hasPrefix("AppleHPMDeviceHAL") {
                return readString(current, "UUID")
            }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                break
            }
            IOObjectRelease(current)
            current = parent
        }

        return nil
    }

    func parentPortIdentity(_ service: io_service_t) -> (type: Int, number: Int?) {
        let type = readInt(service, "ParentBuiltInPortType")
            ?? readInt(service, "ParentPortType")
            ?? readInt(service, "PortType")
            ?? 0
        let number = readInt(service, "ParentBuiltInPortNumber")
            ?? readInt(service, "ParentPortNumber")
            ?? readInt(service, "PortNumber")
            ?? readInt(service, "Priority").map { $0 & 0xff }
        return (type, number)
    }

    func identityEndpoint(service: io_service_t, className: String?) -> CableIdentityEndpoint {
        if let componentName = readString(service, "ComponentName")
            ?? readString(service, "AddressDescription")
            ?? readString(service, "Address Description") {
            switch componentName {
            case "SOP":
                return .sop
            case "SOP'":
                return .sopPrime
            case "SOP''":
                return .sopDoublePrime
            default:
                break
            }
        }

        switch className {
        case "IOPortTransportComponentCCUSBPDSOP":
            return .sop
        case "IOPortTransportComponentCCUSBPDSOPp":
            return .sopPrime
        case "IOPortTransportComponentCCUSBPDSOPpp":
            return .sopDoublePrime
        default:
            break
        }

        switch readString(service, "TransportTypeDescription") {
        case "SOP":
            return .sop
        case "SOP'", "CC":
            return .sopPrime
        case "SOP''":
            return .sopDoublePrime
        default:
            return .sop
        }
    }

    func rawVDODataArray(from value: Any?) -> [Data] {
        if let data = value as? Data {
            return [data]
        }
        if let array = value as? [Any] {
            return array.compactMap { $0 as? Data }
        }
        if let array = value as? NSArray {
            return array.compactMap { $0 as? Data }
        }
        return []
    }

    func parsePowerOptions(_ value: Any?) -> [PowerOptionSnapshot] {
        let items: [Any]
        if let set = value as? NSSet {
            items = set.allObjects
        } else if let array = value as? NSArray {
            items = array.map { $0 }
        } else if let array = value as? [Any] {
            items = array
        } else {
            return []
        }

        return items.compactMap(parsePowerOption)
            .sorted { $0.maxPowerMW > $1.maxPowerMW }
    }

    func parsePowerOption(_ value: Any?) -> PowerOptionSnapshot? {
        let dict = dictionaryValue(value)
        let voltage = intValue(dict["Voltage (mV)"]) ?? intValue(dict["Voltage"]) ?? 0
        let current = intValue(dict["Max Current (mA)"]) ?? intValue(dict["Current"]) ?? 0
        let power = intValue(dict["Max Power (mW)"]) ?? (voltage * current / 1_000)
        guard voltage > 0, current > 0 else {
            return nil
        }
        return PowerOptionSnapshot(voltageMV: voltage, maxCurrentMA: current, maxPowerMW: power)
    }
}

private extension IOKitCableReader {
    func buildPowerNegotiation(
        source: PowerSourceRecord?,
        adapter: PowerAdapterSnapshot?,
        cableCapability: CableCapabilitySnapshot?
    ) -> PowerNegotiationSnapshot? {
        guard source != nil || adapter != nil || cableCapability != nil else {
            return nil
        }

        let options = source?.options ?? []
        let winning = source?.winningOption
        let negotiatedWatts = winning?.watts ?? options.first?.watts
        let chargerWatts = adapter?.watts.map(Double.init) ?? options.first?.watts
        let cableWatts = cableCapability?.maxWatts

        let bottleneck: PowerBottleneck = {
            guard let chargerWatts else {
                return cableWatts == nil ? .unknown : .none
            }
            if let cableWatts, cableWatts + 0.5 < chargerWatts {
                return .cable
            }
            if let negotiatedWatts, negotiatedWatts + max(5.0, chargerWatts * 0.1) < chargerWatts {
                return .mac
            }
            if negotiatedWatts == nil {
                return .unknown
            }
            return .none
        }()

        return PowerNegotiationSnapshot(
            sourceName: source?.sourceName,
            options: options,
            winningOption: winning,
            negotiatedWatts: negotiatedWatts,
            chargerWatts: chargerWatts,
            cableMaxWatts: cableWatts,
            likelyBottleneck: bottleneck
        )
    }

    func buildDataTransport(
        usb3: USB3Record?,
        cio: CIORecord?,
        capability: CableCapabilitySnapshot?
    ) -> DataTransportSnapshot? {
        guard usb3 != nil || cio != nil || capability != nil else {
            return nil
        }

        let usb3Gbps = usb3?.signaling.flatMap(usb3SpeedGbps)
        let cioGbps = cio?.cableSpeedCode.flatMap(cioCableSpeedGbps)
        let advertised = capability?.speedGbps
        let activeGbps = [usb3Gbps, cioGbps, advertised].compactMap { $0 }.min()

        return DataTransportSnapshot(
            active: usb3?.active ?? (cio != nil),
            usb3Signaling: usb3?.signaling,
            usb3Description: usb3?.signalingDescription,
            controllerCableSpeedGbps: cioGbps,
            cableAdvertisedSpeedGbps: advertised,
            effectiveSpeedGbps: activeGbps,
            dataRole: usb3?.dataRole,
            transportRestricted: usb3?.transportRestricted ?? cio?.transportRestricted
        )
    }

    func estimateDisplayPayloadGbps(
        laneCount: Int?,
        linkRateDescription: String?,
        linkRate: Int?
    ) -> Double? {
        guard let lanes = laneCount, lanes > 0 else {
            return nil
        }

        let perLane: Double?
        let description = linkRateDescription?.uppercased()
        if description?.contains("UHBR20") == true {
            perLane = 20
        } else if description?.contains("UHBR13.5") == true || description?.contains("UHBR13") == true {
            perLane = 13.5
        } else if description?.contains("UHBR10") == true {
            perLane = 10
        } else if description?.contains("HBR3") == true {
            perLane = 8.1
        } else if description?.contains("HBR2") == true {
            perLane = 5.4
        } else if description?.contains("HBR") == true {
            perLane = 2.7
        } else if description?.contains("RBR") == true {
            perLane = 1.62
        } else if let linkRate, linkRate > 0 {
            perLane = Double(linkRate) / 100_000.0
        } else {
            perLane = nil
        }

        guard let perLane else {
            return nil
        }

        let encodingEfficiency: Double = perLane >= 10 ? 128.0 / 132.0 : 0.8
        return Double(lanes) * perLane * encodingEfficiency
    }
}

private extension IOKitCableReader {
    func defaultPortTypeCode(for description: String) -> Int {
        description.hasPrefix("MagSafe") ? 17 : 2
    }

    func zeroToNil(_ value: Int?) -> Int? {
        guard let value, value != 0 else {
            return nil
        }
        return value
    }

    func pdRevisionLabel(_ raw: Int) -> String {
        switch raw {
        case 0x10:
            return "PD 1.0"
        case 0x20:
            return "PD 2.0"
        case 0x30:
            return "PD 3.0"
        case 0x31:
            return "PD 3.1"
        default:
            return "0x" + String(raw, radix: 16)
        }
    }

    func usb3SpeedGbps(_ signaling: Int) -> Double? {
        switch signaling {
        case 1:
            return 5
        case 2:
            return 10
        case 3:
            return 20
        default:
            return nil
        }
    }

    func cioCableSpeedGbps(_ speed: Int) -> Double? {
        switch speed {
        case 2:
            return 20
        case 3:
            return 40
        case 4:
            return 80
        default:
            return nil
        }
    }
}

private extension IOKitCableReader {
    func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let int = value as? Int {
            return int
        }
        if let uint = value as? UInt {
            return Int(uint)
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    func boolValue(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let bool = value as? Bool {
            return bool
        }
        return nil
    }

    func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    func trimmedString(_ value: Any?) -> String? {
        guard let string = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }
        return string
    }

    func stringArrayValue(_ value: Any?) -> [String] {
        if let array = value as? [String] {
            return array
        }
        if let array = value as? NSArray {
            return array.compactMap { $0 as? String }
        }
        if let string = value as? String {
            return [string]
        }
        return []
    }

    func dictionaryValue(_ value: Any?) -> [String: Any] {
        if let dict = value as? [String: Any] {
            return dict
        }
        if let dict = value as? NSDictionary {
            var converted: [String: Any] = [:]
            for case let (key, value) as (String, Any) in dict {
                converted[key] = value
            }
            return converted
        }
        return [:]
    }

    func propertyValue(from value: Any?) -> CablePropertyValue? {
        if let bool = value as? Bool {
            return .bool(bool)
        }
        if let number = value as? NSNumber {
            let objcType = String(cString: number.objCType)
            if objcType == "c" || objcType == "B" {
                return .bool(number.boolValue)
            }
            return .int(number.int64Value)
        }
        if let string = value as? String {
            return .string(string)
        }
        if let data = value as? Data {
            return .data(data)
        }
        let strings = stringArrayValue(value)
        if !strings.isEmpty {
            return .stringArray(strings)
        }
        return nil
    }
}

private extension DisplayMonitorSnapshot {
    var hasAnyValue: Bool {
        name != nil
            || productName != nil
            || vendorName != nil
            || productID != nil
            || vendorID != nil
            || serialNumber != nil
            || isVirtual != nil
    }
}
