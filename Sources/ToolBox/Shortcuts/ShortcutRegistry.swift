import Carbon.HIToolbox
import OSLog

final class ShortcutRegistryCallbackContext {
    var onEvent: (@MainActor (EventRef?) -> OSStatus)?

    func handle(event: EventRef?) -> OSStatus {
        MainActor.assumeIsolated {
            onEvent?(event) ?? OSStatus(eventNotHandledErr)
        }
    }
}

private let shortcutRegistryEventHandler: EventHandlerUPP = { _, event, context in
    guard let context else {
        return OSStatus(eventNotHandledErr)
    }
    let callbackContext = Unmanaged<ShortcutRegistryCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    return callbackContext.handle(event: event)
}

struct ShortcutCarbonSystem {
    let installHandler: (
        _ context: UnsafeMutableRawPointer,
        _ output: UnsafeMutablePointer<EventHandlerRef?>
    ) -> OSStatus
    let removeHandler: (EventHandlerRef) -> OSStatus
    let registerHotKey: (
        _ keyCode: UInt32,
        _ modifiers: UInt32,
        _ hotKeyID: EventHotKeyID,
        _ output: UnsafeMutablePointer<EventHotKeyRef?>
    ) -> OSStatus
    let unregisterHotKey: (EventHotKeyRef) -> OSStatus
    let eventHotKeyID: (
        _ event: EventRef,
        _ output: UnsafeMutablePointer<EventHotKeyID>
    ) -> OSStatus

    static let live = ShortcutCarbonSystem(
        installHandler: { context, output in
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            return InstallEventHandler(
                GetApplicationEventTarget(),
                shortcutRegistryEventHandler,
                1,
                &eventType,
                context,
                output
            )
        },
        removeHandler: RemoveEventHandler,
        registerHotKey: { keyCode, modifiers, hotKeyID, output in
            RegisterEventHotKey(
                keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                output
            )
        },
        unregisterHotKey: UnregisterEventHotKey,
        eventHotKeyID: { event, output in
            var actualSize = 0
            return GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                &actualSize,
                output
            )
        }
    )
}

enum ShortcutRegistryError: Error, Equatable {
    case notStarted
    case cleanupRequired
    case emptyModifiers
    case duplicateActionID
    case duplicateBinding
    case protectedRuleMissing
    case protectedRuleDisabled
    case incompleteActionSet
    case handlerInstallFailed(OSStatus)
    case registrationFailed(OSStatus)
    case unregistrationFailed(OSStatus)
    case rollbackFailed(OSStatus)
}

extension ShortcutActionID {
    var carbonID: UInt32 {
        switch self {
        case .captureRegion:
            1
        case .screenWipeExit:
            2
        }
    }
}

@MainActor
final class ShortcutRegistry {
    private struct Registration {
        let action: ShortcutActionID
        let binding: ShortcutBinding
        let carbonID: UInt32
        let ref: EventHotKeyRef
    }

    private let logger = Logger(subsystem: "ToolBox", category: "ShortcutRegistry")
    private let system: ShortcutCarbonSystem
    private let mediaKeyBackend: any ShortcutMediaKeyRoutingBackend
    let permissions: ShortcutPermissionCenter
    private let callbackContext = ShortcutRegistryCallbackContext()
    private var retainedCallbackContext: Unmanaged<ShortcutRegistryCallbackContext>?
    private var handlerRef: EventHandlerRef?
    private var isStarted = false
    private var configuredRules: [ShortcutActionID: ShortcutRule] = [:]
    private var registrations: [ShortcutActionID: Registration] = [:]
    private var rollbackRegistrations: [Registration] = []
    private var idToAction: [UInt32: ShortcutActionID] = [:]
    private var nextTemporaryID: UInt32 = 0x8000_0000
    private var mediaKeyRoutingRequested = false

    var onAction: ((ShortcutActionID) -> Void)?
    var onRoutedAction: ((ShortcutAction) -> Bool)?

    init(
        system: ShortcutCarbonSystem = .live,
        mediaKeyBackend: (any ShortcutMediaKeyRoutingBackend)? = nil,
        permissions: ShortcutPermissionCenter? = nil
    ) {
        self.system = system
        self.mediaKeyBackend = mediaKeyBackend ?? LiveShortcutMediaKeyRoutingBackend()
        self.permissions = permissions ?? ShortcutPermissionCenter()
    }

    func start(rules: [ShortcutRule]) throws {
        guard !isStarted else { return }
        guard handlerRef == nil else {
            throw ShortcutRegistryError.cleanupRequired
        }
        try validate(rules: rules)

        callbackContext.onEvent = { [unowned self] event in
            handle(event: event)
        }

        let retainedContext = Unmanaged.passRetained(callbackContext)
        var installedHandler: EventHandlerRef?
        let installStatus = system.installHandler(
            retainedContext.toOpaque(),
            &installedHandler
        )
        guard installStatus == noErr, let installedHandler else {
            retainedContext.release()
            throw ShortcutRegistryError.handlerInstallFailed(installStatus)
        }

        handlerRef = installedHandler
        retainedCallbackContext = retainedContext

        do {
            for rule in rules where rule.isEnabled {
                let registration = try register(
                    action: rule.id,
                    binding: rule.binding,
                    carbonID: rule.id.carbonID
                )
                registrations[rule.id] = registration
                idToAction[registration.carbonID] = rule.id
            }
            configuredRules = Self.ruleMap(rules)
            isStarted = true
            mediaKeyBackend.onEvent = { [weak self] event in
                self?.onRoutedAction?(.mediaKey(event)) ?? false
            }
            permissions.onApplicationDidBecomeActive = { [weak self] in
                self?.retryMediaKeyRouteIfNeeded()
            }
            permissions.start()
            startMediaKeyRouteIfNeeded()
        } catch {
            if let cleanupStatus = cleanup() {
                throw ShortcutRegistryError.rollbackFailed(cleanupStatus)
            }
            throw error
        }
    }

    @discardableResult
    func stop() -> OSStatus? {
        cleanup()
    }

    private func cleanup() -> OSStatus? {
        stopMediaKeyRoute(clearRequest: true)
        permissions.stop()
        isStarted = false
        var firstFailure: OSStatus?

        for (action, registration) in Array(registrations) {
            let status = system.unregisterHotKey(registration.ref)
            if status == noErr {
                registrations.removeValue(forKey: action)
                idToAction.removeValue(forKey: registration.carbonID)
            } else {
                idToAction.removeValue(forKey: registration.carbonID)
                firstFailure = firstFailure ?? status
                logger.error("Failed to unregister shortcut \(action.rawValue, privacy: .public)")
            }
        }

        for registration in Array(rollbackRegistrations) {
            let status = system.unregisterHotKey(registration.ref)
            if status == noErr {
                rollbackRegistrations.removeAll { $0.ref == registration.ref }
                idToAction.removeValue(forKey: registration.carbonID)
            } else {
                firstFailure = firstFailure ?? status
                logger.error("Failed to unregister rollback shortcut")
            }
        }

        guard firstFailure == nil, let handlerRef else { return firstFailure }
        let status = system.removeHandler(handlerRef)
        guard status == noErr else {
            logger.error("Failed to remove shortcut event handler")
            return status
        }

        callbackContext.onEvent = nil
        self.handlerRef = nil
        configuredRules = [:]
        retainedCallbackContext?.release()
        retainedCallbackContext = nil
        return nil
    }

    func apply(rule: ShortcutRule) throws {
        try requireStarted()
        guard configuredRules[rule.id] != nil else {
            throw ShortcutRegistryError.incompleteActionSet
        }
        var proposed = ShortcutActionID.allCases.compactMap { configuredRules[$0] }
        guard let index = proposed.firstIndex(where: { $0.id == rule.id }) else {
            throw ShortcutRegistryError.incompleteActionSet
        }
        proposed[index] = rule
        try validate(rules: proposed)
        try applyValidated(rule: rule)
        configuredRules[rule.id] = rule
    }

    func apply(rules: [ShortcutRule]) throws {
        try requireStarted()
        try validate(rules: rules)

        let proposedRules = Self.ruleMap(rules)
        guard proposedRules != configuredRules else { return }
        let changedActions = ShortcutActionID.allCases.filter {
            proposedRules[$0] != configuredRules[$0]
        }

        if changedActions.count == 1,
           let action = changedActions.first,
           let rule = proposedRules[action] {
            try applyValidated(rule: rule)
            configuredRules = proposedRules
            return
        }

        try replaceAllRegistrations(with: rules, proposedRules: proposedRules)
    }

    private func applyValidated(rule: ShortcutRule) throws {
        guard rule.isEnabled else {
            try unregister(action: rule.id)
            return
        }

        guard let current = registrations[rule.id] else {
            let registration = try register(
                action: rule.id,
                binding: rule.binding,
                carbonID: rule.id.carbonID
            )
            registrations[rule.id] = registration
            idToAction[registration.carbonID] = rule.id
            return
        }

        guard current.binding != rule.binding else { return }

        let temporaryID = allocateTemporaryID()
        let replacement = try register(
            action: rule.id,
            binding: rule.binding,
            carbonID: temporaryID
        )

        let unregisterStatus = system.unregisterHotKey(current.ref)
        guard unregisterStatus == noErr else {
            let rollbackStatus = system.unregisterHotKey(replacement.ref)
            if rollbackStatus != noErr {
                rollbackRegistrations.append(replacement)
                isStarted = false
                throw ShortcutRegistryError.rollbackFailed(rollbackStatus)
            }
            throw ShortcutRegistryError.unregistrationFailed(unregisterStatus)
        }

        idToAction.removeValue(forKey: current.carbonID)
        registrations[rule.id] = replacement
        idToAction[replacement.carbonID] = rule.id
    }

    private func replaceAllRegistrations(
        with rules: [ShortcutRule],
        proposedRules: [ShortcutActionID: ShortcutRule]
    ) throws {
        let previousRules = configuredRules
        let previousRegistrations = ShortcutActionID.allCases.compactMap { registrations[$0] }
        var removedRegistrations: [Registration] = []

        for registration in previousRegistrations {
            let status = system.unregisterHotKey(registration.ref)
            guard status == noErr else {
                if let rollbackStatus = restore(registrations: removedRegistrations) {
                    isStarted = false
                    throw ShortcutRegistryError.rollbackFailed(rollbackStatus)
                }
                throw ShortcutRegistryError.unregistrationFailed(status)
            }
            registrations.removeValue(forKey: registration.action)
            idToAction.removeValue(forKey: registration.carbonID)
            removedRegistrations.append(registration)
        }

        do {
            for rule in rules where rule.isEnabled {
                let registration = try register(
                    action: rule.id,
                    binding: rule.binding,
                    carbonID: rule.id.carbonID
                )
                registrations[rule.id] = registration
                idToAction[registration.carbonID] = rule.id
            }
            configuredRules = proposedRules
        } catch {
            if let cleanupStatus = unregisterCurrentRegistrations() {
                configuredRules = previousRules
                isStarted = false
                throw ShortcutRegistryError.rollbackFailed(cleanupStatus)
            }
            if let rollbackStatus = restore(registrations: previousRegistrations) {
                configuredRules = previousRules
                isStarted = false
                throw ShortcutRegistryError.rollbackFailed(rollbackStatus)
            }
            configuredRules = previousRules
            throw error
        }
    }

    private func restore(registrations snapshots: [Registration]) -> OSStatus? {
        for snapshot in snapshots {
            do {
                let registration = try register(
                    action: snapshot.action,
                    binding: snapshot.binding,
                    carbonID: snapshot.carbonID
                )
                registrations[snapshot.action] = registration
                idToAction[registration.carbonID] = registration.action
            } catch ShortcutRegistryError.registrationFailed(let status) {
                return status
            } catch {
                return OSStatus(eventInternalErr)
            }
        }
        return nil
    }

    private func unregisterCurrentRegistrations() -> OSStatus? {
        var firstFailure: OSStatus?
        for action in ShortcutActionID.allCases {
            guard let registration = registrations[action] else { continue }
            let status = system.unregisterHotKey(registration.ref)
            if status == noErr {
                registrations.removeValue(forKey: action)
                idToAction.removeValue(forKey: registration.carbonID)
            } else {
                idToAction.removeValue(forKey: registration.carbonID)
                firstFailure = firstFailure ?? status
            }
        }
        return firstFailure
    }

    func isRegistered(_ action: ShortcutActionID) -> Bool {
        guard isStarted, let registration = registrations[action] else {
            return false
        }
        return idToAction[registration.carbonID] == action
    }

    func setMediaKeyRoutingEnabled(_ enabled: Bool) {
        guard mediaKeyRoutingRequested != enabled else {
            if enabled {
                startMediaKeyRouteIfNeeded()
            }
            return
        }
        mediaKeyRoutingRequested = enabled
        if enabled {
            startMediaKeyRouteIfNeeded()
        } else {
            stopMediaKeyRoute(clearRequest: false)
        }
    }

    func refreshMediaKeyRoute(promptIfNeeded: Bool) {
        permissions.refresh()
        if promptIfNeeded {
            permissions.openMediaKeyPermissionSettings()
        }
        retryMediaKeyRouteIfNeeded()
    }

    private func retryMediaKeyRouteIfNeeded() {
        guard isStarted, mediaKeyRoutingRequested else { return }
        mediaKeyBackend.stop()
        startMediaKeyRouteIfNeeded()
    }

    private func startMediaKeyRouteIfNeeded() {
        guard isStarted, mediaKeyRoutingRequested else {
            permissions.updateMediaKeyRoute(
                requested: mediaKeyRoutingRequested,
                active: false,
                listenOnlyTapAvailable: nil
            )
            return
        }
        guard !mediaKeyBackend.isActive else {
            permissions.updateMediaKeyRoute(
                requested: true,
                active: true,
                listenOnlyTapAvailable: nil
            )
            return
        }

        mediaKeyBackend.onEvent = { [weak self] event in
            self?.onRoutedAction?(.mediaKey(event)) ?? false
        }
        permissions.quietlyRegisterMediaKeyPermissions()
        let active = mediaKeyBackend.start()
        let listenOnly = active ? nil : mediaKeyBackend.canCreateListenOnlyTap()
        permissions.refresh()
        permissions.updateMediaKeyRoute(
            requested: true,
            active: active,
            listenOnlyTapAvailable: listenOnly
        )
        if active {
            logger.info("Shared media-key route started")
        } else {
            logger.error(
                "Failed to start shared media-key route. gap=\(String(describing: self.permissions.snapshot.mediaKeyPermissionGap), privacy: .public)"
            )
        }
    }

    private func stopMediaKeyRoute(clearRequest: Bool) {
        mediaKeyBackend.stop()
        if clearRequest {
            mediaKeyRoutingRequested = false
            mediaKeyBackend.onEvent = nil
        }
        permissions.updateMediaKeyRoute(
            requested: mediaKeyRoutingRequested,
            active: false,
            listenOnlyTapAvailable: nil
        )
    }

    private func validate(rules: [ShortcutRule]) throws {
        guard let error = ShortcutRuleStore.validationError(for: rules) else { return }
        switch error {
        case .emptyModifiers:
            throw ShortcutRegistryError.emptyModifiers
        case .duplicateActionID:
            throw ShortcutRegistryError.duplicateActionID
        case .duplicateBinding:
            throw ShortcutRegistryError.duplicateBinding
        case .protectedRuleMissing:
            throw ShortcutRegistryError.protectedRuleMissing
        case .protectedRuleDisabled:
            throw ShortcutRegistryError.protectedRuleDisabled
        case .incompleteActionSet:
            throw ShortcutRegistryError.incompleteActionSet
        }
    }

    private func requireStarted() throws {
        guard isStarted else {
            throw handlerRef == nil
                ? ShortcutRegistryError.notStarted
                : ShortcutRegistryError.cleanupRequired
        }
    }

    private func register(
        action: ShortcutActionID,
        binding: ShortcutBinding,
        carbonID: UInt32
    ) throws -> Registration {
        var ref: EventHotKeyRef?
        let status = system.registerHotKey(
            binding.keyCode,
            binding.modifiers.rawValue,
            EventHotKeyID(signature: Self.signature, id: carbonID),
            &ref
        )
        guard status == noErr, let ref else {
            throw ShortcutRegistryError.registrationFailed(status)
        }
        return Registration(
            action: action,
            binding: binding,
            carbonID: carbonID,
            ref: ref
        )
    }

    private func unregister(action: ShortcutActionID) throws {
        guard let registration = registrations[action] else { return }
        let status = system.unregisterHotKey(registration.ref)
        guard status == noErr else {
            throw ShortcutRegistryError.unregistrationFailed(status)
        }
        registrations.removeValue(forKey: action)
        idToAction.removeValue(forKey: registration.carbonID)
    }

    private func allocateTemporaryID() -> UInt32 {
        while idToAction[nextTemporaryID] != nil
            || ShortcutActionID.allCases.contains(where: { $0.carbonID == nextTemporaryID }) {
            nextTemporaryID &+= 1
        }
        defer { nextTemporaryID &+= 1 }
        return nextTemporaryID
    }

    private func handle(event: EventRef?) -> OSStatus {
        guard isStarted else {
            return OSStatus(eventNotHandledErr)
        }
        guard let event else {
            return OSStatus(eventNotHandledErr)
        }
        var hotKeyID = EventHotKeyID()
        guard system.eventHotKeyID(event, &hotKeyID) == noErr,
              hotKeyID.signature == Self.signature,
              let action = idToAction[hotKeyID.id] else {
            return OSStatus(eventNotHandledErr)
        }
        _ = onRoutedAction?(.hotKey(action))
        onAction?(action)
        return noErr
    }

    private static let signature: OSType = 0x5442_5343 // 'TBSC'

    private static func ruleMap(
        _ rules: [ShortcutRule]
    ) -> [ShortcutActionID: ShortcutRule] {
        Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
    }

    deinit {
        onAction = nil
        onRoutedAction = nil
        callbackContext.onEvent = nil
        for registration in registrations.values {
            if system.unregisterHotKey(registration.ref) != noErr {
                logger.error(
                    "Failed to unregister shortcut during deinitialization: \(registration.action.rawValue, privacy: .public)"
                )
            }
        }
        for registration in rollbackRegistrations {
            if system.unregisterHotKey(registration.ref) != noErr {
                logger.error("Failed to unregister rollback shortcut during deinitialization")
            }
        }
        if let handlerRef {
            let status = system.removeHandler(handlerRef)
            if status == noErr {
                retainedCallbackContext?.release()
            } else {
                logger.error("Failed to remove shortcut event handler during deinitialization")
            }
        }
        retainedCallbackContext = nil
    }
}
