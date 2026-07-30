import CoreGraphics
import Foundation

struct DisplayControlValueKey: Hashable, Sendable {
    var displayID: CGDirectDisplayID
    var kind: DisplayControlKind
}

struct DisplayControlValueStore {
    private var values: [DisplayControlValueKey: DisplayControlValue] = [:]
    private var lastSuccessfulRawValues: [DisplayControlValueKey: UInt16] = [:]
    private let brightnessMemory: DisplayBrightnessRemembering

    init(brightnessMemory: DisplayBrightnessRemembering = DisplayBrightnessMemoryStore()) {
        self.brightnessMemory = brightnessMemory
    }

    func value(for key: DisplayControlValueKey) -> DisplayControlValue {
        values[key] ?? Self.fallbackValue(kind: key.kind)
    }

    mutating func recordObserved(
        _ value: DisplayControlValue,
        for key: DisplayControlValueKey,
        identity: DisplayBrightnessMemoryIdentity? = nil
    ) {
        values[key] = value
        if lastSuccessfulRawValues[key] != value.rawCurrent {
            lastSuccessfulRawValues[key] = nil
        }
        if key.kind == .brightness, let identity {
            brightnessMemory.save(value.normalized, for: identity)
        }
    }

    mutating func capability(
        for key: DisplayControlValueKey,
        identity: DisplayBrightnessMemoryIdentity? = nil,
        observedValue: DisplayControlValue?
    ) -> DisplayControlCapability {
        if let observedValue {
            recordObserved(observedValue, for: key, identity: identity)
            return DisplayControlCapability(
                kind: key.kind,
                status: .available,
                value: observedValue,
                unavailableReason: nil
            )
        }

        if key.kind == .brightness,
           let identity,
           let remembered = brightnessMemory.load(for: identity) {
            values[key] = Self.fallbackValue(kind: key.kind, normalized: remembered)
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
        for key: DisplayControlValueKey,
        identity: DisplayBrightnessMemoryIdentity? = nil
    ) {
        var value = value(for: key)
        value.timestamp = Date()
        value.rawCurrent = rawValue
        value.normalized = normalized
        values[key] = value
        lastSuccessfulRawValues[key] = rawValue
        if key.kind == .brightness, let identity {
            brightnessMemory.save(normalized, for: identity)
        }
    }

    mutating func retainDisplays(_ displayIDs: Set<CGDirectDisplayID>) {
        values = values.filter { displayIDs.contains($0.key.displayID) }
        lastSuccessfulRawValues = lastSuccessfulRawValues.filter {
            displayIDs.contains($0.key.displayID)
        }
    }

    mutating func invalidate(
        displayID: CGDirectDisplayID,
        kinds: Set<DisplayControlKind>
    ) {
        values = values.filter {
            $0.key.displayID != displayID || !kinds.contains($0.key.kind)
        }
        lastSuccessfulRawValues = lastSuccessfulRawValues.filter {
            $0.key.displayID != displayID || !kinds.contains($0.key.kind)
        }
    }

    private static func fallbackValue(
        kind: DisplayControlKind,
        normalized rememberedValue: Double? = nil
    ) -> DisplayControlValue {
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

        let normalized = kind == .mute
            ? 0
            : min(max(rememberedValue ?? Double(current) / Double(maximum), 0), 1)
        let rememberedCurrent = UInt16(
            min(max((normalized * Double(maximum)).rounded(), 0), Double(maximum))
        )
        return DisplayControlValue(
            kind: kind,
            timestamp: Date(),
            rawCurrent: rememberedValue == nil ? current : rememberedCurrent,
            rawMinimum: 0,
            rawMaximum: maximum,
            normalized: normalized
        )
    }
}
