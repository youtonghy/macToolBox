import AppKit

protocol DisplaySettingsOpening {
    @discardableResult
    func openDisplaySettings() -> Bool
}

struct SystemDisplaySettingsLauncher: DisplaySettingsOpening {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    @discardableResult
    func openDisplaySettings() -> Bool {
        let candidates = [
            "x-apple.systempreferences:com.apple.Displays-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.displays",
            "x-apple.systempreferences:"
        ]

        for rawValue in candidates {
            guard let url = URL(string: rawValue), workspace.open(url) else { continue }
            return true
        }
        return false
    }
}
