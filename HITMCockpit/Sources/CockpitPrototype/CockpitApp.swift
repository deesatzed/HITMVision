import SwiftUI
import CockpitUI
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
            FlatCockpitView().frame(minWidth: 1400, minHeight: 800)
        }
    }
}
