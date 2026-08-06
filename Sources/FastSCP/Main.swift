import SwiftUI

@main
struct FastSCPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings scene exists for the system menu when app is .regular.
        // The menu bar status item is created programmatically in AppDelegate.
        Settings { EmptyView() }
    }
}
