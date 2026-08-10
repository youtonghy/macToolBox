import Foundation

/// Reference color-preset name table reverse-engineered from Dell Display
/// Peripheral Manager (DDPM) v2.2.0.0024 and verified again against the
/// installed app binary with IDA Pro.
///
/// Source (IDA Pro, universal arm64/x86_64 binary `DDPM`):
///   - `-[AMControl init_ColorPresetDictionary]`  → base value→name table
///   - `-[AMControl updateColorPresetDict:]`      → model-family overrides
///
/// DDPM maps the value reported in the capability string's `E2(...)` (Dell
/// vendor code) or `14(...)` (MCCS standard) section to a human-readable
/// preset name, and rewrites several names per model family (UP-series,
/// U2723QE-family, etc.). macToolBox follows the same generic discovery
/// behavior: every advertised value becomes a preset option, names come from
/// this table, and values without a known mapping are shown as `Preset 0xXX`.
///
/// The write path is also DDPM-compatible: presets are read/written through
/// VCP `0xE2` on Dell displays (with `0x14` as the MCCS fallback for other
/// vendors) and verified by readback.
struct DisplayColorPresetWriteCommand: Equatable, Sendable {
    var vcp: UInt8
    var value: UInt8
}

enum DisplayColorPresetDDPMTable {
    /// DDPM model families observed in `updateColorPresetDict:`, matched by
    /// substring against the monitor model name (as DDPM matches it against
    /// the capability string / product name).
    enum ModelFamily: Equatable, Sendable {
        case standard
        /// Capability string contains "UP" or the model is "U3226Q".
        case upSeries
        /// Model is "UP32" or "U3226Q".
        case up32
        /// Model is "UP27".
        case up27
        /// U2723QE / U3223QE / U3023E / U2723QX / U3223QZ family.
        case u2723qeFamily
    }

    static func family(forModelName modelName: String?) -> ModelFamily {
        guard let name = modelName?.uppercased() else { return .standard }
        if name.contains("U2723QE") || name.contains("U3223QE") || name.contains("U3023E")
            || name.contains("U2723QX") || name.contains("U3223QZ") {
            return .u2723qeFamily
        }
        if name.contains("UP32") || name.contains("U3226Q") {
            return .up32
        }
        if name.contains("UP27") {
            return .up27
        }
        if name.contains("UP") || name.contains("U3226Q") {
            return .upSeries
        }
        return .standard
    }

    /// Preset names for a display family. `modelYear` is used for the
    /// standard family's Rec.709 naming (DDPM `-[AMControl GetModelFY:]`:
    /// year 24 → "Rec. 709/BT.709", year ≥ 25 → "BT.709").
    static func names(
        modelName: String?,
        modelYear: Int? = nil
    ) -> [UInt8: String] {
        var table = baseTable
        let family = family(forModelName: modelName)

        switch family {
        case .upSeries, .up32, .up27:
            table[0x00] = "Native"
        case .standard, .u2723qeFamily:
            break
        }

        switch family {
        case .up32:
            table[0x2A] = "Adobe RGB D65 G2.2 L160"
            table[0x2B] = "Adobe RGB D50 G2.2 L160"
            table[0x0B] = "sRGB D65 sRGB L120"
            table[0x41] = "HDR Preview"
            table[0x2C] = "User 1"
            table[0x2D] = "User 2"
            table[0x2E] = "User 3"
            table[0x1A] = "BT.709 D65 BT.1886 L100"
            table[0x1C] = "BT.2020 D65 BT.1886 L100"
            table[0x3D] = "Display-P3 D65 aRGB L120"
            table[0x16] = "CAL 3"
            table[0x3A] = "DisplayHDR TrueBlack 500"
        case .up27:
            table[0x2A] = "Adobe RGB D65 G2.2 L250"
            table[0x2B] = "Adobe RGB D50 G2.2 L250"
            table[0x0B] = "sRGB D65 sRGB L250"
            table[0x2C] = "Custom 1"
            table[0x2D] = "Custom 2"
            table[0x2E] = "Custom 3"
            table[0x1A] = "BT.709 D65 BT1886 L100"
            table[0x1C] = "BT.2020 D65 BT1886 L100"
        case .standard, .u2723qeFamily:
            table[0x2A] = "AdobeRGB1"
            table[0x2B] = "AdobeRGB2"
            table[0x0B] = "sRGB"
            table[0x2C] = "Custom 1"
            table[0x2D] = "Custom 2"
            table[0x2E] = "Custom 3"
            if let modelYear {
                if modelYear == 24 {
                    table[0x1A] = "Rec. 709/BT.709"
                } else if modelYear >= 25 {
                    table[0x1A] = "BT.709"
                }
            } else {
                table[0x1A] = "Rec. 709"
            }
        case .upSeries:
            break
        }

        if family == .upSeries || family == .up32 || family == .up27 {
            table[0x1B] = "DCI P3 D65 G2.4 L100"
        }

        if family == .u2723qeFamily {
            table[0x3A] = "Display HDR"
        }

        return table
    }

    static func name(
        for value: UInt8,
        modelName: String?,
        modelYear: Int? = nil
    ) -> String? {
        names(modelName: modelName, modelYear: modelYear)[value]
    }

    /// Model year derived the same way DDPM does in `-[AMControl GetModelFY:]`:
    /// take the first run of digits from the model name, then read the two
    /// characters at offset 2 (e.g. `U2723QE` → `23`).
    static func modelYear(from modelName: String?) -> Int? {
        guard let modelName else { return nil }
        guard let firstDigit = modelName.firstIndex(where: \.isNumber) else {
            return nil
        }
        let digitRun = modelName[firstDigit...].prefix(while: \.isNumber)
        guard digitRun.count >= 4 else { return nil }
        let start = digitRun.index(digitRun.startIndex, offsetBy: 2)
        let end = digitRun.index(start, offsetBy: 2)
        return Int(digitRun[start..<end])
    }

    /// One displayable preset option for a raw value. Known values get the
    /// DDPM name; unknown advertised values stay writable and are labelled
    /// `Preset 0xXX` so capability data is never hidden.
    static func option(
        for rawValue: UInt8,
        modelName: String?,
        modelYear: Int? = nil
    ) -> DisplayColorPresetOption {
        DisplayColorPresetOption(
            rawValue: rawValue,
            name: name(for: rawValue, modelName: modelName, modelYear: modelYear)
                ?? String(format: "Preset 0x%02X", rawValue)
        )
    }

    /// DDPM-compatible generic discovery: every advertised value becomes an
    /// option, sorted by raw value for a stable UI.
    static func options(
        for advertisedValues: Set<UInt8>,
        modelName: String?,
        modelYear: Int? = nil
    ) -> [DisplayColorPresetOption] {
        advertisedValues.sorted().map {
            option(for: $0, modelName: modelName, modelYear: modelYear)
        }
    }

    /// The actual Set VCP command DDPM resolves for a preset name from
    /// `-[AMControl init_AMDictionary]` (`AMInfoDict`/`AMInfoDict_English`).
    /// Dell models advertise the E2 preset subset, but writes are routed to
    /// per-preset VCPs such as 0x14, 0xDC, or 0xF0 with that feature's own
    /// value encoding (e.g. U2723QE sRGB → `14 01`, DCI-P3 → `F0 0A`).
    static func writeCommand(forName name: String?) -> DisplayColorPresetWriteCommand? {
        guard let name else { return nil }
        switch name {
        case "Standard", "Native": return .init(vcp: 0xDC, value: 0x00)
        case "Multimedia": return .init(vcp: 0xDC, value: 0x02)
        case "Movie": return .init(vcp: 0xDC, value: 0x03)
        case "Nature": return .init(vcp: 0xDC, value: 0x04)
        case "Game", "Game 1", "Game1": return .init(vcp: 0xDC, value: 0x05)
        case "Sport": return .init(vcp: 0xDC, value: 0x06)
        case "sRGB", "sRGB D65 sRGB L120", "sRGB D65 sRGB L250": return .init(vcp: 0x14, value: 0x01)
        case "5000k": return .init(vcp: 0x14, value: 0x04)
        case "5700k", "Warm": return .init(vcp: 0x14, value: 0x0B)
        case "6500k": return .init(vcp: 0x14, value: 0x05)
        case "7500k": return .init(vcp: 0x14, value: 0x06)
        case "9300k", "Cool": return .init(vcp: 0x14, value: 0x08)
        case "10000k": return .init(vcp: 0x14, value: 0x09)
        case "Custom Color", "Custom": return .init(vcp: 0x14, value: 0x0C)
        case "Text": return .init(vcp: 0xF0, value: 0x01)
        case "AdobeRGB": return .init(vcp: 0xF0, value: 0x02)
        case "xvMode": return .init(vcp: 0xF0, value: 0x03)
        case "DICOM": return .init(vcp: 0xF0, value: 0x04)
        case "CAL 1", "CAL1": return .init(vcp: 0xF0, value: 0x05)
        case "CAL 2", "CAL2": return .init(vcp: 0xF0, value: 0x06)
        case "Paper": return .init(vcp: 0xF0, value: 0x08)
        case "Rec. 709", "Rec.709", "Rec709", "Rec. 709/BT.709", "Rec.709/BT.709", "BT.709", "BT709", "BT.709 D65 BT.1886 L100", "BT.709 D65 BT1886 L100": return .init(vcp: 0xF0, value: 0x09)
        case "DCI-P3", "DCI P3 D65 G2.4 L100", "DCI P3 D63 G2.4 L100": return .init(vcp: 0xF0, value: 0x0A)
        case "Rec2020", "Rec.2020", "Rec. 2020/BT.2020", "Rec.2020/BT.2020", "BT.2020", "BT2020", "BT.2020 D65 BT.1886 L100", "BT.2020 D65 BT1886 L100": return .init(vcp: 0xF0, value: 0x0B)
        case "ComfortView": return .init(vcp: 0xF0, value: 0x0C)
        case "Game 2", "Game2": return .init(vcp: 0xF0, value: 0x0D)
        case "Game 3", "Game3": return .init(vcp: 0xF0, value: 0x0E)
        case "FPS Game": return .init(vcp: 0xF0, value: 0x0F)
        case "RTS Game": return .init(vcp: 0xF0, value: 0x10)
        case "RPG Game": return .init(vcp: 0xF0, value: 0x11)
        case "Multiscreen Match", "MultiscreenMatch": return .init(vcp: 0xF0, value: 0x12)
        case "SPORTS Game": return .init(vcp: 0xF0, value: 0x13)
        case "CAL 3", "CAL3": return .init(vcp: 0xF0, value: 0x16)
        case "AdobeRGB1", "Adobe RGB1 D65G2.2L250", "Adobe RGB D65 G2.2 L160", "Adobe RGB D65 G2.2 L250": return .init(vcp: 0xF0, value: 0x21)
        case "AdobeRGB2", "Adobe RGB2 D50G2.2L250", "Adobe RGB D50 G2.2 L160", "Adobe RGB D50 G2.2 L250": return .init(vcp: 0xF0, value: 0x22)
        case "Standard HDR", "StandardHDR": return .init(vcp: 0xF0, value: 0x30)
        case "Movie HDR", "MovieHDR": return .init(vcp: 0xF0, value: 0x31)
        case "Game HDR", "GameHDR": return .init(vcp: 0xF0, value: 0x32)
        case "Vivid HDR", "VividHDR": return .init(vcp: 0xF0, value: 0x33)
        case "Desktop": return .init(vcp: 0xF0, value: 0x34)
        case "Reference": return .init(vcp: 0xF0, value: 0x35)
        case "DisplayHDR", "DisplayHDR 400", "Display HDR", "DisplayHDR TrueBlack 500": return .init(vcp: 0xF0, value: 0x36)
        case "HDR10 D65 ST2084 L1000", "HDR10": return .init(vcp: 0xF0, value: 0x37)
        case "HDR D65 HLG L1000", "HLG": return .init(vcp: 0xF0, value: 0x38)
        case "Custom Color HDR": return .init(vcp: 0xF0, value: 0x39)
        case "HDR Peak 1000": return .init(vcp: 0xF0, value: 0x3A)
        case "Bright": return .init(vcp: 0xF0, value: 0x3D)
        case "Dark": return .init(vcp: 0xF0, value: 0x3E)
        case "HDR Preview": return .init(vcp: 0xF0, value: 0x41)
        case "Display P3", "DisplayP3", "Display P3 D65 sRGB L120", "Display-P3 D65 aRGB L120": return .init(vcp: 0xF0, value: 0xA1)
        case "Custom 1", "Custom1", "User 1", "User1": return .init(vcp: 0xF0, value: 0xC1)
        case "Custom 2", "Custom2", "User 2", "User2": return .init(vcp: 0xF0, value: 0xC2)
        case "Custom 3", "Custom3", "User 3", "User3": return .init(vcp: 0xF0, value: 0xC3)
        default: return nil
        }
    }

    /// The base value→name table from
    /// `-[AMControl init_ColorPresetDictionary]` (localized English forms of
    /// the `localizedStringForKey:value:table:` lookups).
    private static let baseTable: [UInt8: String] = [
        0x00: "Standard",
        0x01: "Multimedia",
        0x02: "Movie",
        0x03: "Nature",
        0x04: "Game 1",
        0x05: "Sport",
        0x06: "Text",
        0x07: "AdobeRGB",
        0x2A: "Adobe RGB1 D65 G2.2L250",
        0x2B: "Adobe RGB2 D50 G2.2L250",
        0x08: "xvMode",
        0x09: "DICOM",
        0x0A: "CAL 1",
        0xA1: "Display P3",
        0x0B: "sRGB",
        0x0C: "5000k",
        0x0D: "5700k",
        0x0E: "Warm",
        0x0F: "6500k",
        0x10: "7500k",
        0x11: "9300k",
        0x12: "Cool",
        0x13: "10000k",
        0x14: "Custom Color",
        0x2C: "Custom 1",
        0x2D: "Custom 2",
        0x2E: "Custom 3",
        0x15: "CAL 2",
        0x16: "CAL 3",
        0x18: "Metro",
        0x19: "Paper",
        0x1A: "Rec. 709",
        0x1B: "DCI-P3",
        0x1C: "Rec2020",
        0x1D: "ComfortView",
        0x1E: "Game 2",
        0x1F: "Game 3",
        0x20: "FPS Game",
        0x21: "RTS Game",
        0x22: "RPG Game",
        0x2F: "SPORTS Game",
        0x25: "Standard HDR",
        0x23: "Movie HDR",
        0x24: "Game HDR",
        0x26: "Vivid HDR",
        0x27: "Desktop",
        0x28: "Reference",
        0x29: "Multiscreen Match",
        0x3A: "DisplayHDR",
        0x3B: "HDR10 D65 ST2084 L1000",
        0x3C: "HDR D65 HLG L1000",
        0x3D: "Display P3",
        0x30: "Custom Color HDR",
        0x31: "HDR Peak 1000",
        0x7F: "Presets Disabled",
    ]
}
