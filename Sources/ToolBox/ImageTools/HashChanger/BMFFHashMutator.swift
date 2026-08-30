import Foundation

/// HEIC / AVIF（ISO 基础媒体格式）换 Hash：
/// 在文件**尾部**追加 free box，剥离此前注入的尾部 free box。
///
/// 重要：HEIC/AVIF 的 iloc 条目使用绝对文件偏移指向 mdat，
/// 在文件中部（如 ftyp 后）插入任何字节都会使全部媒体数据偏移
/// 失效、解码出错；因此注入位置必须是文件末尾——这也是 fMP4
/// 写入器做尾部对齐的标准做法。free/skip box 是规范定义的
/// 占位盒，解析器必须跳过。
enum BMFFHashMutator {
    enum Error: Swift.Error, CustomStringConvertible {
        case malformed(String)

        var description: String {
            switch self {
            case let .malformed(detail): return "容器结构异常：\(detail)"
            }
        }
    }

    private static let free = Data("free".utf8)

    static func mutate(_ data: Data, payload: Data) throws -> Data {
        guard data.count >= 8 else { throw Error.malformed("文件过短。") }

        // 1) 剥离此前追加的尾部 free box（可能因 mdat size==0 被吞并，
        //    因此按标记反查而不是按盒遍历）。
        var base = data
        while let boxStart = findInjectedFreeBoxStart(in: base) {
            base = base[..<boxStart]
        }

        // 2) 遍历验证盒结构（异常结构直接报错，不做无把握修改）。
        var index = base.startIndex
        while index + 8 <= base.endIndex {
            var headerSize = 8
            var boxSize = Int(readUInt32BE(base, at: index))
            if boxSize == 1 {
                // 64 位大盒：size==1 时真实长度在 largesize 字段。
                guard index + 16 <= base.endIndex else { throw Error.malformed("largesize 越界。") }
                boxSize = Int(readUInt64BE(base, at: index + 8))
                headerSize = 16
            } else if boxSize == 0 {
                // size==0：盒子延伸到文件末尾。
                boxSize = base.endIndex - index
            }
            guard boxSize >= headerSize, index + boxSize <= base.endIndex else {
                throw Error.malformed("box 长度越界。")
            }
            index += boxSize
        }
        if index != base.endIndex {
            throw Error.malformed("尾部残留不完整盒头。")
        }

        // 3) 尾部追加新 free box。
        var output = Data(base)
        var sizeBE = UInt32(payload.count + 8).bigEndian
        withUnsafeBytes(of: &sizeBE) { output.append(contentsOf: $0) }
        output.append(free)
        output.append(payload)
        return output
    }

    /// 在文件尾部查找"我们注入的 free box"的起始偏移；
    /// 校验 fourcc 与长度字段自洽，避免误伤用户数据。
    private static func findInjectedFreeBoxStart(in data: Data) -> Data.Index? {
        guard let markerRange = data.lastRange(of: ImageHashChanger.injectionMarker),
              markerRange.lowerBound >= 12,
              markerRange.lowerBound - 4 + 4 <= data.endIndex
        else { return nil }
        let typeStart = markerRange.lowerBound - 4
        guard data[typeStart ..< markerRange.lowerBound] == free else { return nil }
        let boxStart = typeStart - 4
        let declaredSize = Int(readUInt32BE(data, at: boxStart))
        guard declaredSize == markerRange.upperBound - boxStart else { return nil }
        return boxStart
    }

    private static func readUInt32BE(_ data: Data, at index: Data.Index) -> UInt32 {
        UInt32(data[index]) << 24 | UInt32(data[index + 1]) << 16
            | UInt32(data[index + 2]) << 8 | UInt32(data[index + 3])
    }

    private static func readUInt64BE(_ data: Data, at index: Data.Index) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0 ..< 8 {
            value = value << 8 | UInt64(data[index + offset])
        }
        return value
    }
}
