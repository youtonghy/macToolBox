import Foundation

enum PDVDO {
    static func vdos(from data: Data) -> [UInt32] {
        var result: [UInt32] = []
        var index = data.startIndex

        while index + 4 <= data.endIndex {
            let value = UInt32(data[index])
                | (UInt32(data[index + 1]) << 8)
                | (UInt32(data[index + 2]) << 16)
                | (UInt32(data[index + 3]) << 24)
            result.append(value)
            index += 4
        }

        return result
    }

    static func identityFields(from vdos: [UInt32]) -> (vendorID: Int?, productID: Int?, bcdDevice: Int?) {
        guard !vdos.isEmpty else {
            return (nil, nil, nil)
        }

        let header = vdos[0]
        let vendorID = Int(header & 0xffff)
        var productID: Int?
        var bcdDevice: Int?

        if vdos.count > 2 {
            productID = Int(vdos[2] & 0xffff)
            bcdDevice = Int((vdos[2] >> 16) & 0xffff)
        }

        return (
            vendorID == 0 ? nil : vendorID,
            productID == 0 ? nil : productID,
            bcdDevice == 0 ? nil : bcdDevice
        )
    }

    static func cableCapability(
        endpoint: CableIdentityEndpoint,
        vdos: [UInt32]
    ) -> CableCapabilitySnapshot? {
        guard endpoint == .sopPrime || endpoint == .sopDoublePrime else {
            return nil
        }

        let cableVDOIndex = firstLikelyCableVDOIndex(in: vdos)
        guard cableVDOIndex < vdos.count else {
            return nil
        }

        return decodeCableVDO(vdos[cableVDOIndex], endpoint: endpoint)
    }

    private static func firstLikelyCableVDOIndex(in vdos: [UInt32]) -> Int {
        if vdos.count > 3 {
            return 3
        }
        if vdos.count > 1 {
            return 1
        }
        return vdos.count
    }

    private static func decodeCableVDO(
        _ raw: UInt32,
        endpoint: CableIdentityEndpoint
    ) -> CableCapabilitySnapshot {
        let speedCode = Int(raw & 0x7)
        let currentCode = Int((raw >> 5) & 0x3)
        let cableTypeCode = Int((raw >> 18) & 0x3)
        let active = cableTypeCode == 1
        let eprCapable = ((raw >> 23) & 0x1) == 1
        let vbusThroughCable = ((raw >> 20) & 0x1) == 1
        let sopDoublePrime = ((raw >> 21) & 0x1) == 1
        let latency = Int((raw >> 13) & 0xf)
        let termination = Int((raw >> 11) & 0x3)
        let version = Int((raw >> 24) & 0x7)
        let maxVoltage = eprCapable ? 50.0 : 20.0

        let speed = speedFields(for: speedCode)
        let current = currentFields(for: currentCode)
        let watts = current.amps.map { amps in
            // EPR cables advertise 50 V in the VDO, but USB-PD EPR power profiles top out at 48 V.
            let voltageForPower = eprCapable ? 48.0 : maxVoltage
            return voltageForPower * amps
        }

        var warnings: [String] = []
        if speed.warning != nil {
            warnings.append(speed.warning!)
        }
        if current.warning != nil {
            warnings.append(current.warning!)
        }

        return CableCapabilitySnapshot(
            sourceEndpoint: endpoint,
            vdoVersion: version == 0 ? nil : version,
            cableType: cableType(for: cableTypeCode),
            maxCurrentA: current.amps,
            maxVoltageV: maxVoltage,
            maxWatts: watts,
            speedGbps: speed.gbps,
            speedDescription: speed.description,
            cableLatency: latency,
            cableTermination: termination,
            eprCapable: eprCapable,
            vbusThroughCable: vbusThroughCable,
            activeCable: active,
            hasSOPDoublePrimeController: sopDoublePrime,
            warnings: warnings
        )
    }

    private static func cableType(for code: Int) -> CableTypeSnapshot {
        switch code {
        case 0:
            return .passive
        case 1:
            return .active
        case 2:
            return .opticallyIsolated
        default:
            return .unknown
        }
    }

    private static func speedFields(for code: Int) -> (gbps: Double?, description: String?, warning: String?) {
        switch code {
        case 0:
            return (0.48, "USB 2.0", nil)
        case 1:
            return (5, "USB 3.2 Gen 1", nil)
        case 2:
            return (10, "USB 3.2 Gen 2", nil)
        case 3:
            return (40, "USB4 Gen 3", nil)
        case 4:
            return (80, "USB4 Gen 4", nil)
        default:
            return (nil, nil, "Unknown USB-PD cable speed code \(code).")
        }
    }

    private static func currentFields(for code: Int) -> (amps: Double?, warning: String?) {
        switch code {
        case 0, 1:
            return (3, nil)
        case 2:
            return (5, nil)
        default:
            return (nil, "Unknown USB-PD cable current code \(code).")
        }
    }
}
