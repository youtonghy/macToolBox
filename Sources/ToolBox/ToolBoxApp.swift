import AppKit
import SwiftUI

@main
struct ToolBoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // AppDelegate owns the status item and settings window for this menu-bar-only app.
        Settings {
            EmptyView()
        }
    }
}
