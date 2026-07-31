enum ScreenCapturePermissionState: Equatable {
    case granted
    case denied
}

protocol ScreenCapturePermissionProviding: AnyObject {
    var state: ScreenCapturePermissionState { get }

    @discardableResult
    func requestAccess() -> Bool
    func openSettings()
}

final class ScreenCapturePermission: ScreenCapturePermissionProviding {
    private let preflight: () -> Bool
    private let request: () -> Bool
    private let openSettingsHandler: () -> Void

    init(
        preflight: @escaping () -> Bool = { Permissions.isScreenCaptureTrusted },
        request: @escaping () -> Bool = { Permissions.requestScreenCapture() },
        openSettings: @escaping () -> Void = { Permissions.openScreenCaptureSettings() }
    ) {
        self.preflight = preflight
        self.request = request
        openSettingsHandler = openSettings
    }

    var state: ScreenCapturePermissionState {
        preflight() ? .granted : .denied
    }

    @discardableResult
    func requestAccess() -> Bool {
        request()
    }

    func openSettings() {
        openSettingsHandler()
    }
}
