import CoreGraphics
import Foundation

struct DisplayControlValueKey: Hashable, Sendable {
    var displayID: CGDirectDisplayID
    var kind: DisplayControlKind
}

struct DisplayControlValueStore {
    private var values: [DisplayControlValueKey: DisplayControlValue] = [:]
    private var lastSuccessfulRawValues: [DisplayControlValueKey: UInt16] = [:]

    func value(for key: DisplayControlValueKey) -> DisplayControlValue {
        values[key] ?? Self.fallbackValue(kind: key.kind)
    }

    mutating func recordObserved(_ value: DisplayControlValue, for key: DisplayControlValueKey) {
        values[key] = value
        if lastSuccessfulRawValues[key] != value.rawCurrent {
            lastSuccessfulRawValues[key] = nil
        }
    }

    mutating func capability(
        for key: DisplayControlValueKey,
        observedValue: DisplayControlValue?
    ) -> DisplayControlCapability {
        if let observedValue {
            recordObserved(observedValue, for: key)
            return DisplayControlCapability(
                kind: key.kind,
                status: .available,
                value: observedValue,
                unavailableReason: nil
            )
        }

        return DisplayControlCapability(
            kind: key.kind,
            status: .writeOnly,
            value: value(for: key),
            unavailableReason: "Current value unavailable; DDC writes remain enabled."
        )
    }

    func rawValue(for key: DisplayControlValueKey, normalized: Double) throws -> UInt16 {
        guard normalized.isFinite, (0...1).contains(normalized) else {
            throw DisplayControlError.invalidValue(normalized)
        }
        if key.kind == .mute {
            return normalized >= 0.5 ? 1 : 2
        }

        let current = value(for: key)
        guard current.rawMaximum > current.rawMinimum else {
            throw DisplayControlError.invalidRange(
                minimum: current.rawMinimum,
                maximum: current.rawMaximum
            )
        }
        let span = Double(current.rawMaximum - current.rawMinimum)
        let raw = Double(current.rawMinimum) + span * normalized
        return UInt16(min(max(raw.rounded(), Double(current.rawMinimum)), Double(current.rawMaximum)))
    }

    func shouldWrite(
        _ rawValue: UInt16,
        for key: DisplayControlValueKey,
        force: Bool = false
    ) -> Bool {
        if force { return true }
        return lastSuccessfulRawValues[key] != rawValue
    }

    mutating func recordSuccessfulWrite(
        _ rawValue: UInt16,
        normalized: Double,
        for key: DisplayControlValueKey
    ) {
        var value = value(for: key)
        value.timestamp = Date()
        value.rawCurrent = rawValue
        value.normalized = normalized
        values[key] = value
        lastSuccessfulRawValues[key] = rawValue
    }

    mutating func retainDisplays(_ displayIDs: Set<CGDirectDisplayID>) {
        values = values.filter { displayIDs.contains($0.key.displayID) }
        lastSuccessfulRawValues = lastSuccessfulRawValues.filter {
            displayIDs.contains($0.key.displayID)
        }
    }

    private static func fallbackValue(kind: DisplayControlKind) -> DisplayControlValue {
        let current: UInt16
        let maximum: UInt16
        switch kind {
        case .brightness:
            current = 100
            maximum = 100
        case .contrast:
            current = 75
            maximum = 100
        case .volume:
            current = 12
            maximum = 100
        case .mute:
            current = 2
            maximum = 2
        }

        return DisplayControlValue(
            kind: kind,
            timestamp: Date(),
            rawCurrent: current,
            rawMinimum: 0,
            rawMaximum: maximum,
            normalized: kind == .mute ? 0 : Double(current) / Double(maximum)
        )
    }
}
