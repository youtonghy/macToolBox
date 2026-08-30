import Foundation

/// WebP 换 Hash：在 RIFF 容器尾部追加 JUNK chunk，剥离此前注入的 JUNK。
///
/// RIFF/WebP 规范要求解码器跳过未知 fourcc 的 chunk；
/// 追加后重写 RIFF 头部的容器长度字段。
enum WebPHashMutator {
    enum Error: Swift.Error, CustomStringConvertible {
        case malformed(String)

        var description: String {
            switch self {
            case let .malformed(detail): return "WebP 结构异常：\(detail)"
            }
        }
    }

    private static let riff = Data("RIFF".utf8)
    private static let webp = Data("WEBP".utf8)
    private static let junk = Data("JUNK".utf8)

    static func mutate(_ data: Data, payload: Data) throws -> Data {
        guard data.count >= 12,
              data.prefix(4) == riff,
              data.subdata(in: 8 ..< 12) == webp
        else {
            throw Error.malformed("缺少 RIFF/WEBP 头。")
        }

        var output = Data()
        output.append(riff)
        output.append(contentsOf: [UInt8](repeating: 0, count: 4)) // RIFF size 占位
        output.append(webp)

        var index = data.startIndex + 12
        while index + 8 <= data.endIndex {
            let fourcc = data[index ..< index + 4]
            let chunkSize = Int(readUInt32LE(data, at: index + 4))
            let dataStart = index + 8
            let paddedSize = chunkSize + (chunkSize & 1) // RIFF chunk 按 2 字节对齐
            guard dataStart + paddedSize <= data.endIndex else {
                throw Error.malformed("chunk 长度越界。")
            }
            let chunkData = data[dataStart ..< dataStart + chunkSize]
            let isInjectedJunk = fourcc == junk
                && chunkData.starts(with: ImageHashChanger.injectionMarker)
            if !isInjectedJunk {
                output.append(contentsOf: data[index ..< dataStart + paddedSize])
            }
            index = dataStart + paddedSize
        }
        if index < data.endIndex {
            // 头部之后不足一个 chunk 头的残余字节：原样保留。
            output.append(contentsOf: data[index...])
        }

        // 追加新的 JUNK chunk（按 2 字节对齐填充）。
        output.append(junk)
        var sizeLE = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &sizeLE) { output.append(contentsOf: $0) }
        output.append(payload)
        if payload.count & 1 == 1 { output.append(0) }

        // 重写 RIFF 容器长度。
        let total = UInt32(truncatingIfNeeded: output.count - 8).littleEndian
        let sizeBytes = withUnsafeBytes(of: total) { Array($0) }
        output.replaceSubrange(4 ..< 8, with: sizeBytes)
        return output
    }

    private static func readUInt32LE(_ data: Data, at index: Data.Index) -> UInt32 {
        UInt32(data[index])
            | UInt32(data[index + 1]) << 8
            | UInt32(data[index + 2]) << 16
            | UInt32(data[index + 3]) << 24
    }
}
