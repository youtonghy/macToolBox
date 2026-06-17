import AppKit
import SwiftUI

@main
struct ToolBoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // LSUIElement hides the Dock; an empty Settings scene means no main window.
        Settings { EmptyView() }
    }
}
