import Foundation

/// PNG 换 Hash：在 IHDR 后插入 tEXt 块，剥离此前注入的 tEXt。
///
/// tEXt 是 PNG 规范的文本元数据块，解析器仅存储不解释；
/// 插入位置紧跟 IHDR（任何 IDAT 之前），合法且安全。
/// 新块 CRC 由 CRC32(type + data) 重新计算。
enum PNGHashMutator {
    enum Error: Swift.Error, CustomStringConvertible {
        case malformed(String)

        var description: String {
            switch self {
            case let .malformed(detail): return "PNG 结构异常：\(detail)"
            }
        }
    }

    private static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private static let textKeyword = Data("ToolboxHash".utf8)

    static func mutate(_ data: Data, payload: Data) throws -> Data {
        guard data.count > signature.count, data.prefix(signature.count) == signature else {
            throw Error.malformed("缺少 PNG 签名。")
        }

        var output = Data(data.prefix(signature.count))
        var index = data.startIndex + signature.count
        var inserted = false
        var sawIHDR = false

        while index + 8 <= data.endIndex {
            let length = readUInt32BE(data, at: index)
            guard length >= 0, length <= data.endIndex - index - 12 else {
                throw Error.malformed("块长度越界。")
            }
            let typeStart = index + 4
            let dataStart = index + 8
            let dataEnd = dataStart + length
            let chunkEnd = dataEnd + 4
            let type = data[typeStart ..< typeStart + 4]

            let isInjectedText = type == Data("tEXt".utf8)
                && data[dataStart ..< dataEnd].starts(with: textKeyword)
            if !isInjectedText {
                appendChunk(to: &output, type: type, chunkData: data[dataStart ..< dataEnd])
            }

            if type == Data("IHDR".utf8) {
                sawIHDR = true
                if !inserted {
                    appendChunk(
                        to: &output,
                        type: Data("tEXt".utf8),
                        chunkData: textKeyword + Data([0x00]) + payload
                    )
                    inserted = true
                }
            }

            index = chunkEnd
            if type == Data("IEND".utf8) { break }
        }
        guard sawIHDR else { throw Error.malformed("缺少 IHDR 块。") }
        // IEND 之后的尾部数据（正常不存在）原样保留。
        if index < data.endIndex { output.append(contentsOf: data[index...]) }
        return output
    }

    private static func appendChunk(to output: inout Data, type: Data, chunkData: Data) {
        var length = UInt32(chunkData.count).bigEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        output.append(type)
        output.append(chunkData)
        var crc = CRC32.checksum(type + chunkData).bigEndian
        withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
    }

    private static func readUInt32BE(_ data: Data, at index: Data.Index) -> Int {
        Int(data[index]) << 24 | Int(data[index + 1]) << 16
            | Int(data[index + 2]) << 8 | Int(data[index + 3])
    }
}
