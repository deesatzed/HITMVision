import SwiftUI

/// Risk profile, sensitive/unsure marker, intent field, sample badge, counts and Reset.
public struct TopRail: View {
    @ObservedObject var store: CockpitStore
    var showsOpenVolume: Bool
    @State private var intent = ""
    #if os(visionOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    public init(store: CockpitStore, showsOpenVolume: Bool = false) {
        self.store = store; self.showsOpenVolume = showsOpenVolume
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HITM Cockpit").font(.title2.bold())
                if store.isLive { LiveBadge() } else { SampleBadge() }
                Spacer()
                #if os(visionOS)
                if showsOpenVolume {
                    Button { openWindow(id: cockpitVolumeWindowID) } label: { Label("Open volume", systemImage: "cube") }
                }
                #endif
                Button("Reset") { store.reset() }
            }
            if store.isLive {
                Text("Live: real runs from the project's .hitm/inbox. Each card was already checked by the floor rules and the gate model when the agent ran.")
                    .font(.callout).foregroundStyle(.secondary)
                if store.failedRuns > 0 { Text("\(store.failedRuns) run(s) produced no change and are not listed.").small().foregroundStyle(.secondary) }
                if let e = store.liveError { Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange) }
            } else {
            HStack(spacing: 16) {
                Picker("Risk profile", selection: Binding(get: { store.choice }, set: { store.setProfile($0) })) {
                    ForEach(ProfileChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 280)
                marker
                Text(store.choice.blurb).font(.callout).foregroundStyle(.secondary)
            }
            }
            HStack(spacing: 24) {
                Stat(value: store.waiting.count, label: "Waiting for you", color: .orange)
                Stat(value: store.quiet.count, label: "Handled quietly", color: .green)
                Stat(value: store.decided.count, label: "Decided by you", color: .blue)
                Text("\(store.interruptionCount) of \(store.tasks.count) tasks need you\(store.isLive ? "" : " under this profile")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !store.isLive {
            HStack {
                TextField("What do you want built?", text: $intent).textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send).buttonStyle(.borderedProminent)
                    .disabled(intent.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Sample: this logs your intent and updates the Planner line. No agent runs yet.")
                .small().foregroundStyle(.secondary)
            }
        }
    }

    /// Text + icon marker for the stricter profiles (never color alone).
    @ViewBuilder private var marker: some View {
        switch store.choice {
        case .light: EmptyView()
        case .strict: Label("SENSITIVE", systemImage: "lock.shield.fill").small(bold: true)
        case .unsure: Label("UNSURE: TREATED AS STRICT", systemImage: "questionmark.circle.fill").small(bold: true)
        }
    }

    private func send() {
        guard !intent.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.submitIntent(intent, source: .typed); intent = ""
    }
}
