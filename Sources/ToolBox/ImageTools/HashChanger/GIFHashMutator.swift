import Foundation

/// GIF 换 Hash：在 Trailer(0x3B) 前插入 Comment Extension(21 FE)，
/// 剥离此前注入的 Comment Extension。
///
/// Comment Extension 是 GIF 规范定义的注释块，解码器跳过其内容。
enum GIFHashMutator {
    enum Error: Swift.Error, CustomStringConvertible {
        case malformed(String)

        var description: String {
            switch self {
            case let .malformed(detail): return "GIF 结构异常：\(detail)"
            }
        }
    }

    static func mutate(_ data: Data, payload: Data) throws -> Data {
        guard data.count >= 14,
              data.prefix(4) == Data("GIF8".utf8)
        else {
            throw Error.malformed("缺少 GIF 头。")
        }

        var index = data.startIndex
        let header = data.startIndex + 6 // GIF87a/GIF89a
        var cursor = header
        // 逻辑屏幕描述符 7 字节。
        guard cursor + 7 <= data.endIndex else { throw Error.malformed("逻辑屏幕描述符不完整。") }
        let packed = data[cursor + 4]
        cursor += 7
        if packed & 0x80 != 0 {
            // 全局颜色表：3 × 2^((packed&7)+1) 字节。
            let gctSize = 3 * (1 << (Int(packed & 0x07) + 1))
            guard cursor + gctSize <= data.endIndex else { throw Error.malformed("全局颜色表越界。") }
            cursor += gctSize
        }
        index = cursor

        var output = Data(data[..<index])
        var trailerOffset: Data.Index?

        // 块级遍历：记录我们的注释扩展区间，其余原样复制。
        loop: while index < data.endIndex {
            let introducer = data[index]
            switch introducer {
            case 0x3B: // Trailer
                trailerOffset = output.count
                output.append(0x3B)
                index += 1
                break loop
            case 0x21: // Extension
                guard index + 2 <= data.endIndex else { throw Error.malformed("扩展块不完整。") }
                let label = data[index + 1]
                var walk = index + 2
                var extensionData = Data()
                while walk < data.endIndex {
                    let sublen = Int(data[walk])
                    guard walk + 1 + sublen <= data.endIndex else {
                        throw Error.malformed("子块越界。")
                    }
                    if sublen == 0 { walk += 1; break }
                    extensionData.append(contentsOf: data[(walk + 1) ..< (walk + 1 + sublen)])
                    walk += 1 + sublen
                }
                let isInjectedComment = label == 0xFE
                    && extensionData.starts(with: ImageHashChanger.injectionMarker)
                if !isInjectedComment {
                    output.append(contentsOf: data[index ..< walk])
                }
                index = walk
            case 0x2C: // Image Descriptor
                guard index + 10 <= data.endIndex else { throw Error.malformed("图像描述符不完整。") }
                let imagePacked = data[index + 9]
                var walk = index + 10
                if imagePacked & 0x80 != 0 {
                    let lctSize = 3 * (1 << (Int(imagePacked & 0x07) + 1))
                    guard walk + lctSize <= data.endIndex else { throw Error.malformed("局部颜色表越界。") }
                    walk += lctSize
                }
                // LZW 最小码长 1 字节 + 图像数据子块。
                guard walk < data.endIndex else { throw Error.malformed("缺少 LZW 码长。") }
                walk += 1
                while walk < data.endIndex {
                    let sublen = Int(data[walk])
                    guard walk + 1 + sublen <= data.endIndex else { throw Error.malformed("图像数据子块越界。") }
                    if sublen == 0 { walk += 1; break }
                    walk += 1 + sublen
                }
                output.append(contentsOf: data[index ..< walk])
                index = walk
            case 0x00:
                // 部分编码器在 Trailer 前填充 0x00 块：跳过。
                index += 1
            default:
                throw Error.malformed("未知块引导字节 0x\(String(introducer, radix: 16))。")
            }
        }
        if index < data.endIndex { output.append(contentsOf: data[index...]) }

        // 在 Trailer 前插入新 Comment Extension（载荷按 ≤255 字节分块）。
        guard let trailerOffset else {
            throw Error.malformed("缺少 Trailer。")
        }
        var comment = Data([0x21, 0xFE])
        var remaining = payload
        while !remaining.isEmpty {
            let take = min(255, remaining.count)
            comment.append(UInt8(take))
            comment.append(contentsOf: remaining.prefix(take))
            remaining = remaining.dropFirst(take)
        }
        comment.append(0x00) // 块终止符
        output.insert(contentsOf: comment, at: trailerOffset)
        return output
    }
}
