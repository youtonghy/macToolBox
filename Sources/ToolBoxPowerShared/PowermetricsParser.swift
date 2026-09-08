import Foundation

// The system tool's text output is line-buffered. A report is committed only when
// its final combined-power line arrives; a partial report never becomes a zero.
struct PowermetricsParser {
    private var pending = Data()
    private var interval: TimeInterval?
    private var cpu: Double?
    private var gpu: Double?
    private var ane: Double?

    mutating func append(_ data: Data, now: Date = Date()) -> [AuthorizedPowerReading] {
        pending.append(data)
        guard pending.count <= 256 * 1_024 else {
            self = Self()
            return []
        }
        var readings: [AuthorizedPowerReading] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...newline)
            if line.hasPrefix("*** Sampled system activity") {
                interval = Self.interval(from: line)
                cpu = nil
                gpu = nil
                ane = nil
            } else if line.hasPrefix("CPU Power:") {
                cpu = Self.watts(from: line, prefix: "CPU Power:")
            } else if line.hasPrefix("GPU Power:") {
                gpu = Self.watts(from: line, prefix: "GPU Power:")
            } else if line.hasPrefix("ANE Power:") {
                ane = Self.watts(from: line, prefix: "ANE Power:")
            } else if line.hasPrefix("Combined Power (CPU + GPU + ANE):") {
                if let interval, let cpu {
                    readings.append(AuthorizedPowerReading(
                        timestamp: now, interval: interval, cpuWatts: cpu,
                        gpuWatts: gpu, aneWatts: ane,
                        combinedWatts: Self.watts(from: line, prefix: "Combined Power (CPU + GPU + ANE):")
                    ))
                }
                interval = nil
            }
        }
        return readings
    }

    private static func watts(from line: String, prefix: String) -> Double? {
        let components = line.dropFirst(prefix.count).split(whereSeparator: \.isWhitespace)
        guard components.count == 2, components[1] == "mW",
              let value = Double(components[0]), value.isFinite, value >= 0 else { return nil }
        return value / 1_000
    }

    private static func interval(from line: String) -> TimeInterval? {
        guard let start = line.lastIndex(of: "("),
              let end = line.range(of: "ms elapsed)", range: start..<line.endIndex),
              let milliseconds = Double(line[line.index(after: start)..<end.lowerBound]),
              milliseconds.isFinite, milliseconds > 0 else { return nil }
        return milliseconds / 1_000
    }
}
