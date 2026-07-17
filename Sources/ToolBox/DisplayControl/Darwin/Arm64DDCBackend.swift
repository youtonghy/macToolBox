// Portions derived from MonitorControl's Arm64DDC implementation.
// MonitorControl is MIT licensed. See THIRD_PARTY_NOTICES.md.

import CoreGraphics
import Foundation
import IOKit

final class Arm64DDCBackend: DDCTransport {
    #if arch(arm64)
    static let isArm64 = true
    #else
    static let isArm64 = false
    #endif

    static let maxMatchScore = 20

    let service: IOAVService
    let backendName = "DDC/CI over IOAVService"

    init(service: IOAVService) {
        self.service = service
    }

    func read(command: UInt8, options: DDCRequestOptions) -> DDCReadResult? {
        var send = [command]
        var reply = [UInt8](repeating: 0, count: 11)

        guard Self.performDDCCommunication(
            service: service,
            send: &send,
            reply: &reply,
            writeSleepMicros: options.writeSleepMicros,
            writeCycles: options.writeCycles,
            readSleepMicros: options.minReplyDelayMicros.map { UInt32($0) },
            retryAttempts: UInt8(min(options.readAttempts, UInt(UInt8.max))),
            retrySleepMicros: options.errorRecoveryWaitMicros
        ) else {
            return nil
        }

        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return DDCReadResult(current: current, maximum: maximum)
    }

    func write(command: UInt8, value: UInt16, options: DDCRequestOptions) -> Bool {
        var send = [command, UInt8(value >> 8), UInt8(value & 0xff)]
        var reply: [UInt8] = []
        return Self.performDDCCommunication(
            service: service,
            send: &send,
            reply: &reply,
            writeSleepMicros: options.writeSleepMicros,
            writeCycles: options.writeCycles,
            retryAttempts: UInt8(min(options.readAttempts, UInt(UInt8.max))),
            retrySleepMicros: options.errorRecoveryWaitMicros
        )
    }
}

struct Arm64DDCServiceMatch {
    var displayID: CGDirectDisplayID
    var service: IOAVService?
    var serviceLocation: Int
    var discouraged: Bool
    var dummy: Bool
    var matchScore: Int
}

private struct Arm64IORegService {
    var edidUUID = ""
    var manufacturerID = ""
    var productName = ""
    var serialNumber: Int64 = 0
    var alphanumericSerialNumber = ""
    var location = ""
    var ioDisplayLocation = ""
    var transportUpstream = ""
    var transportDownstream = ""
    var service: IOAVService?
    var serviceLocation = 0
    var displayAttributes: NSDictionary?
}

private enum Arm64DDCConstants {
    static let ddcAddress: UInt8 = 0x37
    static let dataAddress: UInt8 = 0x51
}

extension Arm64DDCBackend {
    static func serviceMatches(displayIDs: [CGDirectDisplayID]) -> [Arm64DDCServiceMatch] {
        let services = ioregServicesForMatching()
        var scoredCandidates: [Int: [Arm64DDCServiceMatch]] = [:]

        for displayID in displayIDs {
            for service in services {
                let score = ioregMatchScore(
                    displayID: displayID,
                    ioregEdidUUID: service.edidUUID,
                    ioDisplayLocation: service.ioDisplayLocation,
                    ioregProductName: service.productName,
                    ioregSerialNumber: service.serialNumber
                )
                let match = Arm64DDCServiceMatch(
                    displayID: displayID,
                    service: service.service,
                    serviceLocation: service.serviceLocation,
                    discouraged: checkIfDiscouraged(ioregService: service),
                    dummy: checkIfDummy(ioregService: service),
                    matchScore: score
                )
                scoredCandidates[score, default: []].append(match)
            }
        }

        var matches: [Arm64DDCServiceMatch] = []
        var takenDisplayIDs = Set<CGDirectDisplayID>()
        var takenLocations = Set<Int>()
        for score in stride(from: maxMatchScore, to: 0, by: -1) {
            for candidate in scoredCandidates[score] ?? [] {
                guard !takenDisplayIDs.contains(candidate.displayID),
                      !takenLocations.contains(candidate.serviceLocation) else {
                    continue
                }
                takenDisplayIDs.insert(candidate.displayID)
                takenLocations.insert(candidate.serviceLocation)
                matches.append(candidate)
            }
        }
        return matches
    }

    private static func performDDCCommunication(
        service: IOAVService?,
        send: inout [UInt8],
        reply: inout [UInt8],
        writeSleepMicros: UInt32,
        writeCycles: UInt8,
        readSleepMicros: UInt32? = nil,
        retryAttempts: UInt8,
        retrySleepMicros: UInt32? = nil
    ) -> Bool {
        guard let service else { return false }

        var success = false
        var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        let checksumSeed = send.count == 1
            ? Arm64DDCConstants.ddcAddress << 1
            : Arm64DDCConstants.ddcAddress << 1 ^ Arm64DDCConstants.dataAddress
        packet[packet.count - 1] = checksum(seed: checksumSeed, data: packet, start: 0, end: packet.count - 2)

        for _ in 0...retryAttempts {
            for _ in 0..<max(writeCycles, 1) {
                usleep(writeSleepMicros)
                success = IOAVServiceWriteI2C(
                    service,
                    UInt32(Arm64DDCConstants.ddcAddress),
                    UInt32(Arm64DDCConstants.dataAddress),
                    &packet,
                    UInt32(packet.count)
                ) == 0
            }

            if !reply.isEmpty {
                usleep(readSleepMicros ?? 50_000)
                if IOAVServiceReadI2C(
                    service,
                    UInt32(Arm64DDCConstants.ddcAddress),
                    0,
                    &reply,
                    UInt32(reply.count)
                ) == 0 {
                    success = checksum(seed: 0x50, data: reply, start: 0, end: reply.count - 2) == reply[reply.count - 1]
                }
            }

            if success {
                return true
            }
            usleep(retrySleepMicros ?? 20_000)
        }

        return false
    }

    private static func checksum(seed: UInt8, data: [UInt8], start: Int, end: Int) -> UInt8 {
        var checksum = seed
        guard start <= end else { return checksum }
        for index in start...end {
            checksum ^= data[index]
        }
        return checksum
    }

    private static func ioregMatchScore(
        displayID: CGDirectDisplayID,
        ioregEdidUUID: String,
        ioDisplayLocation: String,
        ioregProductName: String,
        ioregSerialNumber: Int64
    ) -> Int {
        var score = 0
        guard let dictionary = CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue() as NSDictionary? else {
            return score
        }

        if let vendorID = dictionary[kDisplayVendorID] as? Int64,
           let productID = dictionary[kDisplayProductID] as? Int64,
           let week = dictionary[kDisplayWeekOfManufacture] as? Int64,
           let year = dictionary[kDisplayYearOfManufacture] as? Int64,
           let width = dictionary[kDisplayHorizontalImageSize] as? Int64,
           let height = dictionary[kDisplayVerticalImageSize] as? Int64 {
            let searchKeys: [(key: String, location: Int)] = [
                (String(format: "%04x", UInt16(max(0, min(vendorID, 65_535)))).uppercased(), 0),
                (
                    String(format: "%02x", UInt8((UInt16(max(0, min(productID, 65_535))) >> 0) & 0xff)).uppercased()
                    + String(format: "%02x", UInt8((UInt16(max(0, min(productID, 65_535))) >> 8) & 0xff)).uppercased(),
                    4
                ),
                (
                    String(format: "%02x", UInt8(max(0, min(week, 255)))).uppercased()
                    + String(format: "%02x", UInt8(max(0, min(year - 1990, 255)))).uppercased(),
                    19
                ),
                (
                    String(format: "%02x", UInt8(max(0, min(width / 10, 255)))).uppercased()
                    + String(format: "%02x", UInt8(max(0, min(height / 10, 255)))).uppercased(),
                    30
                ),
            ]
            for search in searchKeys where search.key != "0000"
                && ioregEdidUUID.prefix(search.location + 4).suffix(4) == search.key {
                score += 1
            }
        }

        if !ioDisplayLocation.isEmpty,
           let displayLocation = dictionary[kIODisplayLocationKey] as? String,
           displayLocation == ioDisplayLocation {
            score += 10
        }
        if !ioregProductName.isEmpty,
           let names = dictionary["DisplayProductName"] as? [String: String],
           let name = names["en_US"] ?? names.first?.value,
           name.lowercased() == ioregProductName.lowercased() {
            score += 1
        }
        if ioregSerialNumber != 0,
           let serialNumber = dictionary[kDisplaySerialNumber] as? Int64,
           serialNumber == ioregSerialNumber {
            score += 1
        }

        return score
    }

    private static func ioregServicesForMatching() -> [Arm64IORegService] {
        var serviceLocation = 0
        var services: [Arm64IORegService] = []
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else {
            return services
        }
        defer { IOObjectRelease(root) }

        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return services
        }
        defer { IOObjectRelease(iterator) }

        let framebufferKeys = ["AppleCLCD2", "IOMobileFramebufferShim"]
        var current = Arm64IORegService()

        while true {
            guard let object = iterateToNextObjectOfInterest(interests: ["DCPAVServiceProxy"] + framebufferKeys, iterator: &iterator) else {
                break
            }

            if framebufferKeys.contains(object.name) {
                current = ioregServiceProperties(entry: object.entry)
                serviceLocation += 1
                current.serviceLocation = serviceLocation
                IOObjectRelease(object.entry)
            } else if object.name == "DCPAVServiceProxy" {
                setDCPAVServiceProxy(entry: object.entry, ioregService: &current)
                services.append(current)
                IOObjectRelease(object.entry)
            }
        }

        return services
    }

    private static func iterateToNextObjectOfInterest(
        interests: [String],
        iterator: inout io_iterator_t
    ) -> (name: String, entry: io_service_t)? {
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else {
                return nil
            }

            let namePointer = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
            defer { namePointer.deallocate() }

            guard IORegistryEntryGetName(entry, namePointer) == KERN_SUCCESS else {
                IOObjectRelease(entry)
                continue
            }

            let name = String(cString: namePointer)
            if interests.contains(where: { name.contains($0) }) {
                return (name, entry)
            }

            IOObjectRelease(entry)
        }
    }

    private static func ioregServiceProperties(entry: io_service_t) -> Arm64IORegService {
        var service = Arm64IORegService()
        if let unmanaged = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)),
           let edidUUID = unmanaged.takeRetainedValue() as? String {
            service.edidUUID = edidUUID
        }

        let pathPointer = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
        defer { pathPointer.deallocate() }
        if IORegistryEntryGetPath(entry, kIOServicePlane, pathPointer) == KERN_SUCCESS {
            service.ioDisplayLocation = String(cString: pathPointer)
        }

        if let unmanaged = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)),
           let attrs = unmanaged.takeRetainedValue() as? NSDictionary {
            service.displayAttributes = attrs
            if let productAttrs = attrs["ProductAttributes"] as? NSDictionary {
                service.manufacturerID = productAttrs["ManufacturerID"] as? String ?? ""
                service.productName = productAttrs["ProductName"] as? String ?? ""
                service.serialNumber = productAttrs["SerialNumber"] as? Int64 ?? 0
                service.alphanumericSerialNumber = productAttrs["AlphanumericSerialNumber"] as? String ?? ""
            }
        }

        if let unmanaged = IORegistryEntryCreateCFProperty(entry, "Transport" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)),
           let transport = unmanaged.takeRetainedValue() as? NSDictionary {
            service.transportUpstream = transport["Upstream"] as? String ?? ""
            service.transportDownstream = transport["Downstream"] as? String ?? ""
        }

        return service
    }

    private static func setDCPAVServiceProxy(entry: io_service_t, ioregService: inout Arm64IORegService) {
        guard let unmanaged = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)),
              let location = unmanaged.takeRetainedValue() as? String else {
            return
        }

        ioregService.location = location
        if location == "External" {
            ioregService.service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() as IOAVService
        }
    }

    private static func checkIfDummy(ioregService: Arm64IORegService) -> Bool {
        ioregService.manufacturerID == "AOC" && ioregService.productName == "28E850"
    }

    private static func checkIfDiscouraged(ioregService _: Arm64IORegService) -> Bool {
        false
    }
}
