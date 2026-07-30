import Carbon.HIToolbox
import XCTest
@testable import ToolBox

@MainActor
final class HotKeyControllerTests: XCTestCase {
    func testDeinitUnregistersHotKeyAndRemovesHandler() {
        let recorder = HotKeySystemRecorder()
        weak var weakController: HotKeyController?

        do {
            let controller = HotKeyController(system: recorder.system)
            weakController = controller
            XCTAssertTrue(controller.install())
            XCTAssertTrue(controller.register(keyCode: 53, modifiers: [.command]))
        }

        XCTAssertNil(weakController)
        XCTAssertEqual(recorder.unregisteredHotKeys, [recorder.hotKeyRef])
        XCTAssertEqual(recorder.removedHandlers, [recorder.handlerRef])
    }

    func testInstallIsIdempotent() {
        let recorder = HotKeySystemRecorder()
        let controller = HotKeyController(system: recorder.system)

        XCTAssertTrue(controller.install())
        XCTAssertTrue(controller.install())

        XCTAssertEqual(recorder.installHandlerCalls, 1)
    }

    func testFailedInstallAndRegistrationRemainUninstalled() {
        let recorder = HotKeySystemRecorder(
            installStatus: OSStatus(eventInternalErr),
            registerStatus: OSStatus(eventHotKeyExistsErr)
        )
        let controller = HotKeyController(system: recorder.system)

        XCTAssertFalse(controller.install())
        XCTAssertFalse(controller.register(keyCode: 53, modifiers: [.command]))
        XCTAssertTrue(recorder.removedHandlers.isEmpty)
        XCTAssertTrue(recorder.unregisteredHotKeys.isEmpty)
    }

    func testRegisterRequiresAnInstalledHandler() {
        let recorder = HotKeySystemRecorder()
        let controller = HotKeyController(system: recorder.system)

        XCTAssertFalse(controller.register(keyCode: 53, modifiers: [.command]))
        XCTAssertEqual(recorder.registerHotKeyCalls, 0)
    }

    func testScreenWipeFailsClosedWhenExitHotKeyCannotBeRegistered() {
        let recorder = HotKeySystemRecorder(registerStatus: OSStatus(eventHotKeyExistsErr))
        let coordinator = ScreenWipeCoordinator(
            hotKey: HotKeyController(system: recorder.system)
        )
        var didFinish = false

        XCTAssertFalse(coordinator.start { didFinish = true })
        XCTAssertFalse(didFinish)
        XCTAssertEqual(recorder.registerHotKeyCalls, 1)
    }
}

private final class HotKeySystemRecorder {
    let handlerRef = EventHandlerRef(bitPattern: 1)!
    let hotKeyRef = EventHotKeyRef(bitPattern: 2)!

    private let installStatus: OSStatus
    private let registerStatus: OSStatus
    private(set) var installHandlerCalls = 0
    private(set) var registerHotKeyCalls = 0
    private(set) var removedHandlers: [EventHandlerRef] = []
    private(set) var unregisteredHotKeys: [EventHotKeyRef] = []

    init(installStatus: OSStatus = noErr, registerStatus: OSStatus = noErr) {
        self.installStatus = installStatus
        self.registerStatus = registerStatus
    }

    lazy var system = HotKeySystem(
        installHandler: { [unowned self] _, output in
            installHandlerCalls += 1
            if installStatus == noErr {
                output.pointee = handlerRef
            }
            return installStatus
        },
        removeHandler: { [unowned self] ref in
            removedHandlers.append(ref)
            return noErr
        },
        registerHotKey: { [unowned self] _, _, _, output in
            registerHotKeyCalls += 1
            if registerStatus == noErr {
                output.pointee = hotKeyRef
            }
            return registerStatus
        },
        unregisterHotKey: { [unowned self] ref in
            unregisteredHotKeys.append(ref)
            return noErr
        }
    )
}
