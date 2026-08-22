import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ToolBoxCore

@MainActor
final class ShortcutInputRoutingTests: XCTestCase {
    func testExternalDisplayDoesNotAutomaticallyEnableMediaKeyInterception() throws {
        let carbon = ShortcutCarbonSystemRecorderForRouting()
        let mediaKeys = ShortcutMediaKeyBackendRecorder()
        let registry = ShortcutRegistry(
            system: carbon.system,
            mediaKeyBackend: mediaKeys,
            permissions: ShortcutPermissionCenter(system: .allDenied)
        )
        let service = DisplayControlService(
            provider: RecordingDisplayControlProvider(),
            observesSystemEvents: false
        )
        service.setSnapshotForTesting(DisplayControlSnapshot(
            timestamp: Date(),
            displays: [
                DisplayControlDisplay(
                    id: 42,
                    name: "External Display",
                    vendorNumber: nil,
                    modelNumber: nil,
                    serialNumber: nil,
                    isBuiltIn: false,
                    isVirtual: false,
                    supportsHardwareDDC: true,
                    backendName: "Test DDC",
                    unavailableReason: nil,
                    controls: []
                ),
            ]
        ))
        let menuModel = DisplayControlMenuModel(service: service)
        let controller = DisplayControlMediaKeyController(
            service: service,
            menuModel: menuModel,
            shortcutRegistry: registry
        )

        try registry.start(rules: ShortcutRule.defaults)
        menuModel.start()
        controller.start()

        XCTAssertEqual(mediaKeys.startCalls, 0)

        controller.stop()
        menuModel.stop()
        registry.stop()
    }

    func testRegistryOwnsOneMediaKeyBackendAndUsesTheSharedActionDispatcher() throws {
        let carbon = ShortcutCarbonSystemRecorderForRouting()
        let mediaKeys = ShortcutMediaKeyBackendRecorder()
        let permissions = ShortcutPermissionCenter(system: .allDenied)
        let registry = ShortcutRegistry(
            system: carbon.system,
            mediaKeyBackend: mediaKeys,
            permissions: permissions
        )
        var actions: [ShortcutAction] = []
        registry.onRoutedAction = { action in
            actions.append(action)
            return true
        }

        try registry.start(rules: ShortcutRule.defaults)
        registry.setMediaKeyRoutingEnabled(true)
        registry.setMediaKeyRoutingEnabled(true)

        XCTAssertEqual(mediaKeys.startCalls, 1)
        XCTAssertTrue(mediaKeys.fire(.brightnessUp, isPressed: true))
        XCTAssertEqual(actions, [.mediaKey(.init(key: .brightnessUp, isPressed: true, isRepeat: false))])

        registry.setMediaKeyRoutingEnabled(false)
        XCTAssertEqual(mediaKeys.stopCalls, 1)

        registry.setMediaKeyRoutingEnabled(true)
        XCTAssertEqual(mediaKeys.startCalls, 2)
        XCTAssertTrue(mediaKeys.fire(.soundDown, isPressed: true))
        XCTAssertEqual(
            actions.last,
            .mediaKey(.init(key: .soundDown, isPressed: true, isRepeat: false))
        )
    }

    func testPermissionSnapshotSeparatesAccessibilityTrustFromMediaKeyOperation() {
        let permissions = ShortcutPermissionCenter(
            system: ShortcutPermissionSystem(
                accessibilityTrusted: { true },
                inputMonitoringStatus: { .granted },
                screenCaptureTrusted: { true },
                canPostEvents: { true },
                requestAccessibility: { true },
                openAccessibilitySettings: {},
                registerInputMonitoring: { true },
                openMediaKeySettings: { _ in }
            )
        )

        permissions.refresh()

        XCTAssertTrue(permissions.snapshot.accessibilityTrusted)
        XCTAssertFalse(permissions.snapshot.mediaKeyRouteActive)
        XCTAssertEqual(permissions.snapshot.mediaKeyPermissionGap, .none)
    }

    func testAccessibilityRequestPromptsOnlyOnceBeforeOpeningSettings() {
        var promptCalls = 0
        var settingsCalls = 0
        let permissions = ShortcutPermissionCenter(
            system: ShortcutPermissionSystem(
                accessibilityTrusted: { false },
                inputMonitoringStatus: { .denied },
                screenCaptureTrusted: { false },
                canPostEvents: { false },
                requestAccessibility: {
                    promptCalls += 1
                    return false
                },
                openAccessibilitySettings: { settingsCalls += 1 },
                registerInputMonitoring: { false },
                openMediaKeySettings: { _ in }
            )
        )

        permissions.requestAccessibility()

        XCTAssertEqual(promptCalls, 1)
        XCTAssertEqual(settingsCalls, 1)
    }

    func testApplicationActivationRefreshesTheSharedPermissionSnapshot() {
        var accessibilityTrusted = false
        let notificationCenter = NotificationCenter()
        let permissions = ShortcutPermissionCenter(
            system: ShortcutPermissionSystem(
                accessibilityTrusted: { accessibilityTrusted },
                inputMonitoringStatus: { .denied },
                screenCaptureTrusted: { false },
                canPostEvents: { false },
                requestAccessibility: { false },
                openAccessibilitySettings: {},
                registerInputMonitoring: { false },
                openMediaKeySettings: { _ in }
            ),
            notificationCenter: notificationCenter
        )
        permissions.start()
        XCTAssertFalse(permissions.snapshot.accessibilityTrusted)

        accessibilityTrusted = true
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertTrue(permissions.snapshot.accessibilityTrusted)
    }
}

@MainActor
private final class ShortcutMediaKeyBackendRecorder: ShortcutMediaKeyRoutingBackend {
    var onEvent: ((ShortcutMediaKeyEvent) -> Bool)?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    var isActive = false

    func start() -> Bool {
        startCalls += 1
        isActive = true
        return true
    }

    func stop() {
        guard isActive else { return }
        stopCalls += 1
        isActive = false
    }

    func canCreateListenOnlyTap() -> Bool {
        true
    }

    func fire(
        _ key: ShortcutMediaKey,
        isPressed: Bool,
        isRepeat: Bool = false
    ) -> Bool {
        onEvent?(.init(key: key, isPressed: isPressed, isRepeat: isRepeat)) ?? false
    }
}

private final class ShortcutCarbonSystemRecorderForRouting {
    private let handlerRef = EventHandlerRef(bitPattern: 1)!
    private var nextRef = 100

    lazy var system = ShortcutCarbonSystem(
        installHandler: { [unowned self] _, output in
            output.pointee = handlerRef
            return noErr
        },
        removeHandler: { _ in noErr },
        registerHotKey: { [unowned self] _, _, _, output in
            output.pointee = EventHotKeyRef(bitPattern: nextRef)
            nextRef += 1
            return noErr
        },
        unregisterHotKey: { _ in noErr },
        eventHotKeyID: { _, _ in OSStatus(eventNotHandledErr) }
    )
}

private extension ShortcutPermissionSystem {
    static let allDenied = ShortcutPermissionSystem(
        accessibilityTrusted: { false },
        inputMonitoringStatus: { .denied },
        screenCaptureTrusted: { false },
        canPostEvents: { false },
        requestAccessibility: { false },
        openAccessibilitySettings: {},
        registerInputMonitoring: { false },
        openMediaKeySettings: { _ in }
    )
}
