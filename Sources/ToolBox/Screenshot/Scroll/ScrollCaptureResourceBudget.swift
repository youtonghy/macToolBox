import Foundation

struct ScrollCaptureResourceBudget: Equatable, Sendable {
    static let defaultMaximumHeight = 60_000
    static let defaultMaximumRGBABytes = 512 * 1_024 * 1_024

    let maximumHeight: Int
    let maximumRGBABytes: Int

    init(
        maximumHeight: Int = defaultMaximumHeight,
        maximumRGBABytes: Int = defaultMaximumRGBABytes
    ) {
        self.maximumHeight = max(1, maximumHeight)
        self.maximumRGBABytes = max(4, maximumRGBABytes)
    }

    func validateAppend(
        width: Int,
        currentHeight: Int,
        additionalRows: Int
    ) throws -> ScrollCaptureResourceUsage {
        guard width > 0, currentHeight >= 0, additionalRows > 0 else {
            throw ScrollCaptureError.invalidStrip
        }
        let heightResult = currentHeight.addingReportingOverflow(additionalRows)
        guard !heightResult.overflow, heightResult.partialValue <= maximumHeight else {
            throw ScrollCaptureError.resourceLimitReached
        }
        let rowResult = width.multipliedReportingOverflow(by: 4)
        guard !rowResult.overflow else { throw ScrollCaptureError.resourceLimitReached }
        let byteResult = rowResult.partialValue.multipliedReportingOverflow(by: heightResult.partialValue)
        guard !byteResult.overflow, byteResult.partialValue <= maximumRGBABytes else {
            throw ScrollCaptureError.resourceLimitReached
        }
        return ScrollCaptureResourceUsage(
            width: width,
            height: heightResult.partialValue,
            rgbaBytes: byteResult.partialValue
        )
    }
}

struct ScrollCaptureResourceUsage: Equatable, Sendable {
    let width: Int
    let height: Int
    let rgbaBytes: Int
}
