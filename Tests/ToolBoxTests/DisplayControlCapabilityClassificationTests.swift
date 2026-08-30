import CoreGraphics
import XCTest
@testable import ToolBoxCore
@testable import ToolBoxControlProtocol

/// Verifies that capability probing classifies typed DDC failures:
/// an explicit unsupported reply must fail closed (not writable), while
/// transient transport failures keep the control write-only, and the CLI
/// DTO must not report write-only estimates as readable.
final class DisplayControlCapabilityClassificationTests: XCTestCase {
    private final class ClassifiedTransport: DDCTransport {
        let backendName = "classified-test"
        let connectionToken: UInt64? = 1
        var outcomesByCommand: [UInt8: DDCReadOutcome] = [:]

        func readOutcome(command: UInt8, options _: DDCRequestOptions) -> DDCReadOutcome {
            outcomesByCommand[command] ?? .failure(.transportFailure)
        }

        func readCapabilityString(options _: DDCRequestOptions) -> Result<String, DDCCapabilityReadFailure> {
            .failure(.transportFailure)
        }

        func write(command _: UInt8, value _: UInt16, options _: DDCRequestOptions) -> Bool {
            true
        }
    }

    private let displayID: CGDirectDisplayID = 77

    private func makeProvider(transport: ClassifiedTransport) -> DarwinDisplayControlProvider {
        DarwinDisplayControlProvider(
            onlineDisplayIDs: { [self.displayID] },
            identity: { _ in DisplayHardwareIdentity(vendorNumber: 1, modelNumber: 2, serialNumber: 3) },
            transportFactory: { _ in transport }
        )
    }

    private func capability(
        _ kind: DisplayControlKind,
        in snapshot: DisplayControlSnapshot
    ) throws -> DisplayControlCapability {
        let display = try XCTUnwrap(snapshot.displays.first { $0.id == displayID })
        return try XCTUnwrap(display.controls.first { $0.kind == kind })
    }

    func testProbeUnsupportedReplyMarksControlUnsupported() async throws {
        let transport = ClassifiedTransport()
        transport.outcomesByCommand[DDCVCPCommand.luminance.rawValue] =
            .failure(.unsupportedReply(resultCode: 0x01))
        transport.outcomesByCommand[DDCVCPCommand.contrast.rawValue] =
            .success(DDCReadResult(current: 50, maximum: 100))

        let snapshot = try await makeProvider(transport: transport).snapshot()

        let brightness = try capability(.brightness, in: snapshot)
        XCTAssertEqual(brightness.status, .unsupported)
        XCTAssertFalse(brightness.status.isWritable)
        XCTAssertNil(brightness.value)

        let contrast = try capability(.contrast, in: snapshot)
        XCTAssertEqual(contrast.status, .available)
        XCTAssertTrue(contrast.status.isWritable)
    }

    func testProbeTransportFailureKeepsControlWriteOnly() async throws {
        let transport = ClassifiedTransport()
        transport.outcomesByCommand[DDCVCPCommand.luminance.rawValue] =
            .failure(.transportFailure)

        let snapshot = try await makeProvider(transport: transport).snapshot()

        let brightness = try capability(.brightness, in: snapshot)
        XCTAssertEqual(brightness.status, .writeOnly)
        XCTAssertTrue(brightness.status.isWritable)
    }

    func testProbeChecksumFailureKeepsControlWriteOnly() async throws {
        let transport = ClassifiedTransport()
        transport.outcomesByCommand[DDCVCPCommand.audioSpeakerVolume.rawValue] =
            .failure(.checksumMismatch)

        let snapshot = try await makeProvider(transport: transport).snapshot()

        let volume = try capability(.volume, in: snapshot)
        XCTAssertEqual(volume.status, .writeOnly)
        XCTAssertTrue(volume.status.isWritable)
    }

    func testProbeInvalidMuteReplyKeepsControlWriteOnly() async throws {
        let transport = ClassifiedTransport()
        // Firmware replying 0 for mute is invalid per MCCS; it must not be
        // decoded as a readable value.
        transport.outcomesByCommand[DDCVCPCommand.audioMuteScreenBlank.rawValue] =
            .success(DDCReadResult(current: 0, maximum: 2))

        let snapshot = try await makeProvider(transport: transport).snapshot()

        let mute = try capability(.mute, in: snapshot)
        XCTAssertEqual(mute.status, .writeOnly)
        XCTAssertTrue(mute.status.isWritable)
    }

    @MainActor
    func testCLIDTOReportsWriteOnlyEstimateAsNotReadable() throws {
        let writeOnlyDisplay = DisplayControlDisplay(
            id: displayID,
            name: "Test",
            vendorNumber: 1,
            modelNumber: 2,
            serialNumber: 3,
            isBuiltIn: false,
            isVirtual: false,
            supportsHardwareDDC: true,
            backendName: "test",
            unavailableReason: nil,
            controls: [
                DisplayControlCapability(
                    kind: .volume,
                    status: .writeOnly,
                    value: DisplayControlValue(
                        kind: .volume,
                        timestamp: Date(),
                        rawCurrent: 12,
                        rawMinimum: 0,
                        rawMaximum: 100,
                        normalized: 0.12
                    ),
                    unavailableReason: "estimated"
                ),
                DisplayControlCapability(
                    kind: .brightness,
                    status: .available,
                    value: DisplayControlValue(
                        kind: .brightness,
                        timestamp: Date(),
                        rawCurrent: 40,
                        rawMinimum: 0,
                        rawMaximum: 100,
                        normalized: 0.4
                    ),
                    unavailableReason: nil
                ),
            ]
        )

        let dto = ToolBoxCommandRouter.makeDisplayDTO(writeOnlyDisplay)
        let volume = try XCTUnwrap(dto.controls.first { $0.kind == .volume })
        XCTAssertFalse(volume.isReadable)
        XCTAssertTrue(volume.isWritable)

        let brightness = try XCTUnwrap(dto.controls.first { $0.kind == .brightness })
        XCTAssertTrue(brightness.isReadable)
        XCTAssertTrue(brightness.isWritable)
    }
}

extension DisplayControlCapabilityClassificationTests {
    private func makeValidationDisplay(
        supportsHardwareDDC: Bool = true,
        controls: [DisplayControlCapability] = [],
        colorPreset: DisplayColorPresetCapability? = nil
    ) -> DisplayControlDisplay {
        DisplayControlDisplay(
            id: 77,
            name: "Validation Display",
            vendorNumber: 1,
            modelNumber: 2,
            serialNumber: 3,
            isBuiltIn: false,
            isVirtual: false,
            supportsHardwareDDC: supportsHardwareDDC,
            backendName: supportsHardwareDDC ? "test" : nil,
            unavailableReason: supportsHardwareDDC ? nil : "No hardware DDC transport is available.",
            controls: controls,
            colorPreset: colorPreset
        )
    }

    @MainActor
    func testValidateRejectsDisplayWithoutDDCTransport() {
        let display = makeValidationDisplay(supportsHardwareDDC: false)

        XCTAssertThrowsError(
            try ToolBoxCommandRouter.validate(display: display, supports: .brightness(50))
        ) { error in
            XCTAssertEqual((error as? ToolBoxDisplayTargetError)?.code, .unavailable)
        }
    }

    @MainActor
    func testValidateRejectsUnsupportedControlButAcceptsWriteOnly() {
        let display = makeValidationDisplay(controls: [
            DisplayControlCapability(kind: .volume, status: .unsupported, value: nil, unavailableReason: "reported unsupported"),
            DisplayControlCapability(kind: .mute, status: .writeOnly, value: nil, unavailableReason: "estimated"),
        ])

        XCTAssertThrowsError(
            try ToolBoxCommandRouter.validate(display: display, supports: .volume(30))
        ) { error in
            XCTAssertEqual((error as? ToolBoxDisplayTargetError)?.code, .unsupported)
        }
        XCTAssertNoThrow(try ToolBoxCommandRouter.validate(display: display, supports: .mute(true)))
    }

    @MainActor
    func testValidateRejectsUnavailablePresetAndAcceptsAvailablePreset() {
        let unavailable = makeValidationDisplay(
            colorPreset: DisplayColorPresetCapability(
                status: .unavailable,
                currentRawValue: nil,
                options: [],
                advertisedRawValues: [],
                unavailableReason: "capability discovery failed"
            )
        )
        XCTAssertThrowsError(
            try ToolBoxCommandRouter.validate(display: unavailable, supports: .preset("sRGB"))
        ) { error in
            XCTAssertEqual((error as? ToolBoxDisplayTargetError)?.code, .unsupported)
        }

        let available = makeValidationDisplay(
            colorPreset: DisplayColorPresetCapability(
                status: .available,
                currentRawValue: 0x0B,
                options: [DisplayColorPresetOption(rawValue: 0x0B, name: "sRGB")],
                advertisedRawValues: [0x0B],
                unavailableReason: nil
            )
        )
        XCTAssertNoThrow(try ToolBoxCommandRouter.validate(display: available, supports: .preset("sRGB")))
    }
}

extension DisplayControlCapabilityClassificationTests {
    @MainActor
    func testValidateRejectsOutOfRangeControlValues() {
        let display = makeValidationDisplay(controls: [
            DisplayControlCapability(
                kind: .brightness,
                status: .available,
                value: DisplayControlValue(
                    kind: .brightness,
                    timestamp: Date(),
                    rawCurrent: 50,
                    rawMinimum: 0,
                    rawMaximum: 100,
                    normalized: 0.5
                ),
                unavailableReason: nil
            ),
        ])

        for invalid in [-1, 101, 255] {
            XCTAssertThrowsError(
                try ToolBoxCommandRouter.validate(display: display, supports: .brightness(invalid))
            ) { error in
                XCTAssertEqual((error as? ToolBoxDisplayTargetError)?.code, .invalidRequest)
            }
        }
        XCTAssertNoThrow(try ToolBoxCommandRouter.validate(display: display, supports: .brightness(0)))
        XCTAssertNoThrow(try ToolBoxCommandRouter.validate(display: display, supports: .brightness(100)))
    }
}

extension DisplayControlCapabilityClassificationTests {
    @MainActor
    func testValidateRejectsUnadvertisedPresetValues() throws {
        let display = makeValidationDisplay(
            colorPreset: DisplayColorPresetCapability(
                status: .available,
                currentRawValue: 0x0B,
                options: [DisplayColorPresetOption(rawValue: 0x0B, name: "sRGB")],
                advertisedRawValues: [0x0B, 0x41],
                unavailableReason: nil
            )
        )

        XCTAssertThrowsError(
            try ToolBoxCommandRouter.validate(display: display, supports: .preset("0xFF"))
        ) { error in
            XCTAssertEqual((error as? ToolBoxDisplayTargetError)?.code, .invalidRequest)
        }
        XCTAssertNoThrow(try ToolBoxCommandRouter.validate(display: display, supports: .preset("0x41")))
        XCTAssertNoThrow(try ToolBoxCommandRouter.validate(display: display, supports: .preset("sRGB")))
    }
}
