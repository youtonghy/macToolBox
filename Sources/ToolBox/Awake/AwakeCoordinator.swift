import Foundation
import IOKit.pwr_mgt

/// F2 — 后台干: keeps the system awake so background apps keep running, while ALLOWING the
/// display to sleep (we deliberately do NOT hold a display-sleep assertion).
///
/// Two mechanisms, combined:
/// - `PreventUserIdleSystemSleep` IOKit assertion: prevents *idle* system sleep.
/// - `caffeinate -s` subprocess: on AC power this additionally prevents clamshell
///   (lid-close) sleep, which the plain assertion cannot do. (Battery: lid-close may still sleep.)
final class AwakeCoordinator {

    enum StartError: LocalizedError {
        case assertionCreationFailed(Int32)

        var errorDescription: String? {
            switch self {
            case let .assertionCreationFailed(result):
                return "无法创建防休眠系统断言（IOKit 错误码：\(result)）。"
            }
        }
    }

    private var assertionID: IOPMAssertionID = 0
    private var caffeinate: Process?
    private(set) var isEnabled = false
    private(set) var caffeinateError: String?

    @discardableResult
    func start() throws -> String? {
        guard assertionID == 0 else { return caffeinateError }

        let result = IOPMAssertionCreateWithDescription(
            "PreventUserIdleSystemSleep" as CFString,
            "ToolBox 后台干" as CFString,
            nil,
            "Keep the system awake for background work" as CFString,
            Bundle.main.bundlePath as CFString,
            0,     // no timeout
            nil,   // default timeout action (TurnOff)
            &assertionID)
        if result != 0 { // kIOReturnSuccess == 0 (macro not Swift-importable)
            assertionID = 0
            isEnabled = false
            throw StartError.assertionCreationFailed(result)
        }
        isEnabled = true
        caffeinateError = nil

        // The IOKit assertion remains authoritative when caffeinate is unavailable.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        proc.arguments = ["-s"]
        do {
            try proc.run()
            caffeinate = proc
        } catch {
            caffeinate = nil
            caffeinateError = error.localizedDescription
        }
        return caffeinateError
    }

    func stop() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        if let proc = caffeinate {
            proc.terminate()
            caffeinate = nil
        }
        caffeinateError = nil
        isEnabled = false
    }

    deinit { stop() }
}
