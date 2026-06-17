import AppKit

/// Simple modal alert helper — the app's only user-facing error presentation.
/// Always presents on the main thread (callers may run from Combine sinks / background work).
enum AppAlert {

    /// Shows a modal `NSAlert`.
    /// - Parameters:
    ///   - title: Bold headline (`messageText`).
    ///   - message: Detail body (`informativeText`).
    ///   - primaryButton: Optional leading button (e.g. "打开系统设置") with an action run on click.
    ///   A trailing "好" button is always added.
    static func show(title: String,
                     message: String,
                     primaryButton: (title: String, action: (() -> Void)?)? = nil) {
        let present = {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            if let primaryButton { alert.addButton(withTitle: primaryButton.title) }
            alert.addButton(withTitle: "好")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn, let primaryButton { primaryButton.action?() }
        }
        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.async(execute: present)
        }
    }
}
