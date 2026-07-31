import Foundation

struct StableContentMask: Equatable, Sendable {
    let ignoredRows: Set<Int>

    static let empty = StableContentMask(ignoredRows: [])

    func includes(row: Int) -> Bool {
        !ignoredRows.contains(row)
    }

    static func detectPersistentRows(
        previous: LumaFrame,
        current: LumaFrame,
        threshold: Double
    ) throws -> StableContentMask {
        guard previous.width == current.width, previous.height == current.height else {
            throw ScrollCaptureError.frameDimensionsChanged
        }
        var ignoredRows = Set<Int>()
        for y in 0..<previous.height {
            var rowDifference = 0
            for x in 0..<previous.width {
                rowDifference += abs(Int(previous[x, y]) - Int(current[x, y]))
            }
            if Double(rowDifference) / Double(previous.width) <= threshold {
                ignoredRows.insert(y)
            }
        }
        return StableContentMask(ignoredRows: ignoredRows)
    }
}
