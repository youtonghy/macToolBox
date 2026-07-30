// Portions derived from MonitorControl's IntelDDC implementation.
// MonitorControl is MIT licensed. See THIRD_PARTY_NOTICES.md.

import CoreGraphics
import Foundation
import IOKit.i2c
import OSLog

final class IntelDDCBackend: DDCTransport {
    let displayID: CGDirectDisplayID
    let framebuffer: io_service_t
    let replyTransactionType: IOOptionBits
    let backendName = "DDC/CI over IOKit I2C"

    private static let logger = Logger(subsystem: "ToolBox", category: "IntelDDC")

    deinit {
        if framebuffer != IO_OBJECT_NULL {
            IOObjectRelease(framebuffer)
        }
    }

    init?(displayID: CGDirectDisplayID, replyTransactionType: IOOptionBits? = nil) {
        self.displayID = displayID
        guard let framebuffer = Self.ioFramebufferPort(displayID: displayID) else {
            return nil
        }
        self.framebuffer = framebuffer

        if let replyTransactionType {
            self.replyTransactionType = replyTransactionType
        } else if let replyTransactionType = Self.supportedTransactionType() {
            self.replyTransactionType = replyTransactionType
        } else {
            Self.logger.error("No supported DDC reply transaction type for display \(displayID, privacy: .public).")
            return nil
        }
    }

    func write(command: UInt8, value: UInt16, options: DDCRequestOptions) -> Bool {
        var success = false
        var data: [UInt8] = Array(repeating: 0, count: 7)

        data[0] = 0x51
        data[1] = 0x84
        data[2] = 0x03
        data[3] = command
        data[4] = UInt8(value >> 8)
        data[5] = UInt8(value & 0xff)
        data[6] = 0x6e ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^ data[4] ^ data[5]

        for _ in 0..<max(options.writeCycles, 1) {
            usleep(options.writeSleepMicros)
            let didSend = data.withUnsafeMutableBufferPointer { buffer -> Bool in
                guard let baseAddress = buffer.baseAddress else { return false }
                var request = IOI2CRequest()
                request.commFlags = 0
                request.sendAddress = 0x6e
                request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                request.sendBuffer = vm_address_t(bitPattern: baseAddress)
                request.sendBytes = UInt32(buffer.count)
                request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                request.replyBytes = 0
                return Self.send(
                    request: &request,
                    to: framebuffer,
                    errorRecoveryWaitMicros: options.errorRecoveryWaitMicros
                )
            }
            if didSend {
                success = true
            }
        }

        return success
    }

    func readOutcome(command: UInt8, options: DDCRequestOptions) -> DDCReadOutcome {
        var data: [UInt8] = Array(repeating: 0, count: 5)
        var replyData: [UInt8] = Array(repeating: 0, count: 11)

        data[0] = 0x51
        data[1] = 0x82
        data[2] = 0x01
        data[3] = command
        data[4] = 0x6e ^ data[0] ^ data[1] ^ data[2] ^ data[3]

        for attempt in 1...max(options.readAttempts, 1) {
            usleep(options.writeSleepMicros)
            if let wait = options.errorRecoveryWaitMicros {
                usleep(wait)
            }

            let didSend = data.withUnsafeMutableBufferPointer { sendBuffer in
                replyData.withUnsafeMutableBufferPointer { replyBuffer -> Bool in
                    guard let sendAddress = sendBuffer.baseAddress,
                          let replyAddress = replyBuffer.baseAddress else {
                        return false
                    }
                    var request = IOI2CRequest()
                    request.commFlags = 0
                    request.sendAddress = 0x6e
                    request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                    request.sendBuffer = vm_address_t(bitPattern: sendAddress)
                    request.sendBytes = UInt32(sendBuffer.count)
                    request.minReplyDelay = options.minReplyDelayMicros ?? 10
                    request.replyAddress = 0x6f
                    request.replySubAddress = 0x51
                    request.replyTransactionType = replyTransactionType
                    request.replyBytes = UInt32(replyBuffer.count)
                    request.replyBuffer = vm_address_t(bitPattern: replyAddress)
                    return Self.send(
                        request: &request,
                        to: framebuffer,
                        errorRecoveryWaitMicros: options.errorRecoveryWaitMicros
                    )
                }
            }
            guard didSend else {
                continue
            }

            switch DDCFeatureReplyParser.parse(replyData, expectedCommand: command) {
            case .success(let result):
                return .success(result)
            case .failure(.unsupportedReply(let resultCode)):
                Self.logger.info("DDC command \(command, privacy: .public) unsupported for display \(self.displayID, privacy: .public).")
                return .failure(.unsupportedReply(resultCode: resultCode))
            case .failure:
                Self.logger.info("Invalid DDC response for display \(self.displayID, privacy: .public), attempt \(attempt, privacy: .public).")
                continue
            }
        }

        return .failure(.transportFailure)
    }

    private static func supportedTransactionType() -> IOOptionBits? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("IOFramebufferI2CInterface"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, IOOptionBits()) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as NSDictionary?,
                  let types = dict[kIOI2CTransactionTypesKey] as? UInt64 else {
                continue
            }

            if (1 << kIOI2CDDCciReplyTransactionType) & types != 0 {
                return IOOptionBits(kIOI2CDDCciReplyTransactionType)
            }
            if (1 << kIOI2CSimpleTransactionType) & types != 0 {
                return IOOptionBits(kIOI2CSimpleTransactionType)
            }
        }

        return nil
    }

    private static func send(request: inout IOI2CRequest, to framebuffer: io_service_t, errorRecoveryWaitMicros: UInt32?) -> Bool {
        if let errorRecoveryWaitMicros {
            usleep(errorRecoveryWaitMicros)
        }

        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebuffer, &busCount) == KERN_SUCCESS else {
            return false
        }

        for bus in 0..<busCount {
            var interface = io_service_t()
            guard IOFBCopyI2CInterfaceForBus(framebuffer, IOOptionBits(bus), &interface) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(interface) }

            var connect: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(interface, IOOptionBits(), &connect) == KERN_SUCCESS else {
                continue
            }
            defer { IOI2CInterfaceClose(connect, IOOptionBits()) }

            guard IOI2CSendRequest(connect, IOOptionBits(), &request) == KERN_SUCCESS,
                  request.result == KERN_SUCCESS else {
                continue
            }

            return true
        }

        return false
    }

    private static func servicePortUsingDisplayProperties(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(IOFRAMEBUFFER_CONFORMSTO), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let port = IOIteratorNext(iterator)
            guard port != IO_OBJECT_NULL else { break }

            let dict = IODisplayCreateInfoDictionary(port, IOOptionBits(kIODisplayOnlyPreferredName)).takeRetainedValue() as NSDictionary
            let valueForKey: (String) -> UInt32 = { key in
                (dict[key] as? CFIndex)
                    .flatMap { Int32(exactly: $0) }
                    .map { UInt32(bitPattern: $0) } ?? 0
            }

            guard valueForKey(kDisplayVendorID) == CGDisplayVendorNumber(displayID),
                  valueForKey(kDisplayProductID) == CGDisplayModelNumber(displayID),
                  valueForKey(kDisplaySerialNumber) == CGDisplaySerialNumber(displayID) else {
                IOObjectRelease(port)
                continue
            }

            var busCount: IOItemCount = 0
            guard IOFBGetI2CInterfaceCount(port, &busCount) == KERN_SUCCESS, busCount >= 1 else {
                IOObjectRelease(port)
                continue
            }

            return port
        }

        return nil
    }

    private static func ioFramebufferPort(displayID: CGDirectDisplayID) -> io_service_t? {
        guard CGDisplayIsBuiltin(displayID) == 0 else {
            return nil
        }

        var serviceFromCGS = io_service_t()
        CGSServiceForDisplayNumber(displayID, &serviceFromCGS)
        if serviceFromCGS != IO_OBJECT_NULL {
            return serviceFromCGS
        }

        return servicePortUsingDisplayProperties(displayID: displayID)
    }
}
