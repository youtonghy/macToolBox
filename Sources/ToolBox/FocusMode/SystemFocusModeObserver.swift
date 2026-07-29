import AppKit
import ApplicationServices
import CoreGraphics
import OSLog

enum FocusAXRegistrationDisposition: Equatable {
    case installed
    case recoverable
    case failed
}

enum FocusAXRegistrationPolicy {
    static func classify(_ error: AXError) -> FocusAXRegistrationDisposition {
        switch error {
        case .success, .notificationAlreadyRegistered:
            return .installed
        case .notificationUnsupported:
            return .recoverable
        default:
            return .failed
        }
    }
}

@MainActor
final class SystemFocusModeObserver: FocusModeSystemObserving {
    var onChange: (() -> Void)?

    var snapshot: FocusSystemSnapshot {
        let trusted = Permissions.isAccessibilityTrusted
        let frontmostPID = frontmostApplicationPID
        return FocusSystemSnapshot(
            frontmostApplicationPID: frontmostPID,
            accessibilityTrusted: trusted,
            axFocusedWindowFrame: trusted ? focusedWindowFrame(for: frontmostPID) : nil,
            mouseLocation: NSEvent.mouseLocation,
            isSleeping: isSleeping
        )
    }

    private let ownProcessID: pid_t
    private let workspace: NSWorkspace
    private let logger = Logger(subsystem: "ToolBox", category: "FocusModeObserver")

    private var isRunning = false
    private var isSleeping = false
    private var healthTimer: Timer?
    private var notificationTokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var lastMouseDisplayID: CGDirectDisplayID?
    private var axObserver: AXObserver?
    private var observedApplication: AXUIElement?
    private var observedWindow: AXUIElement?
    private var observedPID: pid_t?
    private var applicationRegistration: FocusAXRegistrationDisposition?
    private var windowRegistrations: [String: FocusAXRegistrationDisposition] = [:]
    private var lastDiagnostic: String?

    init(
        ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
        workspace: NSWorkspace = .shared
    ) {
        self.ownProcessID = ownProcessID
        self.workspace = workspace
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isSleeping = false
        installNotifications()
        installHealthTimer()
        refreshAXObserver()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        healthTimer?.invalidate()
        healthTimer = nil
        for entry in notificationTokens {
            entry.center.removeObserver(entry.token)
        }
        notificationTokens.removeAll()
        removeMouseFallbackMonitoring()
        tearDownAXObserver()
    }

    func requestAccessibilityPermission() {
        _ = Permissions.requestAccessibilityOnce()
        emitChange()
    }

    func openAccessibilitySettings() {
        Permissions.openAccessibilitySettings()
    }

    private var frontmostApplicationPID: pid_t? {
        workspace.frontmostApplication?.processIdentifier
    }

    private func installNotifications() {
        let workspaceCenter = workspace.notificationCenter
        observe(
            center: workspaceCenter,
            name: NSWorkspace.didActivateApplicationNotification
        ) { observer in
            observer.refreshAXObserver()
            observer.emitChange()
        }
        observe(center: workspaceCenter, name: NSWorkspace.willSleepNotification) { observer in
            observer.isSleeping = true
            observer.tearDownAXObserver()
            observer.updateMouseFallbackMonitoring()
            observer.emitChange()
        }
        observe(center: workspaceCenter, name: NSWorkspace.didWakeNotification) { observer in
            observer.isSleeping = false
            observer.refreshAXObserver()
            observer.emitChange()
        }
        observe(
            center: NotificationCenter.default,
            name: NSApplication.didChangeScreenParametersNotification
        ) { observer in
            observer.lastMouseDisplayID = nil
            observer.emitChange()
        }
    }

    private func observe(
        center: NotificationCenter,
        name: Notification.Name,
        handler: @escaping @MainActor (SystemFocusModeObserver) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                handler(self)
            }
        }
        notificationTokens.append((center, token))
    }

    private func installHealthTimer() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, !self.isSleeping else { return }
                self.refreshAXObserver()
                self.emitChange()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func refreshAXObserver() {
        defer { updateMouseFallbackMonitoring() }
        guard isRunning, !isSleeping, Permissions.isAccessibilityTrusted,
              let frontmostPID = frontmostApplicationPID,
              frontmostPID != ownProcessID else {
            tearDownAXObserver()
            return
        }

        if observedPID == frontmostPID, axObserver != nil {
            retryApplicationRegistrationIfNeeded()
            refreshFocusedWindowRegistration()
            return
        }

        tearDownAXObserver()
        var newObserver: AXObserver?
        let createError = AXObserverCreate(frontmostPID, focusModeAXCallback, &newObserver)
        guard createError == .success, let newObserver else {
            logDiagnostic("AXObserverCreate failed: \(createError.rawValue)")
            return
        }

        let application = applicationElement(for: frontmostPID)
        axObserver = newObserver
        observedApplication = application
        observedPID = frontmostPID
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(newObserver),
            .commonModes
        )

        applicationRegistration = register(
            observer: newObserver,
            element: application,
            notification: kAXFocusedWindowChangedNotification
        )
        refreshFocusedWindowRegistration()
    }

    private func refreshFocusedWindowRegistration() {
        guard let observer = axObserver, let application = observedApplication else { return }
        let newWindow = focusedWindow(for: application)
        if let oldWindow = observedWindow, let newWindow, CFEqual(oldWindow, newWindow) {
            retryWindowRegistrationsIfNeeded(observer: observer, window: oldWindow)
            return
        }

        if let oldWindow = observedWindow {
            removeWindowNotifications(observer: observer, window: oldWindow)
        }
        observedWindow = newWindow
        windowRegistrations.removeAll()
        guard let newWindow else { return }

        for notification in Self.windowNotifications {
            windowRegistrations[notification] = register(
                observer: observer,
                element: newWindow,
                notification: notification
            )
        }
    }

    fileprivate func handleAXNotification(_ notification: CFString) {
        guard isRunning else { return }
        if notification == kAXFocusedWindowChangedNotification as CFString {
            refreshFocusedWindowRegistration()
        } else if notification == kAXUIElementDestroyedNotification as CFString {
            // A destroyed AX element must not be passed back to Accessibility APIs.
            observedWindow = nil
            windowRegistrations.removeAll()
            refreshFocusedWindowRegistration()
        }
        updateMouseFallbackMonitoring()
        emitChange()
    }

    private func register(
        observer: AXObserver,
        element: AXUIElement,
        notification: String
    ) -> FocusAXRegistrationDisposition {
        let error = AXObserverAddNotification(
            observer,
            element,
            notification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
        let disposition = FocusAXRegistrationPolicy.classify(error)
        switch disposition {
        case .installed:
            lastDiagnostic = nil
        case .recoverable:
            logDiagnostic("AX notification unsupported: \(notification)", isError: false)
        case .failed:
            logDiagnostic("AX notification registration failed (\(error.rawValue)): \(notification)")
        }
        return disposition
    }

    private func retryApplicationRegistrationIfNeeded() {
        guard applicationRegistration == .failed,
              let observer = axObserver,
              let application = observedApplication else { return }
        applicationRegistration = register(
            observer: observer,
            element: application,
            notification: kAXFocusedWindowChangedNotification
        )
    }

    private func retryWindowRegistrationsIfNeeded(
        observer: AXObserver,
        window: AXUIElement
    ) {
        for notification in Self.windowNotifications
        where windowRegistrations[notification] == .failed {
            windowRegistrations[notification] = register(
                observer: observer,
                element: window,
                notification: notification
            )
        }
    }

    private func tearDownAXObserver() {
        guard let observer = axObserver else {
            observedWindow = nil
            observedApplication = nil
            observedPID = nil
            applicationRegistration = nil
            windowRegistrations.removeAll()
            return
        }

        if let window = observedWindow {
            removeWindowNotifications(observer: observer, window: window)
        }
        if let application = observedApplication {
            remove(
                observer: observer,
                element: application,
                notification: kAXFocusedWindowChangedNotification
            )
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        observedWindow = nil
        observedApplication = nil
        observedPID = nil
        applicationRegistration = nil
        windowRegistrations.removeAll()
        axObserver = nil
    }

    private func removeWindowNotifications(observer: AXObserver, window: AXUIElement) {
        for notification in Self.windowNotifications {
            remove(observer: observer, element: window, notification: notification)
        }
    }

    private func remove(
        observer: AXObserver,
        element: AXUIElement,
        notification: String
    ) {
        let error = AXObserverRemoveNotification(observer, element, notification as CFString)
        guard error != .success,
              error != .notificationNotRegistered,
              error != .invalidUIElement else { return }
        logDiagnostic("AX notification removal failed (\(error.rawValue)): \(notification)")
    }

    private func focusedWindowFrame(for pid: pid_t?) -> CGRect? {
        guard let pid, pid != ownProcessID else { return nil }
        let application = applicationElement(for: pid)
        guard let window = focusedWindow(for: application),
              let position = pointAttribute(kAXPositionAttribute, from: window),
              let size = sizeAttribute(kAXSizeAttribute, from: window),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func applicationElement(for pid: pid_t) -> AXUIElement {
        let application = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        return application
    }

    private func focusedWindow(for application: AXUIElement) -> AXUIElement? {
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &rawWindow
        ) == .success,
        let rawWindow,
        CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return nil }
        return (rawWindow as! AXUIElement)
    }

    private func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let value = rawValue as! AXValue
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let value = rawValue as! AXValue
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func emitChange() {
        onChange?()
    }

    private func updateMouseFallbackMonitoring() {
        guard isRunning, mouseFallbackIsNeeded else {
            removeMouseFallbackMonitoring()
            return
        }
        if globalMouseMonitor == nil, localMouseMonitor == nil {
            lastMouseDisplayID = displayID(at: NSEvent.mouseLocation)
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleMouseMovement()
                }
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleMouseMovement()
                }
                return event
            }
        }
    }

    private var mouseFallbackIsNeeded: Bool {
        guard !isSleeping else { return false }
        guard Permissions.isAccessibilityTrusted else { return true }
        guard let frontmostPID = frontmostApplicationPID else { return true }
        guard frontmostPID != ownProcessID else { return false }
        guard applicationRegistration == .installed, observedWindow != nil else { return true }
        return Self.requiredWindowNotifications.contains {
            windowRegistrations[$0] != .installed
        }
    }

    private func handleMouseMovement() {
        guard isRunning, mouseFallbackIsNeeded else {
            updateMouseFallbackMonitoring()
            return
        }
        let displayID = displayID(at: NSEvent.mouseLocation)
        guard displayID != lastMouseDisplayID else { return }
        lastMouseDisplayID = displayID
        emitChange()
    }

    private func displayID(at point: CGPoint) -> CGDirectDisplayID? {
        FocusScreenProvider.currentScreens().first { $0.frame.contains(point) }?.id
    }

    private func removeMouseFallbackMonitoring() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        lastMouseDisplayID = nil
    }

    private func logDiagnostic(_ message: String, isError: Bool = true) {
        guard message != lastDiagnostic else { return }
        lastDiagnostic = message
        if isError {
            logger.error("\(message, privacy: .public)")
        } else {
            logger.debug("\(message, privacy: .public)")
        }
    }

    private static let windowNotifications = [
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXUIElementDestroyedNotification,
    ]
    private static let requiredWindowNotifications = [
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
    ]
    private static let messagingTimeout: Float = 0.2
}

@MainActor
enum FocusScreenProvider {
    static func currentScreens() -> [FocusScreenGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            return FocusScreenGeometry(
                id: CGDirectDisplayID(number.uint32Value),
                frame: screen.frame
            )
        }
    }
}

private func focusModeAXCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let owner = Unmanaged<SystemFocusModeObserver>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        owner.handleAXNotification(notification)
    }
}
