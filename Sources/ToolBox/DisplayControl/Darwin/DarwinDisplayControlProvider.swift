import AppKit
import CoreGraphics
import Foundation
import IOKit
import OSLog

final class DarwinDisplayControlProvider: DisplayControlProviding {
    private let queue = DispatchQueue(label: "ToolBox DisplayControl DDC queue")
    private let logger = Logger(subsystem: "ToolBox", category: "DisplayControlProvider")
    private var transports: [CGDirectDisplayID: DDCTransport] = [:]
    private var unavailableReasons: [CGDirectDisplayID: String] = [:]
    private var valueStore = DisplayControlValueStore()

    func refresh() async throws {
        try await queue.asyncCancellable {
            try self.refreshConnectionsLocked(displayIDs: Self.onlineDisplayIDs())
        }
    }

    func snapshot() async throws -> DisplayControlSnapshot {
        try await queue.asyncCancellable {
            let displayIDs = Self.onlineDisplayIDs()
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
                identity: Self.brightnessMemoryIdentity(displayID: displayID)
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
                    identity: Self.brightnessMemoryIdentity(displayID: displayID)
                )
            }
            return self.valueStore.value(for: key)
        }
    }

    private func refreshConnectionsLocked(displayIDs: [CGDirectDisplayID]) throws {
        var nextTransports: [CGDirectDisplayID: DDCTransport] = [:]
        var nextReasons: [CGDirectDisplayID: String] = [:]

        if Arm64DDCBackend.isArm64 {
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
                nextTransports[match.displayID] = Arm64DDCBackend(service: service)
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
    }

    private func makeDisplayLocked(displayID: CGDirectDisplayID) -> DisplayControlDisplay {
        let transport = transports[displayID]
        let reason = unavailableReasonLocked(displayID: displayID)
        let controls = DisplayControlKind.allCases.map { kind in
            makeCapabilityLocked(displayID: displayID, kind: kind, transport: transport, displayReason: reason)
        }

        return DisplayControlDisplay(
            id: displayID,
            name: Self.displayName(displayID: displayID),
            vendorNumber: Self.vendorNumber(displayID: displayID),
            modelNumber: Self.modelNumber(displayID: displayID),
            serialNumber: Self.serialNumber(displayID: displayID),
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
            isVirtual: Self.isVirtual(displayID: displayID),
            supportsHardwareDDC: transport != nil,
            backendName: transport?.backendName,
            unavailableReason: transport == nil ? reason : nil,
            controls: controls
        )
    }

    private func makeCapabilityLocked(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind,
        transport: DDCTransport?,
        displayReason: String
    ) -> DisplayControlCapability {
        guard Self.isExternalHardwareDisplay(displayID) else {
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
            identity: Self.brightnessMemoryIdentity(displayID: displayID),
            observedValue: observedValue
        )
    }

    private func ensureDisplayOnline(_ displayID: CGDirectDisplayID) throws {
        let online = Self.onlineDisplayIDs()
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

    private static func brightnessMemoryIdentity(
        displayID: CGDirectDisplayID
    ) -> DisplayBrightnessMemoryIdentity? {
        guard let vendorNumber = vendorNumber(displayID: displayID),
              let modelNumber = modelNumber(displayID: displayID),
              let serialNumber = serialNumber(displayID: displayID) else {
            return nil
        }
        return DisplayBrightnessMemoryIdentity(
            vendorNumber: vendorNumber,
            modelNumber: modelNumber,
            serialNumber: serialNumber
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
