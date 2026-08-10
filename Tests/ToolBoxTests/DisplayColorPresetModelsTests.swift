import CoreGraphics
import XCTest
@testable import ToolBox

final class DisplayColorPresetModelsTests: XCTestCase {
    func testCapabilityPreservesAllAdvertisedRawValuesAlongsideOptions() {
        let advertised: [UInt8] = [0x0B, 0x41, 0xFE]
        let options = DisplayColorPresetDDPMTable.options(
            for: Set(advertised),
            modelName: "U2723QE"
        )
        let capability = DisplayColorPresetCapability(
            status: .available,
            currentRawValue: 0xFE,
            options: options,
            advertisedRawValues: advertised,
            unavailableReason: nil
        )

        XCTAssertEqual(capability.advertisedRawValues, [0x0B, 0x41, 0xFE])
        XCTAssertEqual(capability.options.map(\.rawValue), [0x0B, 0x41, 0xFE])
        XCTAssertEqual(capability.options.map(\.name), ["sRGB", "Preset 0x41", "Preset 0xFE"])
    }

    func testCodableSnapshotRoundTripsColorPresetCapability() throws {
        let capability = DisplayColorPresetCapability(
            status: .available,
            currentRawValue: 0x0B,
            options: [DisplayColorPresetOption(rawValue: 0x0B, name: "sRGB")],
            advertisedRawValues: [0x0B, 0x41, 0xFE],
            unavailableReason: nil
        )
        let identity = DisplayHardwareIdentity(
            vendorNumber: 0x10AC,
            modelNumber: 0x0001,
            serialNumber: 0x0000002A
        )
        let display = DisplayControlDisplay(
            id: 12,
            name: "U2723QE",
            vendorNumber: identity.vendorNumber,
            modelNumber: identity.modelNumber,
            serialNumber: identity.serialNumber,
            isBuiltIn: false,
            isVirtual: false,
            supportsHardwareDDC: true,
            backendName: "test",
            unavailableReason: nil,
            controls: [],
            colorPreset: capability
        )
        let snapshot = DisplayControlSnapshot(timestamp: Date(timeIntervalSince1970: 123), displays: [display])

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DisplayControlSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.displays.first?.colorPreset, capability)
    }
}
