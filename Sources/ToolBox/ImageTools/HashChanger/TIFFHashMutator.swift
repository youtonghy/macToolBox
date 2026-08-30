import Foundation

/// TIFF 换 Hash：在文件尾部追加标记注释行，剥离上次追加的内容。
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
    /// 追加行的结尾换行，便于按行剥离。
    private static let terminator = Data("\n".utf8)

    static func mutate(_ data: Data, payload: Data) throws -> Data {
        guard data.count >= 8,
              data.prefix(4) == littleEndianHeader || data.prefix(4) == bigEndianHeader
        else {
            throw Error.malformed("缺少 TIFF 头。")
        }

        var base = data
        // 剥离上次追加的注释行：查找最后一个标记出现点，截断其后内容。
        if let markerRange = base.lastRange(of: ImageHashChanger.injectionMarker) {
            base = base[..<markerRange.lowerBound]
        }

        var output = Data(base)
        output.append(ImageHashChanger.injectionMarker)
        output.append(payload)
        output.append(terminator)
        return output
    }
}
