import SwiftUI

/// Tasks proceeding without asking the human.
public struct QuietShelf: View {
    @ObservedObject var store: CockpitStore
    public init(store: CockpitStore) { self.store = store }

    public var body: some View {
        let tasks = store.quiet
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("RUNNING QUIETLY").small(bold: true).foregroundStyle(.secondary)
                ForEach(tasks) { t in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(.body).lineLimit(1)
                            Text(t.role).small().foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("quiet").small().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Items the human has decided, plus (optionally) the last log events.
public struct DecidedPanel: View {
    @ObservedObject var store: CockpitStore
    var showsLog: Bool
    public init(store: CockpitStore, showsLog: Bool = true) { self.store = store; self.showsLog = showsLog }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let tasks = store.decided
            Text("DECIDED BY YOU").small(bold: true).foregroundStyle(.secondary)
            if tasks.isEmpty { Text("Nothing decided yet").small().foregroundStyle(.secondary) }
            ForEach(tasks) { t in
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).font(.body).lineLimit(1)
                        Text(t.role).small().foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(store.resolutions[t.id].map { store.label($0) } ?? "").small().foregroundStyle(.secondary)
                }
            }
            if showsLog {
                Divider()
                LogTail(store: store)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The last three events of the real EventLog.
public struct LogTail: View {
    @ObservedObject var store: CockpitStore
    public init(store: CockpitStore) { self.store = store }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Activity log (real EventLog)").small(bold: true).foregroundStyle(.secondary)
            if store.log.events.isEmpty { Text("No decisions yet").small().foregroundStyle(.secondary) }
            ForEach(Array(store.log.events.suffix(3).reversed()), id: \.revision) { e in
                Text("rev \(e.revision) · \(e.kind) · \(e.payload)").small().lineLimit(1)
            }
        }
    }
}

/// The user's typed requests (flat sidebar).
struct RequestsList: View {
    @ObservedObject var store: CockpitStore
    var body: some View {
        if !store.requests.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR REQUESTS").small(bold: true).foregroundStyle(.secondary)
                ForEach(Array(store.requests.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r).font(.body)
                        Text("Received by Planner · sample: no agent runs yet").small().foregroundStyle(.secondary)
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
