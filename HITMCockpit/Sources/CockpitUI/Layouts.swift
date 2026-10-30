import SwiftUI

/// The flat layout: the same panels as the volume, arranged as the original prototype window.
public struct FlatCockpitView: View {
    @StateObject private var ownStore = CockpitStore()
    private let external: CockpitStore?

    /// Pass a shared store (the visionOS app does); omit it for a self-contained window.
    public init(store: CockpitStore? = nil) { external = store }

    public var body: some View {
        if let s = external { content(s) } else { content(ownStore) }
    }

    private func content(_ store: CockpitStore) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                #if os(visionOS)
                TopRail(store: store, showsOpenVolume: true)
                #else
                TopRail(store: store)
                #endif
                AgentsPanel(store: store, axis: .horizontal)
            }
            .padding(16)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        RequestsList(store: store)
                        QuietShelf(store: store)
                        DecidedPanel(store: store, showsLog: false)
                    }
                    .padding(16)
                }
                .frame(width: 280)
                Divider()
                NeedsYouPanel(store: store).frame(maxWidth: .infinity)
                Divider()
                DecisionDetailCard(store: store).frame(minWidth: 400, idealWidth: 440, maxWidth: 480)
            }
            Divider()
            LogTail(store: store).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The volume layout. Fixed addresses, nothing moves: top rail on top, agents left, Needs-you front-center (nearest),
/// decided right, quiet shelf low and pushed back by a small fixed distance (visionOS only; static, no animation).
public struct VolumeCockpitView: View {
    @ObservedObject var store: CockpitStore
    public init(store: CockpitStore) { self.store = store }

    /// Fixed push-back of the quiet shelf in points (my choice; roughly 9 cm at visionOS scale).
    static let quietShelfPushBack: CGFloat = 120

    public var body: some View {
        VStack(spacing: 16) {
            TopRail(store: store).padding(16).glassBackgroundIfAvailable()
            HStack(alignment: .top, spacing: 16) {
                AgentsPanel(store: store, axis: .vertical)
                    .frame(width: 300).padding(16).glassBackgroundIfAvailable()
                HStack(alignment: .top, spacing: 16) {
                    NeedsYouPanel(store: store)
                        .frame(maxWidth: .infinity).glassBackgroundIfAvailable()
                    DecisionDetailCard(store: store)
                        .frame(width: 420).glassBackgroundIfAvailable()
                }
                DecidedPanel(store: store)
                    .frame(width: 300).padding(16).glassBackgroundIfAvailable()
            }
            QuietShelf(store: store)
                .padding(16).glassBackgroundIfAvailable()
                .modifier(PushedBack(points: Self.quietShelfPushBack))
        }
        .padding(24)
        .environment(\.spatialText, true)
    }
}

extension View {
    @ViewBuilder func glassBackgroundIfAvailable() -> some View {
        #if os(visionOS)
        self.glassBackgroundEffect()
        #else
        self.background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.1)))
        #endif
    }
}
