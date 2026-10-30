import SwiftUI
import CockpitUI

@main
struct HITMCockpitVisionApp: App {
    /// ONE store for both scenes, so the flat window and the volume always show the same state.
    @StateObject private var store = CockpitStore()

    var body: some Scene {
        WindowGroup("Flat") {
            FlatCockpitView(store: store)
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
