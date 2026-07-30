import CoreGraphics
import XCTest
@testable import ToolBox

final class DarwinDisplayColorPresetProviderTests: XCTestCase {
    func testCompleteCapabilityProjectsOnlyAllowlistedAdvertisedOptions() async throws {
        let transport = PresetTestTransport(
            connectionToken: 10,
            capabilityResult: .success("vcp(10 12 14(0B 41 FE) 62 8D)")
        )
        let provider = makeProvider(transport: { transport })

        let snapshot = try await provider.snapshot()
        let display = try XCTUnwrap(snapshot.displays.first)
        let preset = try XCTUnwrap(display.colorPreset)

        XCTAssertEqual(preset.status, .available)
        XCTAssertEqual(preset.currentRawValue, 0x0B)
        XCTAssertEqual(preset.options.map(\.rawValue), [0x0B, 0x41])
        XCTAssertEqual(preset.advertisedRawValues, [0x0B, 0x41, 0xFE])
        XCTAssertEqual(transport.capabilityReadCount, 1)
        XCTAssertEqual(transport.readCommands.filter { $0 == 0x14 }.count, 1)
        XCTAssertEqual(display.controls.map(\.kind), DisplayControlKind.allCases)
    }

    func testUnknownIdentityRetainsAdvertisedValuesButIsUnavailable() async throws {
        let transport = PresetTestTransport(
            connectionToken: 10,
            capabilityResult: .success("vcp(10 14(0B 41))")
        )
        let provider = makeProvider(
            identity: DisplayHardwareIdentity(
                vendorNumber: 0xFFFF,
                modelNumber: 1,
                serialNumber: 2
            ),
            transport: { transport }
        )

        let snapshot = try await provider.snapshot()
        let preset = try XCTUnwrap(snapshot.displays.first?.colorPreset)

        XCTAssertEqual(preset.status, .unavailable)
        XCTAssertEqual(preset.options, [])
        XCTAssertEqual(preset.advertisedRawValues, [0x0B, 0x41])
        XCTAssertEqual(transport.readCommands.filter { $0 == 0x14 }.count, 1)
    }

    func testPresetWithoutEnumSubsetIsUnavailableAndSkipsGetVCP() async throws {
        let transport = PresetTestTransport(
            connectionToken: 10,
            capabilityResult: .success("vcp(10 12 14)")
        )
        let provider = makeProvider(transport: { transport })

        let snapshot = try await provider.snapshot()
        let preset = try XCTUnwrap(snapshot.displays.first?.colorPreset)

        XCTAssertEqual(preset.status, .unavailable)
        XCTAssertEqual(preset.advertisedRawValues, [])
        XCTAssertFalse(transport.readCommands.contains(0x14))
    }

    func testMalformedCapabilityIsUnavailableWithoutRemovingExistingControls() async throws {
        let transport = PresetTestTransport(
            connectionToken: 10,
            capabilityResult: .success("vcp(10 14(0B 41)")
        )
        let provider = makeProvider(transport: { transport })

        let snapshot = try await provider.snapshot()
        let display = try XCTUnwrap(snapshot.displays.first)

        XCTAssertEqual(display.colorPreset?.status, .unavailable)
        XCTAssertEqual(display.controls.count, DisplayControlKind.allCases.count)
        XCTAssertTrue(display.controls.allSatisfy { $0.status.isWritable })
    }

    func testDisabledExperimentalFlagSkipsCapabilityReadAndRejectsWrites() async throws {
        let transport = PresetTestTransport(
            connectionToken: 10,
            capabilityResult: .success("vcp(14(0B 41))")
        )
        let provider = makeProvider(enabled: false, transport: { transport })

        let snapshot = try await provider.snapshot()
        let display = try XCTUnwrap(snapshot.displays.first)

        XCTAssertNil(display.colorPreset)
        XCTAssertEqual(transport.capabilityReadCount, 0)
        do {
            _ = try await provider.writeColorPreset(displayID: display.id, rawValue: 0x0B)
            XCTFail("Expected color preset write rejection")
        } catch {
            XCTAssertEqual(error as? DisplayColorPresetError, .capabilityUnavailable)
        }
    }

    func testSameConnectionTokenCachesCapabilityButReadsCurrentPresetOncePerSnapshot() async throws {
        let transport = PresetTestTransport(
            connectionToken: 10,
            capabilityResult: .success("vcp(10 14(0B 41))")
        )
        let provider = makeProvider(transport: { transport })

        _ = try await provider.snapshot()
        _ = try await provider.snapshot()

        XCTAssertEqual(transport.capabilityReadCount, 1)
        XCTAssertEqual(transport.readCommands.filter { $0 == 0x14 }.count, 2)
    }

    func testReconnectWithNewConnectionTokenReadsCapabilityAgain() async throws {
        let first = PresetTestTransport(
            connectionToken: 10,
            capabilityResult: .success("vcp(10 14(0B 41))")
        )
        let second = PresetTestTransport(
            connectionToken: 11,
            capabilityResult: .success("vcp(10 14(0B 41))")
        )
        var current: PresetTestTransport = first
        let provider = makeProvider(transport: { current })

        _ = try await provider.snapshot()
        current = second
        _ = try await provider.snapshot()

        XCTAssertEqual(first.capabilityReadCount, 1)
        XCTAssertEqual(second.capabilityReadCount, 1)
    }

    func testFailedCapabilityReadIsRetriedOnNextSnapshot() async throws {
        let transport = PresetTestTransport(
            connectionToken: 10,
            capabilityResult: .failure(.transportFailure)
        )
        let provider = makeProvider(transport: { transport })

        _ = try await provider.snapshot()
        _ = try await provider.snapshot()

        XCTAssertEqual(transport.capabilityReadCount, 2)
        XCTAssertFalse(transport.readCommands.contains(0x14))
    }

    func testPresetWriteRejectsValueOutsideAdvertisedSubset() async throws {
        let transport = makeWritableTransport()
        let provider = makeProvider(transport: { transport })
        _ = try await provider.snapshot()

        await assertPresetError(
            .valueNotAdvertised(0x42),
            from: provider,
            rawValue: 0x42
        )
        XCTAssertFalse(transport.writes.contains { $0.command == 0x14 })
    }

    func testPresetWriteRejectsUnknownIdentityEvenWhenValueIsAdvertised() async throws {
        let transport = makeWritableTransport()
        let provider = makeProvider(
            identity: DisplayHardwareIdentity(
                vendorNumber: 0xFFFF,
                modelNumber: 1,
                serialNumber: 2
            ),
            transport: { transport }
        )
        _ = try await provider.snapshot()

        await assertPresetError(
            .unverifiedDisplayIdentity,
            from: provider,
            rawValue: 0x0B
        )
        XCTAssertFalse(transport.writes.contains { $0.command == 0x14 })
    }

    func testPresetWriteDoesNotReportSuccessWhenTransportWriteFails() async throws {
        let transport = makeWritableTransport()
        let provider = makeProvider(transport: { transport })
        _ = try await provider.snapshot()
        transport.writeSucceeds = false

        await assertPresetError(
            .transportWriteFailed,
            from: provider,
            rawValue: 0x41
        )
    }

    func testPresetWriteRetriesReadbackUntilRequestedValueAppears() async throws {
        let transport = makeWritableTransport()
        var sleeps: [UInt64] = []
        let provider = makeProvider(
            sleeper: { sleeps.append($0) },
            transport: { transport }
        )
        _ = try await provider.snapshot()
        transport.presetReadOutcomes = [
            .success(DDCReadResult(current: 0x0B, maximum: 0xFF)),
            .success(DDCReadResult(current: 0x41, maximum: 0xFF)),
        ]

        let result = try await provider.writeColorPreset(
            displayID: displayID,
            rawValue: 0x41
        )

        XCTAssertEqual(result.requestedRawValue, 0x41)
        XCTAssertEqual(result.verifiedRawValue, 0x41)
        XCTAssertEqual(transport.writes.last?.command, 0x14)
        XCTAssertEqual(transport.writes.last?.value, 0x41)
        XCTAssertEqual(transport.presetVerificationReadCount, 2)
        XCTAssertEqual(sleeps, [0, 0])
    }

    func testPresetWriteFailsWhenReadbackNeverMatches() async throws {
        let transport = makeWritableTransport()
        let provider = makeProvider(transport: { transport })
        _ = try await provider.snapshot()
        transport.presetReadOutcomes = [
            .success(DDCReadResult(current: 0x0B, maximum: 0xFF)),
            .success(DDCReadResult(current: 0x0B, maximum: 0xFF)),
            .success(DDCReadResult(current: 0x0B, maximum: 0xFF)),
        ]

        await assertPresetError(
            .verificationMismatch(requested: 0x41, lastObserved: 0x0B),
            from: provider,
            rawValue: 0x41
        )
        XCTAssertEqual(transport.presetVerificationReadCount, 3)
    }

    func testVerifiedPresetWriteInvalidatesBrightnessAndContrastValues() async throws {
        let transport = makeWritableTransport()
        let provider = makeProvider(transport: { transport })
        _ = try await provider.snapshot()

        _ = try await provider.writeValue(
            displayID: displayID,
            kind: .brightness,
            normalizedValue: 0.5
        )
        _ = try await provider.writeValue(
            displayID: displayID,
            kind: .contrast,
            normalizedValue: 0.5
        )
        _ = try await provider.writeValue(
            displayID: displayID,
            kind: .brightness,
            normalizedValue: 0.5
        )
        _ = try await provider.writeValue(
            displayID: displayID,
            kind: .contrast,
            normalizedValue: 0.5
        )
        XCTAssertEqual(transport.writes.filter { $0.command == 0x10 }.count, 1)
        XCTAssertEqual(transport.writes.filter { $0.command == 0x12 }.count, 1)

        transport.presetReadOutcomes = [
            .success(DDCReadResult(current: 0x41, maximum: 0xFF)),
        ]
        _ = try await provider.writeColorPreset(displayID: displayID, rawValue: 0x41)

        _ = try await provider.writeValue(
            displayID: displayID,
            kind: .brightness,
            normalizedValue: 0.5
        )
        _ = try await provider.writeValue(
            displayID: displayID,
            kind: .contrast,
            normalizedValue: 0.5
        )
        XCTAssertEqual(transport.writes.filter { $0.command == 0x10 }.count, 2)
        XCTAssertEqual(transport.writes.filter { $0.command == 0x12 }.count, 2)
    }

    func testUnsupportedReplyDoesNotRetryForever() async throws {
        let transport = makeWritableTransport()
        let provider = makeProvider(transport: { transport })
        _ = try await provider.snapshot()
        transport.presetReadOutcomes = [
            .failure(.unsupportedReply(resultCode: 1)),
            .success(DDCReadResult(current: 0x41, maximum: 0xFF)),
        ]

        await assertPresetError(
            .readbackFailed,
            from: provider,
            rawValue: 0x41
        )
        XCTAssertEqual(transport.presetVerificationReadCount, 1)
    }

    private let displayID: CGDirectDisplayID = 77

    private var verifiedIdentity: DisplayHardwareIdentity {
        DisplayHardwareIdentity(
            vendorNumber: 0x10AC,
            modelNumber: 0x0001,
            serialNumber: 0x0000002A
        )
    }

    private func makeProvider(
        identity: DisplayHardwareIdentity? = nil,
        enabled: Bool = true,
        sleeper: @escaping (UInt64) -> Void = { _ in },
        transport: @escaping () -> DDCTransport?
    ) -> DarwinDisplayControlProvider {
        DarwinDisplayControlProvider(
            onlineDisplayIDs: { [self.displayID] },
            identity: { _ in identity ?? self.verifiedIdentity },
            transportFactory: { _ in transport() },
            presetCatalog: DisplayColorPresetCatalog(
                entries: [
                    DisplayColorPresetCatalogEntry(
                        identity: verifiedIdentity,
                        options: [
                            DisplayColorPresetOption(rawValue: 0x0B, name: "Verified sRGB"),
                            DisplayColorPresetOption(rawValue: 0x41, name: "Verified HDR Preview"),
                        ]
                    ),
                ]
            ),
            colorPresetPOCEnabled: { enabled },
            verificationPolicy: DisplayColorPresetVerificationPolicy(
                initialDelayNanos: 0,
                retryDelayNanos: 0,
                maximumReadAttempts: 3
            ),
            sleepNanos: sleeper
        )
    }

    private func makeWritableTransport() -> PresetTestTransport {
        PresetTestTransport(
            connectionToken: 10,
            capabilityResult: .success("vcp(10 12 14(0B 41) 62 8D)")
        )
    }

    private func assertPresetError(
        _ expected: DisplayColorPresetError,
        from provider: DarwinDisplayControlProvider,
        rawValue: UInt8
    ) async {
        do {
            _ = try await provider.writeColorPreset(
                displayID: displayID,
                rawValue: rawValue
            )
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? DisplayColorPresetError, expected)
        }
    }
}

private final class PresetTestTransport: DDCTransport {
    struct Write: Equatable {
        var command: UInt8
        var value: UInt16
    }

    let backendName = "test"
    let connectionToken: UInt64?
    var capabilityResult: Result<String, DDCCapabilityReadFailure>
    private(set) var capabilityReadCount = 0
    private(set) var readCommands: [UInt8] = []
    private(set) var presetVerificationReadCount = 0
    private(set) var writes: [Write] = []
    var presetReadOutcomes: [DDCReadOutcome] = []
    var writeSucceeds = true

    init(
        connectionToken: UInt64?,
        capabilityResult: Result<String, DDCCapabilityReadFailure>
    ) {
        self.connectionToken = connectionToken
        self.capabilityResult = capabilityResult
    }

    func readOutcome(command: UInt8, options _: DDCRequestOptions) -> DDCReadOutcome {
        readCommands.append(command)
        if command == 0x14 {
            if !presetReadOutcomes.isEmpty {
                presetVerificationReadCount += 1
                return presetReadOutcomes.removeFirst()
            }
            return .success(DDCReadResult(current: 0x0B, maximum: 0xFF))
        }
        if command == DDCVCPCommand.audioMuteScreenBlank.rawValue {
            return .success(DDCReadResult(current: 2, maximum: 2))
        }
        return .success(DDCReadResult(current: 50, maximum: 100))
    }

    func readCapabilityString(
        options _: DDCRequestOptions
    ) -> Result<String, DDCCapabilityReadFailure> {
        capabilityReadCount += 1
        return capabilityResult
    }

    func write(command: UInt8, value: UInt16, options _: DDCRequestOptions) -> Bool {
        writes.append(Write(command: command, value: value))
        return writeSucceeds
    }
}
