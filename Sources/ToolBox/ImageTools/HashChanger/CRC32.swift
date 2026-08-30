import Foundation

/// PNG/RIFF 块校验用的 CRC32（IEEE 802.3，即 PNG 规范要求的算法）。
enum CRC32 {
    private static let table: [UInt32] = {
        (0 ..< 256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0 ..< 8 {
                value = (value & 1 == 1) ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    static func checksum(bytes: [UInt8]) -> UInt32 {
        checksum(Data(bytes))
    }
}

extension Data {
    /// 最后一次出现 data 的字节区间（朴素匹配；注入标记短，性能足够）。
    internal func lastRange(of data: Data) -> Range<Data.Index>? {
        guard !data.isEmpty, count >= data.count else { return nil }
        var searchEnd = endIndex
        while searchEnd >= startIndex + data.count {
            let range = (searchEnd - data.count) ..< searchEnd
            if self[range] == data {
                return range
            }
            searchEnd -= 1
        }
        return nil
    }
}
