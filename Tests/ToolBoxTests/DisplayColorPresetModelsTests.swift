import CoreGraphics
import XCTest
@testable import ToolBox

final class DisplayColorPresetModelsTests: XCTestCase {
    func testUnknownIdentityReturnsNoWritableFriendlyOptions() {
        let catalog = makeCatalog()
        let unknownIdentity = DisplayHardwareIdentity(
            vendorNumber: 0x10AC,
            modelNumber: 0x9999,
            serialNumber: 0x2A
        )

        XCTAssertEqual(
            catalog.options(identity: unknownIdentity, advertisedValues: [0x0B, 0x41]),
            []
        )
    }

    func testAllowlistedIdentityOnlyReturnsAdvertisedValues() {
        let options = makeCatalog().options(
            identity: verifiedIdentity,
            advertisedValues: [0x0B, 0xFF]
        )

        XCTAssertEqual(
            options,
            [DisplayColorPresetOption(rawValue: 0x0B, name: "Verified sRGB")]
        )
    }

    func testUnknownAdvertisedValueIsPreservedForDiagnosticsButNotWritable() {
        let advertised: [UInt8] = [0x0B, 0xFE]
        let capability = DisplayColorPresetCapability(
            status: .available,
            currentRawValue: 0xFE,
            options: makeCatalog().options(
                identity: verifiedIdentity,
                advertisedValues: Set(advertised)
            ),
            advertisedRawValues: advertised,
            unavailableReason: nil
        )

        XCTAssertEqual(capability.advertisedRawValues, [0x0B, 0xFE])
        XCTAssertEqual(capability.options.map(\.rawValue), [0x0B])
    }

    func testDuplicateDisplayNamesDoNotAffectIdentityMatching() {
        let catalog = makeCatalog()

        XCTAssertEqual(
            catalog.options(identity: verifiedIdentity, advertisedValues: [0x41]),
            [DisplayColorPresetOption(rawValue: 0x41, name: "Verified HDR Preview")]
        )
    }

    func testCodableSnapshotRoundTripsColorPresetCapability() throws {
        let capability = DisplayColorPresetCapability(
            status: .available,
            currentRawValue: 0x0B,
            options: [DisplayColorPresetOption(rawValue: 0x0B, name: "Verified sRGB")],
            advertisedRawValues: [0x0B, 0x41, 0xFE],
            unavailableReason: nil
        )
        let display = DisplayControlDisplay(
            id: 12,
            name: "Same Name",
            vendorNumber: verifiedIdentity.vendorNumber,
            modelNumber: verifiedIdentity.modelNumber,
            serialNumber: verifiedIdentity.serialNumber,
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

    func testProductionCatalogHasNoGuessedMappings() {
        XCTAssertEqual(
            DisplayColorPresetCatalog.production.options(
                identity: verifiedIdentity,
                advertisedValues: [0x0B, 0x41]
            ),
            []
        )
    }

    private var verifiedIdentity: DisplayHardwareIdentity {
        DisplayHardwareIdentity(
            vendorNumber: 0x10AC,
            modelNumber: 0x0001,
            serialNumber: 0x0000002A
        )
    }

    private func makeCatalog() -> DisplayColorPresetCatalog {
        DisplayColorPresetCatalog(
            entries: [
                DisplayColorPresetCatalogEntry(
                    identity: verifiedIdentity,
                    options: [
                        DisplayColorPresetOption(rawValue: 0x0B, name: "Verified sRGB"),
                        DisplayColorPresetOption(rawValue: 0x41, name: "Verified HDR Preview"),
                    ]
                ),
            ]
        )
    }
}
