import SwiftUI
import CockpitUI
import Foundation

@main
struct HITMCockpitVisionApp: App {
    /// ONE store for both scenes, so the flat window and the volume always show the same state.
    @StateObject private var store = CockpitStore()

    /// `HITM_REPO=/path/to/repo` (simulator: SIMCTL_CHILD_HITM_REPO) switches from sample tasks to the real cards in that repo's
    /// .hitm/inbox. Decisions are recorded there; `LiveSlice sync` on the Mac then commits or removes the branch.
    private func startLiveIfRequested() {
        guard !store.isLive, let path = ProcessInfo.processInfo.environment["HITM_REPO"], !path.isEmpty else { return }
        store.enableLive(repo: URL(fileURLWithPath: path), reviewer: ProcessInfo.processInfo.environment["HITM_REVIEWER"] ?? "vision-user", apply: nil)
    }

    var body: some Scene {
        WindowGroup("Flat") {
            FlatCockpitView(store: store).task { startLiveIfRequested() }
        }
        .defaultSize(width: 1500, height: 950)

        // Volume size is my choice: about 1.0 m wide x 0.7 m high x 0.4 m deep.
        WindowGroup("Volume", id: cockpitVolumeWindowID) {
            VolumeCockpitView(store: store)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.0, height: 0.7, depth: 0.4, in: .meters)
    }
}
