import Foundation

/// TIFF 换 Hash：在文件尾部追加带长度和校验和的载荷，剥离上次追加的内容。
///
/// TIFF 的 IFD 体系不含全局长度字段，读取器在 IFD 链结束时即停止，
/// 尾部多余字节会被忽略（等效于常见软件追加的私有数据做法）。
/// 产物经 CGImageSource 解码校验 + 像素一致性校验兜底。
enum TIFFHashMutator {
    enum Error: Swift.Error, CustomStringConvertible {
        case malformed(String)

        var description: String {
            switch self {
            case let .malformed(detail): return "TIFF 结构异常：\(detail)"
            }
        }
    }

    private static let littleEndianHeader = Data([0x49, 0x49, 0x2A, 0x00])
    private static let bigEndianHeader = Data([0x4D, 0x4D, 0x00, 0x2A])
    // A length/checksum footer permits exact tail removal without searching image bytes.
    private static let footer = Data("TOOLBOX-HASH-END-V2".utf8)

    static func mutate(_ data: Data, payload: Data) throws -> Data {
        guard data.count >= 8,
              data.prefix(4) == littleEndianHeader || data.prefix(4) == bigEndianHeader
        else { throw Error.malformed("缺少 TIFF 头。") }

        var base = data
        if let start = framedTailStart(base) {
            base = Data(base[..<start])
        } else if let start = legacyTailStart(base) {
            base = Data(base[..<start])
        }
        guard let size = UInt32(exactly: payload.count) else { throw Error.malformed("载荷过长。") }
        var output = Data(base)
        output.append(payload)
        for value in [size, CRC32.checksum(payload)] {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { output.append(contentsOf: $0) }
        }
        output.append(footer)
        return output
    }

    private static func framedTailStart(_ data: Data) -> Int? {
        guard data.suffix(footer.count) == footer, data.count >= footer.count + 16 else { return nil }
        let fields = data.count - footer.count - 8
        let length = Int(readUInt32(data, at: fields))
        guard length > 0, length <= fields - 8 else { return nil }
        let start = fields - length
        let body = Data(data[start..<fields])
        guard body.starts(with: ImageHashChanger.injectionMarker),
              CRC32.checksum(body) == readUInt32(data, at: fields + 4) else { return nil }
        return start
    }

    /// V1 always wrote at least two consecutive markers, 24 printable random bytes,
    /// and a newline. Leave anything that does not match that exact tail intact.
    private static func legacyTailStart(_ data: Data) -> Int? {
        let marker = ImageHashChanger.injectionMarker
        guard data.last == 10, data.count >= 8 + marker.count * 2 + 25 else { return nil }
        let randomStart = data.count - 25
        guard data[randomStart..<(data.count - 1)].allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        var start = randomStart
        var count = 0
        while start >= 8 + marker.count, data[(start - marker.count)..<start] == marker {
            start -= marker.count
            count += 1
        }
        return count >= 2 ? start : nil
    }

    private static func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        UInt32(data[index]) << 24 | UInt32(data[index + 1]) << 16
            | UInt32(data[index + 2]) << 8 | UInt32(data[index + 3])
    }
}
