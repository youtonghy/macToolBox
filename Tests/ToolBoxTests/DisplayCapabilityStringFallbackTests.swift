import XCTest
@testable import ToolBox

final class DisplayCapabilityStringFallbackTests: XCTestCase {
    func testU2723QEFallbackParsesAndAdvertisesE2PresetValues() throws {
        let raw = try XCTUnwrap(
            DisplayCapabilityStringFallback.capabilityString(forModelName: "DELL U2723QE")
        )
        let report = try DDCCapabilityParser.parse(raw).get()

        XCTAssertEqual(report.resolveColorPresetCode(), .dellE2)
        XCTAssertEqual(
            report.advertisedValues(for: .dellE2),
            [0x00, 0x02, 0x04, 0x0B, 0x0C, 0x0D, 0x0F, 0x10, 0x11, 0x13, 0x14, 0x1A, 0x1B, 0x23, 0x24, 0x27, 0x3A]
        )
    }

    func testU2723QEFallbackProducesDisplayHDRNameFor3A() {
        XCTAssertEqual(
            DisplayColorPresetDDPMTable.name(for: 0x3A, modelName: "U2723QE"),
            "Display HDR"
        )
    }

    func testUnknownModelHasNoFallback() {
        XCTAssertNil(DisplayCapabilityStringFallback.capabilityString(forModelName: "UP3225"))
        XCTAssertNil(DisplayCapabilityStringFallback.capabilityString(forModelName: nil))
    }
}
