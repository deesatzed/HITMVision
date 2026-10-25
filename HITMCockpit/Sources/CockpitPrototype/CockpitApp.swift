import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct CockpitApp: App {
    init() {
        #if os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
    }

    var body: some Scene {
        WindowGroup("HITM Cockpit prototype") {
            ContentView().frame(minWidth: 1100, minHeight: 700)
        }
    }
}
