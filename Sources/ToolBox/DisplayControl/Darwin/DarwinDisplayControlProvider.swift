import AppKit
import CoreGraphics
import Foundation
import IOKit
import OSLog

final class DarwinDisplayControlProvider: DisplayControlProviding {
    private let queue = DispatchQueue(label: "ToolBox DisplayControl DDC queue")
    private let logger = Logger(subsystem: "ToolBox", category: "DisplayControlProvider")
    private let onlineDisplayIDsProvider: () -> [CGDirectDisplayID]
    private let hardwareIdentityProvider: (CGDirectDisplayID) -> DisplayHardwareIdentity
    private let displayNameProvider: (CGDirectDisplayID) -> String
    private let injectedTransportFactory: ((CGDirectDisplayID) -> DDCTransport?)?
    private let verificationPolicy: DisplayColorPresetVerificationPolicy
    private let sleepNanos: (UInt64) -> Void
    private var transports: [CGDirectDisplayID: DDCTransport] = [:]
    private var unavailableReasons: [CGDirectDisplayID: String] = [:]
    private var valueStore = DisplayControlValueStore()
    private var capabilityStore = DisplayCapabilityStore()

    init() {
        onlineDisplayIDsProvider = Self.onlineDisplayIDs
        hardwareIdentityProvider = Self.hardwareIdentity
        displayNameProvider = Self.displayName(displayID:)
        injectedTransportFactory = nil
        verificationPolicy = .poc
        sleepNanos = { nanos in
            Thread.sleep(forTimeInterval: Double(nanos) / 1_000_000_000)
        }
    }

    init(
        onlineDisplayIDs: @escaping () -> [CGDirectDisplayID],
        identity: @escaping (CGDirectDisplayID) -> DisplayHardwareIdentity,
        displayName: @escaping (CGDirectDisplayID) -> String = DarwinDisplayControlProvider.displayName(displayID:),
        transportFactory: @escaping (CGDirectDisplayID) -> DDCTransport?,
        verificationPolicy: DisplayColorPresetVerificationPolicy = .poc,
        sleepNanos: @escaping (UInt64) -> Void = { nanos in
            Thread.sleep(forTimeInterval: Double(nanos) / 1_000_000_000)
        }
    ) {
        onlineDisplayIDsProvider = onlineDisplayIDs
        hardwareIdentityProvider = identity
        displayNameProvider = displayName
        injectedTransportFactory = transportFactory
        self.verificationPolicy = verificationPolicy
        self.sleepNanos = sleepNanos
    }

    func refresh() async throws {
        try await queue.asyncCancellable {
            try self.refreshConnectionsLocked(displayIDs: self.onlineDisplayIDsProvider())
        }
    }

    func snapshot() async throws -> DisplayControlSnapshot {
        try await queue.asyncCancellable {
            let displayIDs = self.onlineDisplayIDsProvider()
            try self.refreshConnectionsLocked(displayIDs: displayIDs)
            return DisplayControlSnapshot(
                timestamp: Date(),
                displays: displayIDs.map { self.makeDisplayLocked(displayID: $0) }
            )
        }
    }

    func readValue(displayID: CGDirectDisplayID, kind: DisplayControlKind) async throws -> DisplayControlValue {
        try await queue.asyncCancellable {
            try self.ensureDisplayOnline(displayID)
            guard let transport = self.transports[displayID] else {
                throw DisplayControlError.backendUnavailable(displayID, self.unavailableReasonLocked(displayID: displayID))
            }
            guard let read = transport.read(command: kind.ddcCommand.rawValue, options: .interactive) else {
                throw DisplayControlError.readFailed(displayID, kind)
            }
            let value = try Self.decodeValue(kind: kind, read: read)
            self.valueStore.recordObserved(
                value,
                for: DisplayControlValueKey(displayID: displayID, kind: kind),
                identity: self.brightnessMemoryIdentityLocked(displayID: displayID)
            )
            return value
        }
    }

    func writeValue(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind,
        normalizedValue: Double,
        options: DisplayControlWriteOptions
    ) async throws -> DisplayControlValue {
        try await queue.asyncCancellable {
            try self.ensureDisplayOnline(displayID)
            guard normalizedValue.isFinite, (0...1).contains(normalizedValue) else {
                throw DisplayControlError.invalidValue(normalizedValue)
            }
            guard let transport = self.transports[displayID] else {
                throw DisplayControlError.backendUnavailable(displayID, self.unavailableReasonLocked(displayID: displayID))
            }
            let key = DisplayControlValueKey(displayID: displayID, kind: kind)
            let rawValue = try self.valueStore.rawValue(for: key, normalized: normalizedValue)
            let force = options.contains(.force)
            if self.valueStore.shouldWrite(rawValue, for: key, force: force) {
                guard transport.write(command: kind.ddcCommand.rawValue, value: rawValue, options: .interactive) else {
                    throw DisplayControlError.writeFailed(displayID, kind)
                }
                self.valueStore.recordSuccessfulWrite(
                    rawValue,
                    normalized: normalizedValue,
                    for: key,
                    identity: self.brightnessMemoryIdentityLocked(displayID: displayID)
                )
            }
            return self.valueStore.value(for: key)
        }
    }

    func writeColorPreset(
        displayID: CGDirectDisplayID,
        rawValue: UInt8
    ) async throws -> DisplayColorPresetWriteResult {
        try await queue.asyncCancellable {
            do {
                try self.ensureDisplayOnline(displayID)
            } catch {
                throw DisplayColorPresetError.capabilityUnavailable
            }
            guard let transport = self.transports[displayID],
                  let connectionToken = transport.connectionToken else {
                throw DisplayColorPresetError.capabilityUnavailable
            }

            let identity = self.hardwareIdentityProvider(displayID)
            let cacheKey = DisplayCapabilityCacheKey(
                displayID: displayID,
                hardwareIdentity: identity,
                backendName: transport.backendName,
                connectionToken: connectionToken
            )
            let report: DDCCapabilityReport
            if let cached = self.capabilityStore.report(for: cacheKey) {
                report = cached
            } else if let fallback = self.fallbackColorPresetReport(
                displayID: displayID,
                transport: transport,
                cacheKey: cacheKey
            ) {
                report = fallback
            } else {
                throw DisplayColorPresetError.capabilityUnavailable
            }

            let presetCode = report.resolveColorPresetCode()
            guard let presetCodeValue = presetCode.rawValue else {
                switch presetCode {
                case .notAdvertised, .advertisedNoEnumSubset:
                    throw DisplayColorPresetError.presetNotAdvertised
                case .capabilityStringUnavailable:
                    throw DisplayColorPresetError.capabilityUnavailable
                case .dellE2, .mccs14:
                    throw DisplayColorPresetError.capabilityUnavailable
                }
            }
            guard let advertisedValues = report.advertisedValues(for: presetCode) else {
                throw DisplayColorPresetError.presetNotAdvertised
            }
            guard advertisedValues.contains(rawValue) else {
                throw DisplayColorPresetError.valueNotAdvertised(rawValue)
            }

            let identityDescription = DDCDiagnostics.identity(identity)
            let modelName = self.displayNameProvider(displayID)
            let modelYear = DisplayColorPresetDDPMTable.modelYear(from: modelName)
            let optionName = DisplayColorPresetDDPMTable.name(
                for: rawValue,
                modelName: modelName,
                modelYear: modelYear
            )
            let writeCommand: DisplayColorPresetWriteCommand?
            if presetCode == .dellE2, let optionName {
                writeCommand = DisplayColorPresetDDPMTable.writeCommand(forName: optionName)
            } else {
                writeCommand = nil
            }
            let writeVCP = writeCommand?.vcp ?? presetCodeValue
            let writeValue = writeCommand?.value ?? rawValue
            self.logger.info(
                "preset-write display=\(displayID, privacy: .public) \(identityDescription, privacy: .public) backend=\(transport.backendName, privacy: .public) vcp=\(DDCDiagnostics.hex(writeVCP), privacy: .public) requested=\(DDCDiagnostics.hex(rawValue), privacy: .public) write-value=\(DDCDiagnostics.hex(writeValue), privacy: .public)"
            )

            let maximumWriteAttempts = max(self.verificationPolicy.maximumWriteAttempts, 1)
            var writeSucceeded = false
            for writeAttempt in 1...maximumWriteAttempts {
                guard transport.write(
                    command: writeVCP,
                    value: UInt16(writeValue),
                    options: .interactive
                ) else {
                    self.logger.error(
                        "VCP \(DDCDiagnostics.hex(writeVCP)) write attempt \(writeAttempt) failed for display \(displayID, privacy: .public)."
                    )
                    if writeAttempt < maximumWriteAttempts {
                        self.sleepNanos(self.verificationPolicy.writeRetryDelayNanos)
                    }
                    continue
                }
                writeSucceeded = true
                break
            }
            guard writeSucceeded else {
                throw DisplayColorPresetError.transportWriteFailed
            }

            self.sleepNanos(self.verificationPolicy.initialDelayNanos)
            let maximumReadAttempts = max(self.verificationPolicy.maximumReadAttempts, 1)
            var lastObserved: UInt8?
            var receivedValidRead = false
            for attempt in 1...maximumReadAttempts {
                switch transport.readOutcome(command: presetCodeValue, options: .interactive) {
                case .success(let result):
                    receivedValidRead = true
                    lastObserved = UInt8(exactly: result.current)
                    let disposition = lastObserved == rawValue ? "match" : "mismatch"
                    self.logger.debug(
                        "preset-verify display=\(displayID, privacy: .public) \(identityDescription, privacy: .public) backend=\(transport.backendName, privacy: .public) vcp=\(DDCDiagnostics.hex(presetCodeValue), privacy: .public) requested=\(DDCDiagnostics.hex(rawValue), privacy: .public) attempt=\(attempt, privacy: .public) current=\(DDCDiagnostics.hex(result.current), privacy: .public) maximum=\(DDCDiagnostics.hex(result.maximum), privacy: .public) result=\(disposition, privacy: .public)"
                    )
                    if lastObserved == rawValue {
                        self.valueStore.invalidate(
                            displayID: displayID,
                            kinds: [.brightness, .contrast]
                        )
                        return DisplayColorPresetWriteResult(
                            displayID: displayID,
                            requestedRawValue: rawValue,
                            verifiedRawValue: rawValue,
                            verifiedAt: Date()
                        )
                    }
                case .failure(.unsupportedReply):
                    self.logger.debug(
                        "preset-verify display=\(displayID, privacy: .public) \(identityDescription, privacy: .public) backend=\(transport.backendName, privacy: .public) vcp=\(DDCDiagnostics.hex(presetCodeValue), privacy: .public) requested=\(DDCDiagnostics.hex(rawValue), privacy: .public) attempt=\(attempt, privacy: .public) result=unsupported-reply"
                    )
                    self.logger.error(
                        "VCP \(DDCDiagnostics.hex(presetCodeValue)) readback was unsupported for display \(displayID, privacy: .public)."
                    )
                    throw DisplayColorPresetError.readbackFailed
                case .failure(let failure):
                    self.logger.debug(
                        "preset-verify display=\(displayID, privacy: .public) \(identityDescription, privacy: .public) backend=\(transport.backendName, privacy: .public) vcp=\(DDCDiagnostics.hex(presetCodeValue), privacy: .public) requested=\(DDCDiagnostics.hex(rawValue), privacy: .public) attempt=\(attempt, privacy: .public) result=\(String(describing: failure), privacy: .public)"
                    )
                }
                if attempt < maximumReadAttempts {
                    self.sleepNanos(self.verificationPolicy.retryDelayNanos)
                }
            }

            if receivedValidRead {
                throw DisplayColorPresetError.verificationMismatch(
                    requested: rawValue,
                    lastObserved: lastObserved
                )
            }
            throw DisplayColorPresetError.readbackFailed
        }
    }

    private func refreshConnectionsLocked(displayIDs: [CGDirectDisplayID]) throws {
        var nextTransports: [CGDirectDisplayID: DDCTransport] = [:]
        var nextReasons: [CGDirectDisplayID: String] = [:]

        if let injectedTransportFactory {
            for displayID in displayIDs {
                if let transport = injectedTransportFactory(displayID) {
                    nextTransports[displayID] = transport
                } else {
                    nextReasons[displayID] = "No injected DDC transport is available."
                }
            }
        } else if Arm64DDCBackend.isArm64 {
            let matches = Arm64DDCBackend.serviceMatches(displayIDs: displayIDs)
            for match in matches {
                if match.dummy {
                    nextReasons[match.displayID] = "Display is marked as a dummy display."
                    continue
                }
                if match.discouraged {
                    nextReasons[match.displayID] = "Display is discouraged for DDC control."
                    continue
                }
                guard let service = match.service else {
                    nextReasons[match.displayID] = "No IOAVService was matched for this display."
                    continue
                }
                nextTransports[match.displayID] = Arm64DDCBackend(
                    service: service,
                    connectionToken: match.connectionToken
                )
            }
        } else {
            for displayID in displayIDs {
                guard Self.isExternalHardwareDisplay(displayID) else {
                    nextReasons[displayID] = Self.staticUnavailableReason(displayID: displayID)
                    continue
                }
                if let backend = IntelDDCBackend(displayID: displayID) {
                    nextTransports[displayID] = backend
                } else {
                    nextReasons[displayID] = "No IOKit I2C framebuffer was matched for this display."
                }
            }
        }

        for displayID in displayIDs where nextTransports[displayID] == nil && nextReasons[displayID] == nil {
            nextReasons[displayID] = Self.staticUnavailableReason(displayID: displayID)
        }

        transports = nextTransports
        unavailableReasons = nextReasons
        valueStore.retainDisplays(Set(nextTransports.keys))
        capabilityStore.retainConnections(
            Set(nextTransports.compactMap { displayID, transport in
                guard let connectionToken = transport.connectionToken else {
                    return nil
                }
                return DisplayCapabilityCacheKey(
                    displayID: displayID,
                    hardwareIdentity: hardwareIdentityProvider(displayID),
                    backendName: transport.backendName,
                    connectionToken: connectionToken
                )
            })
        )
    }

    private func makeDisplayLocked(displayID: CGDirectDisplayID) -> DisplayControlDisplay {
        let transport = transports[displayID]
        let reason = unavailableReasonLocked(displayID: displayID)
        let identity = hardwareIdentityProvider(displayID)
        let controls = DisplayControlKind.allCases.map { kind in
            makeCapabilityLocked(displayID: displayID, kind: kind, transport: transport, displayReason: reason)
        }

        return DisplayControlDisplay(
            id: displayID,
            name: displayNameProvider(displayID),
            vendorNumber: identity.vendorNumber,
            modelNumber: identity.modelNumber,
            serialNumber: identity.serialNumber,
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
            isVirtual: Self.isVirtual(displayID: displayID),
            supportsHardwareDDC: transport != nil,
            backendName: transport?.backendName,
            unavailableReason: transport == nil ? reason : nil,
            controls: controls,
            colorPreset: makeColorPresetLocked(
                displayID: displayID,
                identity: identity,
                transport: transport
            )
        )
    }

    private func makeCapabilityLocked(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind,
        transport: DDCTransport?,
        displayReason: String
    ) -> DisplayControlCapability {
        guard isExternalHardwareDisplayLocked(displayID) else {
            return DisplayControlCapability(
                kind: kind,
                status: .unsupported,
                value: nil,
                unavailableReason: displayReason
            )
        }
        guard let transport else {
            return DisplayControlCapability(
                kind: kind,
                status: .unavailable,
                value: nil,
                unavailableReason: displayReason
            )
        }
        let key = DisplayControlValueKey(displayID: displayID, kind: kind)
        let observedValue = try? self.currentValueLocked(
            displayID: displayID,
            kind: kind,
            transport: transport,
            options: .probe
        )
        return valueStore.capability(
            for: key,
            identity: brightnessMemoryIdentityLocked(displayID: displayID),
            observedValue: observedValue
        )
    }

    private func ensureDisplayOnline(_ displayID: CGDirectDisplayID) throws {
        let online = onlineDisplayIDsProvider()
        guard online.contains(displayID) else {
            throw DisplayControlError.displayNotFound(displayID)
        }
        if transports[displayID] == nil && unavailableReasons[displayID] == nil {
            try refreshConnectionsLocked(displayIDs: online)
        }
    }

    private func currentValueLocked(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind,
        transport: DDCTransport,
        options: DDCRequestOptions = .interactive
    ) throws -> DisplayControlValue {
        guard let read = transport.read(command: kind.ddcCommand.rawValue, options: options) else {
            throw DisplayControlError.readFailed(displayID, kind)
        }
        return try Self.decodeValue(kind: kind, read: read)
    }

    private func unavailableReasonLocked(displayID: CGDirectDisplayID) -> String {
        unavailableReasons[displayID] ?? Self.staticUnavailableReason(displayID: displayID)
    }

    private func makeColorPresetLocked(
        displayID: CGDirectDisplayID,
        identity: DisplayHardwareIdentity,
        transport: DDCTransport?
    ) -> DisplayColorPresetCapability? {
        guard let transport, let connectionToken = transport.connectionToken else {
            return unavailableColorPreset(reason: "Capability discovery requires a registry-backed display connection.")
        }

        let cacheKey = DisplayCapabilityCacheKey(
            displayID: displayID,
            hardwareIdentity: identity,
            backendName: transport.backendName,
            connectionToken: connectionToken
        )
        let report: DDCCapabilityReport
        if let cached = capabilityStore.report(for: cacheKey) {
            report = cached
        } else if case let .success(rawString) = transport.readCapabilityString(options: .probe),
                  case let .success(parsed) = DDCCapabilityParser.parse(rawString) {
            let advertisedPresetValues: String
            let advertisedPresetCode: UInt8?
            switch parsed.resolveColorPresetCode() {
            case .dellE2:
                advertisedPresetCode = 0xE2
                advertisedPresetValues = parsed.advertisedValues(for: .dellE2)
                    .map { $0.sorted().map(DDCDiagnostics.hex).joined(separator: ",") } ?? "no-enum-subset"
            case .mccs14:
                advertisedPresetCode = 0x14
                advertisedPresetValues = parsed.advertisedValues(for: .mccs14)
                    .map { $0.sorted().map(DDCDiagnostics.hex).joined(separator: ",") } ?? "no-enum-subset"
            case .advertisedNoEnumSubset:
                advertisedPresetCode = nil
                advertisedPresetValues = "no-enum-subset"
            case .notAdvertised:
                advertisedPresetCode = nil
                advertisedPresetValues = "not-advertised"
            case .capabilityStringUnavailable:
                advertisedPresetCode = nil
                advertisedPresetValues = "unavailable"
            }
            let presetCodeLog = advertisedPresetCode.map(DDCDiagnostics.hex) ?? "none"
            self.logger.debug(
                "capability-report display=\(displayID, privacy: .public) \(DDCDiagnostics.identity(identity), privacy: .public) backend=\(transport.backendName, privacy: .public) bytes=\(rawString.utf8.count, privacy: .public) vcp=\(presetCodeLog, privacy: .public) preset-values=\(advertisedPresetValues, privacy: .public)"
            )
            capabilityStore.record(parsed, for: cacheKey)
            report = parsed
        } else if let fallback = fallbackColorPresetReport(
            displayID: displayID,
            transport: transport,
            cacheKey: cacheKey
        ) {
            report = fallback
        } else {
            return unavailableColorPreset(reason: "The display capability report could not be read and validated.")
        }

        let presetCode = report.resolveColorPresetCode()
        guard let presetCodeValue = presetCode.rawValue else {
            switch presetCode {
            case .capabilityStringUnavailable:
                return unavailableColorPreset(
                    reason: "The display capability report is unavailable."
                )
            case .advertisedNoEnumSubset:
                return unavailableColorPreset(
                    reason: "The display advertised a color preset VCP without an allowed value subset."
                )
            case .notAdvertised:
                return DisplayColorPresetCapability(
                    status: .unsupported,
                    currentRawValue: nil,
                    options: [],
                    advertisedRawValues: [],
                    unavailableReason: "The display did not advertise a color preset VCP (0xE2 or 0x14)."
                )
            case .dellE2, .mccs14:
                return unavailableColorPreset(
                    reason: "The display advertised a resolvable preset code without a usable value."
                )
            }
        }
        guard let advertisedValues = report.advertisedValues(for: presetCode) else {
            return unavailableColorPreset(
                reason: "The display advertised a color preset VCP without an allowed value subset."
            )
        }
        let sortedValues = advertisedValues.sorted()
        let modelName = displayNameProvider(displayID)
        let options = DisplayColorPresetDDPMTable.options(
            for: advertisedValues,
            modelName: modelName,
            modelYear: DisplayColorPresetDDPMTable.modelYear(from: modelName)
        )
        let currentRawValue: UInt8?
        if case let .success(read) = transport.readOutcome(command: presetCodeValue, options: .probe) {
            currentRawValue = UInt8(exactly: read.current)
        } else {
            currentRawValue = nil
        }
        return DisplayColorPresetCapability(
            status: .available,
            currentRawValue: currentRawValue,
            options: options,
            advertisedRawValues: sortedValues,
            unavailableReason: nil
        )
    }

    private func fallbackColorPresetReport(
        displayID: CGDirectDisplayID,
        transport: DDCTransport,
        cacheKey: DisplayCapabilityCacheKey
    ) -> DDCCapabilityReport? {
        let modelName = displayNameProvider(displayID)
        guard let rawString = DisplayCapabilityStringFallback.capabilityString(forModelName: modelName),
              case let .success(parsed) = DDCCapabilityParser.parse(rawString) else {
            return nil
        }
        self.logger.info(
            "capability-fallback display=\(displayID, privacy: .public) model=\(modelName, privacy: .public) source=ddpm-verified-cache"
        )
        capabilityStore.record(parsed, for: cacheKey)
        return parsed
    }

    private func unavailableColorPreset(reason: String) -> DisplayColorPresetCapability {
        DisplayColorPresetCapability(
            status: .unavailable,
            currentRawValue: nil,
            options: [],
            advertisedRawValues: [],
            unavailableReason: reason
        )
    }

    private func isExternalHardwareDisplayLocked(_ displayID: CGDirectDisplayID) -> Bool {
        injectedTransportFactory != nil || Self.isExternalHardwareDisplay(displayID)
    }

    private func brightnessMemoryIdentityLocked(
        displayID: CGDirectDisplayID
    ) -> DisplayBrightnessMemoryIdentity? {
        let identity = hardwareIdentityProvider(displayID)
        guard let vendorNumber = identity.vendorNumber,
              let modelNumber = identity.modelNumber,
              let serialNumber = identity.serialNumber else {
            return nil
        }
        return DisplayBrightnessMemoryIdentity(
            vendorNumber: vendorNumber,
            modelNumber: modelNumber,
            serialNumber: serialNumber
        )
    }

    static func decodeValue(kind: DisplayControlKind, read: DDCReadResult) throws -> DisplayControlValue {
        if kind == .mute {
            let muted = read.current == 1
            return DisplayControlValue(
                kind: kind,
                timestamp: Date(),
                rawCurrent: muted ? 1 : 2,
                rawMinimum: 0,
                rawMaximum: 2,
                normalized: muted ? 1 : 0
            )
        }

        let minimum: UInt16 = 0
        let maximum = read.maximum
        guard maximum > minimum, maximum != .max else {
            throw DisplayControlError.invalidRange(minimum: minimum, maximum: maximum)
        }

        let clamped = min(max(read.current, minimum), maximum)
        let normalized = Double(clamped - minimum) / Double(maximum - minimum)
        return DisplayControlValue(
            kind: kind,
            timestamp: Date(),
            rawCurrent: clamped,
            rawMinimum: minimum,
            rawMaximum: maximum,
            normalized: normalized
        )
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount) == .success else {
            return []
        }
        return Array(displayIDs.prefix(Int(displayCount))).filter { $0 != 0 }
    }

    private static func isExternalHardwareDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(displayID) == 0 && !isVirtual(displayID: displayID)
    }

    private static func staticUnavailableReason(displayID: CGDirectDisplayID) -> String {
        if CGDisplayIsBuiltin(displayID) != 0 {
            return "Built-in displays use the native Apple brightness path, not DDC."
        }
        if isVirtual(displayID: displayID) {
            return "Virtual displays do not expose hardware DDC control."
        }
        return "No hardware DDC transport is available."
    }

    private static func displayName(displayID: CGDirectDisplayID) -> String {
        if let dictionary = CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue() as NSDictionary?,
           let names = dictionary["DisplayProductName"] as? [String: String],
           let name = names[Locale.current.identifier] ?? names["en_US"] ?? names.first?.value {
            return name
        }

        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) {
            return screen.localizedName
        }

        return "Display \(displayID)"
    }

    private static func vendorNumber(displayID: CGDirectDisplayID) -> UInt32? {
        let value = CGDisplayVendorNumber(displayID)
        return value == UInt32.max ? nil : value
    }

    private static func modelNumber(displayID: CGDirectDisplayID) -> UInt32? {
        let value = CGDisplayModelNumber(displayID)
        return value == UInt32.max ? nil : value
    }

    private static func serialNumber(displayID: CGDirectDisplayID) -> UInt32? {
        let value = CGDisplaySerialNumber(displayID)
        return value == 0 ? nil : value
    }

    private static func hardwareIdentity(
        displayID: CGDirectDisplayID
    ) -> DisplayHardwareIdentity {
        DisplayHardwareIdentity(
            vendorNumber: vendorNumber(displayID: displayID),
            modelNumber: modelNumber(displayID: displayID),
            serialNumber: serialNumber(displayID: displayID)
        )
    }

    private static func isVirtual(displayID: CGDirectDisplayID) -> Bool {
        guard let dictionary = CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue() as NSDictionary? else {
            return false
        }
        return (dictionary["kCGDisplayIsVirtualDevice"] as? Bool)
            ?? (dictionary["kCGDisplayIsAirPlay"] as? Bool)
            ?? false
    }
}

private final class DispatchQueueCancellableWork<T>: @unchecked Sendable {
    private enum State {
        case pending
        case running
        case cancelled
        case completed
    }

    private let lock = NSLock()
    private var state = State.pending
    private var continuation: CheckedContinuation<T, Error>?
    private var work: (() throws -> T)?

    init(work: @escaping () throws -> T) {
        self.work = work
    }

    func register(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        guard case .pending = state else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func takeWorkForExecution() -> (() throws -> T)? {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = state, let work else { return nil }
        state = .running
        self.work = nil
        return work
    }

    func cancel() {
        let continuation: CheckedContinuation<T, Error>?
        lock.lock()
        if case .pending = state {
            state = .cancelled
            continuation = self.continuation
            self.continuation = nil
            work = nil
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    func complete(_ result: Result<T, Error>) {
        let continuation: CheckedContinuation<T, Error>?
        lock.lock()
        if case .running = state {
            state = .completed
            continuation = self.continuation
            self.continuation = nil
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

extension DispatchQueue {
    func asyncCancellable<T>(
        onEnqueued: (() -> Void)? = nil,
        _ work: @escaping () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let cancellableWork = DispatchQueueCancellableWork(work: work)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard cancellableWork.register(continuation) else { return }
                async {
                    guard let operation = cancellableWork.takeWorkForExecution() else { return }
                    cancellableWork.complete(Result { try operation() })
                }
                onEnqueued?()
            }
        } onCancel: {
            cancellableWork.cancel()
        }
    }
}
