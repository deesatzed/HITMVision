import SwiftUI
import CockpitUI
import HITMCore
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

    @StateObject private var store = CockpitStore()

    var body: some Scene {
        WindowGroup("HITM Cockpit prototype") {
            FlatCockpitView(store: store).frame(minWidth: 1400, minHeight: 800)
                .task { startLiveIfRequested() }
        }
    }

    /// `HITM_REPO=/path/to/repo` switches from sample tasks to the real cards in that repo's .hitm/inbox.
    private func startLiveIfRequested() {
        guard !store.isLive, let path = ProcessInfo.processInfo.environment["HITM_REPO"], !path.isEmpty else { return }
        let repo = URL(fileURLWithPath: path)
        let workspace = try? Workspace(repo: repo)
        store.enableLive(repo: repo, reviewer: ProcessInfo.processInfo.environment["HITM_REVIEWER"] ?? NSUserName()) { card, pass in
            guard let workspace else { return }
            if pass { try workspace.commit(id: card.id, message: card.title) } else { try workspace.discard(id: card.id) }
        }
    }
}
