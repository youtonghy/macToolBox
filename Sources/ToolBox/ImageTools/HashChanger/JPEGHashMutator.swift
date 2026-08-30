import Foundation

/// JPEG 换 Hash：在 SOI 后插入 COM（注释）段，剥离此前注入的 COM。
///
/// COM 段是 JPEG 规范定义的注释段，所有解析器都必须跳过其内容；
/// 注入位置紧跟 SOI（任何熵编码数据之前），不会影响像素。
enum JPEGHashMutator {
    enum Error: Swift.Error, CustomStringConvertible {
        case malformed(String)

        var description: String {
            switch self {
            case let .malformed(detail): return "JPEG 结构异常：\(detail)"
            }
        }
    }

    static func mutate(_ data: Data, payload: Data) throws -> Data {
        guard data.count >= 4, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else {
            throw Error.malformed("缺少 SOI 标记。")
        }
        guard payload.count <= 65_533 else {
            throw Error.malformed("注入载荷过长。")
        }

        // 剥离旧的注入 COM 段后原样重组。
        var filtered = Data(data.prefix(2)) // SOI
        var index = data.startIndex + 2
        while index + 4 <= data.endIndex {
            guard data[index] == 0xFF else { break } // 段流结束（异常容错：直接保留剩余）
            let marker = data[index + 1]
            // 无载荷独立标记：TEM(0x01)、RST(0xD0-D7)、EOI(0xD9)
            if marker == 0x01 || marker == 0xD9 || (0xD0 ... 0xD7).contains(marker) {
                filtered.append(data[index])
                filtered.append(data[index + 1])
                index += 2
                continue
            }
            guard index + 4 <= data.endIndex else { break }
            let segmentLength = (Int(data[index + 2]) << 8) | Int(data[index + 3])
            guard segmentLength >= 2, index + 2 + segmentLength <= data.endIndex else {
                throw Error.malformed("段长度越界。")
            }
            let segmentEnd = index + 2 + segmentLength
            let isInjectedComment = marker == 0xFE
                && data[(index + 4) ..< segmentEnd].starts(with: ImageHashChanger.injectionMarker)
            if !isInjectedComment {
                filtered.append(contentsOf: data[index ..< segmentEnd])
            }
            index = segmentEnd
            if marker == 0xDA {
                // SOS 之后是熵编码数据，不能再按段解析；剩余部分原样保留。
                if index < data.endIndex { filtered.append(contentsOf: data[index...]) }
                index = data.endIndex
            }
        }
        if index < data.endIndex { filtered.append(contentsOf: data[index...]) }

        // 在 SOI 后插入新 COM 段：FF FE <len:2 BE = payload+2> payload
        var comment = Data([0xFF, 0xFE])
        let length = payload.count + 2
        comment.append(UInt8((length >> 8) & 0xFF))
        comment.append(UInt8(length & 0xFF))
        comment.append(payload)

        var output = Data()
        output.reserveCapacity(filtered.count + comment.count)
        output.append(filtered.prefix(2))
        output.append(comment)
        output.append(filtered.dropFirst(2))
        return output
    }
}
