import Carbon.HIToolbox
import XCTest
@testable import ToolBoxCore

@MainActor
final class ShortcutRegistryTests: XCTestCase {
    func testApplyBeforeStartDoesNotRegisterHotKey() {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)

        XCTAssertThrowsError(try registry.apply(rule: ShortcutRule.defaults[0])) {
            XCTAssertEqual($0 as? ShortcutRegistryError, .notStarted)
        }
        XCTAssertEqual(recorder.activeRegistrationCount, 0)
        XCTAssertTrue(recorder.registerCalls.isEmpty)
    }

    func testEventIDDispatchesOnlyMatchingAction() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        var actions: [ShortcutActionID] = []
        registry.onAction = { actions.append($0) }

        try registry.start(rules: ShortcutRule.defaults)
        XCTAssertEqual(recorder.fire(id: ShortcutActionID.captureRegion.carbonID), noErr)

        XCTAssertEqual(actions, [.captureRegion])
    }

    func testFailedRebindKeepsOldRegistration() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        try registry.start(rules: ShortcutRule.defaults)
        recorder.nextRegisterStatus = OSStatus(eventHotKeyExistsErr)

        XCTAssertThrowsError(try registry.apply(
            rule: .init(
                id: .captureRegion,
                binding: .init(keyCode: 1, modifiers: [.command]),
                isEnabled: true
            )
        ))
        XCTAssertTrue(registry.isRegistered(.captureRegion))
        XCTAssertEqual(
            recorder.activeBinding(id: ShortcutActionID.captureRegion.carbonID),
            ShortcutRule.defaults[0].binding
        )
    }

    func testStartInstallsOneHandlerAndRegistersBothActionsOnce() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)

        try registry.start(rules: ShortcutRule.defaults)
        try registry.start(rules: ShortcutRule.defaults)

        XCTAssertEqual(recorder.installHandlerCalls, 1)
        XCTAssertEqual(recorder.registerCalls.count, 2)
        XCTAssertTrue(registry.isRegistered(.captureRegion))
        XCTAssertTrue(registry.isRegistered(.screenWipeExit))
    }

    func testUnknownEventIDIsNotHandled() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        var actions: [ShortcutActionID] = []
        registry.onAction = { actions.append($0) }
        try registry.start(rules: ShortcutRule.defaults)

        XCTAssertEqual(recorder.fire(id: 9_999), OSStatus(eventNotHandledErr))
        XCTAssertTrue(actions.isEmpty)
    }

    func testEventParameterFailureIsNotHandled() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        try registry.start(rules: ShortcutRule.defaults)
        recorder.nextEventStatus = OSStatus(eventInternalErr)

        XCTAssertEqual(
            recorder.fire(id: ShortcutActionID.captureRegion.carbonID),
            OSStatus(eventNotHandledErr)
        )
    }

    func testForeignEventSignatureIsNotHandled() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        var actions: [ShortcutActionID] = []
        registry.onAction = { actions.append($0) }
        try registry.start(rules: ShortcutRule.defaults)
        recorder.eventSignatureOverride = 0x464F_524E // 'FORN'

        XCTAssertEqual(
            recorder.fire(id: ShortcutActionID.captureRegion.carbonID),
            OSStatus(eventNotHandledErr)
        )
        XCTAssertTrue(actions.isEmpty)
    }

    func testDisabledCaptureUnregistersOnlyCapture() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        try registry.start(rules: ShortcutRule.defaults)
        var capture = ShortcutRule.defaults[0]
        capture.isEnabled = false

        try registry.apply(rule: capture)

        XCTAssertFalse(registry.isRegistered(.captureRegion))
        XCTAssertTrue(registry.isRegistered(.screenWipeExit))
        XCTAssertEqual(recorder.activeRegistrationCount, 1)
    }

    func testProtectedRuleCannotBeDisabled() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        try registry.start(rules: ShortcutRule.defaults)
        var protectedRule = ShortcutRule.defaults[1]
        protectedRule.isEnabled = false

        XCTAssertThrowsError(try registry.apply(rule: protectedRule)) {
            XCTAssertEqual($0 as? ShortcutRegistryError, .protectedRuleDisabled)
        }
        XCTAssertTrue(registry.isRegistered(.screenWipeExit))
    }

    func testStartRejectsIncompleteActionSet() {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        let rules = ShortcutRule.defaults.filter { $0.id != .captureRegion }

        XCTAssertThrowsError(try registry.start(rules: rules)) {
            XCTAssertEqual($0 as? ShortcutRegistryError, .incompleteActionSet)
        }
        XCTAssertEqual(recorder.installHandlerCalls, 0)
    }

    func testSingleRuleApplyRejectsBindingOwnedByAnotherAction() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        try registry.start(rules: ShortcutRule.defaults)
        let capture = ShortcutRule(
            id: .captureRegion,
            binding: ShortcutRule.defaults[1].binding,
            isEnabled: true
        )

        XCTAssertThrowsError(try registry.apply(rule: capture)) {
            XCTAssertEqual($0 as? ShortcutRegistryError, .duplicateBinding)
        }
        XCTAssertEqual(recorder.registerCalls.count, 2)
    }

    func testApplyRuleSetCanSwapBindingsAndKeepsStableIDs() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        try registry.start(rules: ShortcutRule.defaults)
        let swapped = [
            ShortcutRule(
                id: .captureRegion,
                binding: ShortcutRule.defaults[1].binding,
                isEnabled: true
            ),
            ShortcutRule(
                id: .screenWipeExit,
                binding: ShortcutRule.defaults[0].binding,
                isEnabled: true
            ),
        ]

        try registry.apply(rules: swapped)

        XCTAssertEqual(
            recorder.activeBinding(id: ShortcutActionID.captureRegion.carbonID),
            swapped[0].binding
        )
        XCTAssertEqual(
            recorder.activeBinding(id: ShortcutActionID.screenWipeExit.carbonID),
            swapped[1].binding
        )
        XCTAssertEqual(recorder.activeRegistrationCount, 2)
    }

    func testApplyRuleSetRegistrationFailureRestoresPreviousRules() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        try registry.start(rules: ShortcutRule.defaults)
        let proposed = [
            ShortcutRule(
                id: .captureRegion,
                binding: ShortcutBinding(keyCode: 1, modifiers: [.command]),
                isEnabled: true
            ),
            ShortcutRule(
                id: .screenWipeExit,
                binding: ShortcutBinding(keyCode: 2, modifiers: [.command]),
                isEnabled: true
            ),
        ]
        recorder.registerStatusQueue = [noErr, OSStatus(eventHotKeyExistsErr)]

        XCTAssertThrowsError(try registry.apply(rules: proposed)) {
            XCTAssertEqual(
                $0 as? ShortcutRegistryError,
                .registrationFailed(OSStatus(eventHotKeyExistsErr))
            )
        }

        XCTAssertEqual(
            recorder.activeBinding(id: ShortcutActionID.captureRegion.carbonID),
            ShortcutRule.defaults[0].binding
        )
        XCTAssertEqual(
            recorder.activeBinding(id: ShortcutActionID.screenWipeExit.carbonID),
            ShortcutRule.defaults[1].binding
        )
        XCTAssertEqual(recorder.activeRegistrationCount, 2)
    }

    func testApplyRuleSetCleanupFailureDoesNotDispatchProposedAction() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        var actions: [ShortcutActionID] = []
        registry.onAction = { actions.append($0) }
        try registry.start(rules: ShortcutRule.defaults)
        let proposed = [
            ShortcutRule(
                id: .captureRegion,
                binding: ShortcutBinding(keyCode: 1, modifiers: [.command]),
                isEnabled: true
            ),
            ShortcutRule(
                id: .screenWipeExit,
                binding: ShortcutBinding(keyCode: 2, modifiers: [.command]),
                isEnabled: true
            ),
        ]
        recorder.registerStatusQueue = [noErr, OSStatus(eventHotKeyExistsErr)]
        recorder.unregisterStatusQueue = [
            noErr,
            noErr,
            OSStatus(eventInternalErr),
        ]

        XCTAssertThrowsError(try registry.apply(rules: proposed)) {
            XCTAssertEqual(
                $0 as? ShortcutRegistryError,
                .rollbackFailed(OSStatus(eventInternalErr))
            )
        }

        XCTAssertEqual(
            recorder.fire(id: ShortcutActionID.captureRegion.carbonID),
            OSStatus(eventNotHandledErr)
        )
        XCTAssertTrue(actions.isEmpty)
        XCTAssertThrowsError(try registry.apply(rules: ShortcutRule.defaults)) {
            XCTAssertEqual($0 as? ShortcutRegistryError, .cleanupRequired)
        }
    }

    func testApplyRuleSetRestoreFailureDoesNotDispatchPartiallyRestoredAction() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        var actions: [ShortcutActionID] = []
        registry.onAction = { actions.append($0) }
        try registry.start(rules: ShortcutRule.defaults)
        let proposed = [
            ShortcutRule(
                id: .captureRegion,
                binding: ShortcutBinding(keyCode: 1, modifiers: [.command]),
                isEnabled: true
            ),
            ShortcutRule(
                id: .screenWipeExit,
                binding: ShortcutBinding(keyCode: 2, modifiers: [.command]),
                isEnabled: true
            ),
        ]
        recorder.registerStatusQueue = [
            OSStatus(eventHotKeyExistsErr),
            noErr,
            OSStatus(eventHotKeyExistsErr),
        ]

        XCTAssertThrowsError(try registry.apply(rules: proposed)) {
            XCTAssertEqual(
                $0 as? ShortcutRegistryError,
                .rollbackFailed(OSStatus(eventHotKeyExistsErr))
            )
        }

        XCTAssertEqual(
            recorder.fire(id: ShortcutActionID.captureRegion.carbonID),
            OSStatus(eventNotHandledErr)
        )
        XCTAssertTrue(actions.isEmpty)
    }

    func testSuccessfulRebindRoutesTemporaryIDToOriginalAction() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        var actions: [ShortcutActionID] = []
        registry.onAction = { actions.append($0) }
        try registry.start(rules: ShortcutRule.defaults)

        try registry.apply(rule: ShortcutRule(
            id: .captureRegion,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command]),
            isEnabled: true
        ))

        let latestID = try XCTUnwrap(recorder.registerCalls.last?.id)
        XCTAssertNotEqual(latestID, ShortcutActionID.captureRegion.carbonID)
        XCTAssertEqual(recorder.fire(id: latestID), noErr)
        XCTAssertEqual(actions, [.captureRegion])
    }

    func testStopIsIdempotent() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        try registry.start(rules: ShortcutRule.defaults)

        XCTAssertNil(registry.stop())
        XCTAssertNil(registry.stop())

        XCTAssertEqual(recorder.unregisterCalls.count, 2)
        XCTAssertEqual(recorder.removeHandlerCalls, 1)
        XCTAssertEqual(recorder.activeRegistrationCount, 0)
    }

    func testFailedStopDoesNotReportResidualRegistrationAsAvailable() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        try registry.start(rules: ShortcutRule.defaults)
        recorder.unregisterStatusQueue = [OSStatus(eventInternalErr), noErr]

        XCTAssertEqual(registry.stop(), OSStatus(eventInternalErr))

        XCTAssertEqual(recorder.activeRegistrationCount, 1)
        XCTAssertFalse(registry.isRegistered(.captureRegion))
        XCTAssertFalse(registry.isRegistered(.screenWipeExit))
    }

    func testStartAfterStopRestoresEventDispatch() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        var actions: [ShortcutActionID] = []
        registry.onAction = { actions.append($0) }

        try registry.start(rules: ShortcutRule.defaults)
        registry.stop()
        try registry.start(rules: ShortcutRule.defaults)

        XCTAssertEqual(recorder.fire(id: ShortcutActionID.captureRegion.carbonID), noErr)
        XCTAssertEqual(actions, [.captureRegion])
    }

    func testFailedHandlerRemovalCanBeRetriedWithoutInstallingDuplicateHandler() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        try registry.start(rules: ShortcutRule.defaults)
        recorder.nextRemoveHandlerStatus = OSStatus(eventInternalErr)

        XCTAssertEqual(registry.stop(), OSStatus(eventInternalErr))
        XCTAssertThrowsError(try registry.start(rules: ShortcutRule.defaults)) {
            XCTAssertEqual($0 as? ShortcutRegistryError, .cleanupRequired)
        }
        XCTAssertFalse(registry.isRegistered(.captureRegion))

        XCTAssertEqual(recorder.installHandlerCalls, 1)
        XCTAssertEqual(recorder.removeHandlerCalls, 1)

        XCTAssertNil(registry.stop())
        try registry.start(rules: ShortcutRule.defaults)

        XCTAssertEqual(recorder.removeHandlerCalls, 2)
        XCTAssertEqual(recorder.installHandlerCalls, 2)
    }

    func testHandlerInstallFailureCanBeRetried() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        recorder.installStatusQueue = [OSStatus(eventInternalErr), noErr]

        XCTAssertThrowsError(try registry.start(rules: ShortcutRule.defaults)) {
            XCTAssertEqual(
                $0 as? ShortcutRegistryError,
                .handlerInstallFailed(OSStatus(eventInternalErr))
            )
        }
        try registry.start(rules: ShortcutRule.defaults)

        XCTAssertEqual(recorder.installHandlerCalls, 2)
        XCTAssertEqual(recorder.activeRegistrationCount, 2)
    }

    func testPartialStartFailureRollsBackAndCanBeRetried() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        recorder.registerStatusQueue = [noErr, OSStatus(eventHotKeyExistsErr)]

        XCTAssertThrowsError(try registry.start(rules: ShortcutRule.defaults))
        XCTAssertEqual(recorder.activeRegistrationCount, 0)
        XCTAssertEqual(recorder.removeHandlerCalls, 1)

        try registry.start(rules: ShortcutRule.defaults)
        XCTAssertEqual(recorder.activeRegistrationCount, 2)
        XCTAssertEqual(recorder.installHandlerCalls, 2)
    }

    func testPartialStartRollbackFailureRequiresCleanupBeforeRestart() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        recorder.registerStatusQueue = [noErr, OSStatus(eventHotKeyExistsErr)]
        recorder.unregisterStatusQueue = [OSStatus(eventInternalErr)]

        XCTAssertThrowsError(try registry.start(rules: ShortcutRule.defaults)) {
            XCTAssertEqual(
                $0 as? ShortcutRegistryError,
                .rollbackFailed(OSStatus(eventInternalErr))
            )
        }
        XCTAssertFalse(registry.isRegistered(.captureRegion))
        XCTAssertThrowsError(try registry.start(rules: ShortcutRule.defaults)) {
            XCTAssertEqual($0 as? ShortcutRegistryError, .cleanupRequired)
        }

        registry.stop()
        try registry.start(rules: ShortcutRule.defaults)
        XCTAssertEqual(recorder.activeRegistrationCount, 2)
        XCTAssertTrue(registry.isRegistered(.captureRegion))
        XCTAssertTrue(registry.isRegistered(.screenWipeExit))
    }

    func testOldUnregistrationFailureKeepsOldBinding() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        try registry.start(rules: ShortcutRule.defaults)
        recorder.unregisterStatusQueue = [OSStatus(eventInternalErr), noErr]

        XCTAssertThrowsError(try registry.apply(rule: ShortcutRule(
            id: .captureRegion,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command]),
            isEnabled: true
        ))) {
            XCTAssertEqual(
                $0 as? ShortcutRegistryError,
                .unregistrationFailed(OSStatus(eventInternalErr))
            )
        }

        XCTAssertEqual(
            recorder.activeBinding(id: ShortcutActionID.captureRegion.carbonID),
            ShortcutRule.defaults[0].binding
        )
        XCTAssertEqual(recorder.activeRegistrationCount, 2)
    }

    func testRollbackFailureDoesNotDispatchReplacementAction() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        var actions: [ShortcutActionID] = []
        registry.onAction = { actions.append($0) }
        try registry.start(rules: ShortcutRule.defaults)
        recorder.unregisterStatusQueue = [
            OSStatus(eventInternalErr),
            OSStatus(eventInternalErr),
        ]

        XCTAssertThrowsError(try registry.apply(rule: ShortcutRule(
            id: .captureRegion,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command]),
            isEnabled: true
        ))) {
            XCTAssertEqual(
                $0 as? ShortcutRegistryError,
                .rollbackFailed(OSStatus(eventInternalErr))
            )
        }

        let temporaryID = try XCTUnwrap(recorder.registerCalls.last?.id)
        XCTAssertEqual(recorder.fire(id: temporaryID), OSStatus(eventNotHandledErr))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(
            recorder.activeBinding(id: ShortcutActionID.captureRegion.carbonID),
            ShortcutRule.defaults[0].binding
        )
    }

    func testDeinitCleansUpRegistrationsAndHandler() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        weak var weakRegistry: ShortcutRegistry?

        do {
            let registry = ShortcutRegistry(system: recorder.system)
            weakRegistry = registry
            try registry.start(rules: ShortcutRule.defaults)
        }

        XCTAssertNil(weakRegistry)
        XCTAssertEqual(recorder.unregisterCalls.count, 2)
        XCTAssertEqual(recorder.removeHandlerCalls, 1)
    }
}

private final class ShortcutCarbonSystemRecorder {
    struct RegisterCall {
        let binding: ShortcutBinding
        let signature: OSType
        let id: UInt32
        let ref: EventHotKeyRef
    }

    let handlerRef = EventHandlerRef(bitPattern: 1)!
    private var callbackContext: UnsafeMutableRawPointer?
    private var nextRefValue = 100
    private var nextEventID: UInt32 = 0
    private var active: [EventHotKeyRef: RegisterCall] = [:]

    var nextRegisterStatus: OSStatus = noErr
    var nextRemoveHandlerStatus: OSStatus = noErr
    var installStatusQueue: [OSStatus] = []
    var registerStatusQueue: [OSStatus] = []
    var unregisterStatusQueue: [OSStatus] = []
    var nextEventStatus: OSStatus = noErr
    var eventSignatureOverride: OSType?
    private(set) var installHandlerCalls = 0
    private(set) var removeHandlerCalls = 0
    private(set) var registerCalls: [RegisterCall] = []
    private(set) var unregisterCalls: [EventHotKeyRef] = []

    var activeRegistrationCount: Int {
        active.count
    }

    lazy var system = ShortcutCarbonSystem(
        installHandler: { [unowned self] context, output in
            installHandlerCalls += 1
            let status = installStatusQueue.isEmpty
                ? noErr
                : installStatusQueue.removeFirst()
            guard status == noErr else { return status }
            callbackContext = context
            output.pointee = handlerRef
            return noErr
        },
        removeHandler: { [unowned self] _ in
            removeHandlerCalls += 1
            let status = nextRemoveHandlerStatus
            nextRemoveHandlerStatus = noErr
            if status == noErr {
                callbackContext = nil
            }
            return status
        },
        registerHotKey: { [unowned self] keyCode, modifiers, hotKeyID, output in
            let status = registerStatusQueue.isEmpty
                ? nextRegisterStatus
                : registerStatusQueue.removeFirst()
            nextRegisterStatus = noErr
            guard status == noErr else { return status }

            let binding = ShortcutBinding(
                keyCode: keyCode,
                modifiers: ShortcutModifiers(rawValue: modifiers)
            )
            guard !active.values.contains(where: { $0.binding == binding }) else {
                return OSStatus(eventHotKeyExistsErr)
            }

            let ref = EventHotKeyRef(bitPattern: nextRefValue)!
            nextRefValue += 1
            let call = RegisterCall(
                binding: binding,
                signature: hotKeyID.signature,
                id: hotKeyID.id,
                ref: ref
            )
            registerCalls.append(call)
            active[ref] = call
            output.pointee = ref
            return noErr
        },
        unregisterHotKey: { [unowned self] ref in
            unregisterCalls.append(ref)
            let status = unregisterStatusQueue.isEmpty
                ? noErr
                : unregisterStatusQueue.removeFirst()
            guard status == noErr else { return status }
            active.removeValue(forKey: ref)
            return noErr
        },
        eventHotKeyID: { [unowned self] _, output in
            let status = nextEventStatus
            nextEventStatus = noErr
            guard status == noErr else { return status }
            let signature = eventSignatureOverride
                ?? registerCalls.first?.signature
                ?? 0
            output.pointee = EventHotKeyID(signature: signature, id: nextEventID)
            return noErr
        }
    )

    func fire(id: UInt32) -> OSStatus {
        nextEventID = id
        guard let callbackContext else {
            return OSStatus(eventNotHandledErr)
        }
        let context = Unmanaged<ShortcutRegistryCallbackContext>
            .fromOpaque(callbackContext)
            .takeUnretainedValue()
        return context.handle(event: EventRef(bitPattern: 1))
    }

    func activeBinding(id: UInt32) -> ShortcutBinding? {
        active.values.first(where: { $0.id == id })?.binding
    }
}
