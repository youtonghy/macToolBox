import Foundation
import IOKit

final class SMCSystemPowerReader {
    private var connection: io_connect_t = 0

    init() {
        assert(
            MemoryLayout<SMCParamStruct>.stride == 80,
            "SMCParamStruct must be 80 bytes, got \(MemoryLayout<SMCParamStruct>.stride)"
        )
    }

    deinit {
        close()
    }

    func readSystemWatts() -> Double? {
        guard open() else {
            return nil
        }

        if let pstr = readFloat("PSTR") {
            return Double(pstr)
        }
        if let pdtr = readFloat("PDTR") {
            return Double(pdtr)
        }
        if let volts = readFloat("VD0R"), let amps = readFloat("ID0R") {
            return Double(volts * amps)
        }
        return nil
    }

    @discardableResult
    private func open() -> Bool {
        if connection != 0 {
            return true
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            return false
        }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else {
            return false
        }
        connection = conn
        return true
    }

    private func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    private func readFloat(_ key: String) -> Float? {
        guard let bytes = readKey(key), bytes.count >= 4 else {
            return nil
        }
        let bits = UInt32(bytes[0])
            | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
        let value = Float(bitPattern: bits)
        return value.isFinite ? value : nil
    }

    private func readKey(_ key: String) -> [UInt8]? {
        guard let fourCC = Self.fourCC(key) else {
            return nil
        }

        var info = SMCParamStruct()
        info.key = fourCC
        info.data8 = Self.commandGetKeyInfo
        guard let infoOutput = callDriver(&info), infoOutput.result == 0 else {
            return nil
        }
        let size = infoOutput.keyInfo.dataSize
        guard size > 0 else {
            return nil
        }

        var read = SMCParamStruct()
        read.key = fourCC
        read.keyInfo.dataSize = size
        read.keyInfo.dataType = infoOutput.keyInfo.dataType
        read.data8 = Self.commandReadKey
        guard let readOutput = callDriver(&read), readOutput.result == 0 else {
            return nil
        }

        let count = Int(min(size, 32))
        var value = readOutput.bytes
        return withUnsafeBytes(of: &value) { Array($0.prefix(count)) }
    }

    private func callDriver(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        guard connection != 0 else {
            return nil
        }

        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            Self.kernelIndex,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )

        return result == KERN_SUCCESS ? output : nil
    }

    private static func fourCC(_ key: String) -> UInt32? {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count == 4 else {
            return nil
        }

        var result: UInt32 = 0
        for scalar in scalars {
            guard scalar.value <= 0xff else {
                return nil
            }
            result = (result << 8) | UInt32(scalar.value)
        }
        return result
    }

    private static let kernelIndex: UInt32 = 2
    private static let commandReadKey: UInt8 = 5
    private static let commandGetKeyInfo: UInt8 = 9
}

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimit = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}
