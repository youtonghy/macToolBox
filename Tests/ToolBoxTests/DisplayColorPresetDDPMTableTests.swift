import XCTest
@testable import ToolBoxCore

final class DisplayColorPresetCodeTests: XCTestCase {
    func testDellE2TakesPrecedenceOverMCCS14() throws {
        let report = try parse("vcp(10 12 E2(0B 1B 41) 14(0B) 62)")

        XCTAssertEqual(report.resolveColorPresetCode(), .dellE2)
        XCTAssertEqual(report.advertisedValues(for: .dellE2), [0x0B, 0x1B, 0x41])
    }

    func testMCCS14UsedWhenE2Absent() throws {
        let report = try parse("vcp(10 12 14(0B 1B) 62)")

        XCTAssertEqual(report.resolveColorPresetCode(), .mccs14)
        XCTAssertEqual(report.advertisedValues(for: .mccs14), [0x0B, 0x1B])
    }

    func testNotAdvertisedWhenNeitherPresent() throws {
        let report = try parse("vcp(10 12 62)")

        XCTAssertEqual(report.resolveColorPresetCode(), .notAdvertised)
        XCTAssertNil(report.advertisedValues(for: .notAdvertised))
    }

    func testE2WithoutSubsetFallsBackToMCCS14() throws {
        let report = try parse("vcp(10 E2 14(0B))")

        XCTAssertEqual(report.resolveColorPresetCode(), .mccs14)
    }

    func testAdvertisedNoEnumSubsetResolvesToUnavailableState() throws {
        let report = try parse("vcp(10 12 14)")

        XCTAssertEqual(report.resolveColorPresetCode(), .advertisedNoEnumSubset)
        XCTAssertNil(report.advertisedValues(for: .advertisedNoEnumSubset))
    }

    func testRawValues() {
        XCTAssertEqual(DisplayColorPresetCode.dellE2.rawValue, 0xE2)
        XCTAssertEqual(DisplayColorPresetCode.mccs14.rawValue, 0x14)
        XCTAssertNil(DisplayColorPresetCode.advertisedNoEnumSubset.rawValue)
        XCTAssertNil(DisplayColorPresetCode.notAdvertised.rawValue)
        XCTAssertNil(DisplayColorPresetCode.capabilityStringUnavailable.rawValue)
        XCTAssertTrue(DisplayColorPresetCode.dellE2.isAvailable)
        XCTAssertTrue(DisplayColorPresetCode.mccs14.isAvailable)
        XCTAssertFalse(DisplayColorPresetCode.advertisedNoEnumSubset.isAvailable)
        XCTAssertFalse(DisplayColorPresetCode.notAdvertised.isAvailable)
    }

    private func parse(_ raw: String) throws -> DDCCapabilityReport {
        try DDCCapabilityParser.parse(raw).get()
    }
}

final class DisplayColorPresetDDPMTableTests: XCTestCase {
    func testBaseTableEntries() {
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x00, modelName: nil), "Standard")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x0B, modelName: nil), "sRGB")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x1A, modelName: nil), "Rec. 709")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x1B, modelName: nil), "DCI-P3")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x1C, modelName: nil), "Rec2020")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0xA1, modelName: nil), "Display P3")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x1D, modelName: nil), "ComfortView")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x7F, modelName: nil), "Presets Disabled")
        // 0x41 (HDR Preview) exists only on the UP32 family.
        XCTAssertNil(DisplayColorPresetDDPMTable.name(for: 0x41, modelName: nil))
    }

    func testUP32Overrides() {
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x00, modelName: "UP3225"), "Native")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x41, modelName: "UP3225"), "HDR Preview")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x2A, modelName: "UP3225"), "Adobe RGB D65 G2.2 L160")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x0B, modelName: "UP3225"), "sRGB D65 sRGB L120")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x1B, modelName: "UP3225"), "DCI P3 D65 G2.4 L100")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x3A, modelName: "UP3225"), "DisplayHDR TrueBlack 500")
    }

    func testUP27Overrides() {
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x00, modelName: "UP2720"), "Native")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x2A, modelName: "UP2720"), "Adobe RGB D65 G2.2 L250")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x0B, modelName: "UP2720"), "sRGB D65 sRGB L250")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x1B, modelName: "UP2720"), "DCI P3 D65 G2.4 L100")
    }

    func testU3226QIsUP32Family() {
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x00, modelName: "U3226Q"), "Native")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x41, modelName: "U3226Q"), "HDR Preview")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x2A, modelName: "U3226Q"), "Adobe RGB D65 G2.2 L160")
    }

    func testU2723QEFamilyOverridesDisplayHDR() {
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x3A, modelName: "U2723QE"), "Display HDR")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x3A, modelName: "U3223QE"), "Display HDR")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x3A, modelName: "U3023E"), "Display HDR")
    }

    func testStandardFamilyNames() {
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x00, modelName: "U2723QE"), "Standard")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x2A, modelName: "U2723QE"), "AdobeRGB1")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x0B, modelName: "U2723QE"), "sRGB")
    }

    func testStandardRec709NameByModelYear() {
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x1A, modelName: "U2723QE", modelYear: 24), "Rec. 709/BT.709")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x1A, modelName: "U2723QE", modelYear: 25), "BT.709")
        XCTAssertEqual(DisplayColorPresetDDPMTable.name(for: 0x1A, modelName: "U2723QE"), "Rec. 709")
    }

    func testOptionsMapsAllAdvertisedValuesToDDPMNames() {
        let options = DisplayColorPresetDDPMTable.options(
            for: [0x0B, 0x41, 0xFE],
            modelName: "UP3225"
        )

        XCTAssertEqual(options.map(\.rawValue), [0x0B, 0x41, 0xFE])
        XCTAssertEqual(options.map(\.name), [
            "sRGB D65 sRGB L120",
            "HDR Preview",
            "Preset 0xFE",
        ])
    }

    func testUnknownAdvertisedValueFallsBackToPresetHex() {
        let option = DisplayColorPresetDDPMTable.option(
            for: 0xFE,
            modelName: "U2723QE"
        )

        XCTAssertEqual(option.rawValue, 0xFE)
        XCTAssertEqual(option.name, "Preset 0xFE")
    }

    func testOptionsRemainStableWhenModelNameIsUnavailable() {
        let options = DisplayColorPresetDDPMTable.options(
            for: [0x1B, 0x1C],
            modelName: nil
        )

        XCTAssertEqual(options.map(\.rawValue), [0x1B, 0x1C])
        XCTAssertEqual(options.map(\.name), ["DCI-P3", "Rec2020"])
    }

    func testModelYearUsesFirstDigitRunLikeDDPM() {
        XCTAssertEqual(DisplayColorPresetDDPMTable.modelYear(from: "U2723QE"), 23)
        XCTAssertEqual(DisplayColorPresetDDPMTable.modelYear(from: "Dell U2723QE"), 23)
        XCTAssertEqual(DisplayColorPresetDDPMTable.modelYear(from: "P2425E"), 25)
        XCTAssertEqual(DisplayColorPresetDDPMTable.modelYear(from: "UP3225"), 25)
        XCTAssertNil(DisplayColorPresetDDPMTable.modelYear(from: "Display 77"))
        XCTAssertNil(DisplayColorPresetDDPMTable.modelYear(from: "DELL 27 U2723QE"))
        XCTAssertNil(DisplayColorPresetDDPMTable.modelYear(from: nil))
    }

    func testDDPMWriteCommandMapping() {
        XCTAssertEqual(
            DisplayColorPresetDDPMTable.writeCommand(forName: "sRGB"),
            DisplayColorPresetWriteCommand(vcp: 0x14, value: 0x01)
        )
        XCTAssertEqual(
            DisplayColorPresetDDPMTable.writeCommand(forName: "DCI-P3"),
            DisplayColorPresetWriteCommand(vcp: 0xF0, value: 0x0A)
        )
        XCTAssertEqual(
            DisplayColorPresetDDPMTable.writeCommand(forName: "Standard"),
            DisplayColorPresetWriteCommand(vcp: 0xDC, value: 0x00)
        )
        XCTAssertEqual(
            DisplayColorPresetDDPMTable.writeCommand(forName: "Display HDR"),
            DisplayColorPresetWriteCommand(vcp: 0xF0, value: 0x36)
        )
        XCTAssertNil(DisplayColorPresetDDPMTable.writeCommand(forName: "Preset 0xFE"))
    }
}
