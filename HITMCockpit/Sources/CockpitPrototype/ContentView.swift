import SwiftUI
import HITMCore

struct ContentView: View {
    @StateObject private var store = CockpitStore()

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(store: store)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                BoardView(store: store).frame(width: 360)
                Divider()
                AttentionPane(store: store).frame(maxWidth: .infinity)
            }
            Divider()
            LogFooter(store: store)
        }
    }
}

struct SampleBadge: View {
    var body: some View {
        Text("PROTOTYPE SAMPLE DATA")
            .font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.yellow).foregroundColor(.black).clipShape(Capsule())
    }
}

struct HeaderBar: View {
    @ObservedObject var store: CockpitStore
    @State private var intent = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HITM Cockpit").font(.title2.bold())
                SampleBadge()
                Spacer()
                Button("Reset") { store.reset() }
            }
            HStack(spacing: 16) {
                Picker("Risk profile", selection: Binding(get: { store.choice }, set: { store.setProfile($0) })) {
                    ForEach(ProfileChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 280)
                Text(store.choice.blurb).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                Stat(value: store.waiting.count, label: "Waiting for you", color: .orange)
                Stat(value: store.quiet.count, label: "Handled quietly", color: .green)
                Stat(value: store.decided.count, label: "Decided by you", color: .blue)
                Text("\(store.interruptionCount) of \(sampleTasks.count) tasks need you under this profile")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                TextField("What do you want built?", text: $intent, onCommit: send).textFieldStyle(.roundedBorder)
                Button("Send", action: send).buttonStyle(.borderedProminent).disabled(intent.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Sample: this logs your intent and updates the Planner line. No agent runs yet.")
                .font(.caption).foregroundStyle(.secondary)
            NowStrip(store: store)
        }
        .padding(16)
    }

    private func send() { store.submitIntent(intent); intent = "" }
}

struct NowStrip: View {
    @ObservedObject var store: CockpitStore

    var body: some View {
        HStack(spacing: 10) {
            Text("NOW").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(store.agentLines) { line in
                HStack(spacing: 6) {
                    Circle().fill(color(line.state)).frame(width: 8, height: 8)
                    Text(line.id).font(.caption.bold())
                    Text(line.text).font(.caption).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.gray.opacity(0.15)).clipShape(Capsule())
            }
            Text("(sample activity)").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func color(_ s: AgentLine.State) -> Color {
        switch s { case .working: return .green; case .waiting: return .orange; case .idle: return .gray }
    }
}

struct Stat: View {
    let value: Int, label: String, color: Color
    var body: some View {
        HStack(spacing: 8) {
            Text("\(value)").font(.title.bold()).foregroundColor(color)
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct BoardView: View {
    @ObservedObject var store: CockpitStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !store.requests.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("YOUR REQUESTS").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(Array(store.requests.enumerated()), id: \.offset) { _, r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r).font(.body)
                                Text("Received by Planner · sample: no agent runs yet").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                section("Running quietly", store.quiet, chip: "quiet", color: .green)
                section("Decided by you", store.decided, chip: nil, color: .blue)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ tasks: [SampleTask], chip: String?, color: Color) -> some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(tasks) { t in
                    HStack(spacing: 8) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(.body).lineLimit(1)
                            Text(t.role).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(chip ?? store.resolutions[t.id].map { store.label($0) } ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct AttentionPane: View {
    @ObservedObject var store: CockpitStore
    @State private var manual: [String: Bool] = [:]

    var body: some View {
        let queue = store.waiting
        if queue.isEmpty {
            VStack(spacing: 10) {
                if store.showOffer { OfferPanel(store: store).padding(24) }
                Text("All clear").font(.largeTitle.bold())
                Text("Nothing is waiting for you. \(store.quiet.count) tasks proceeded quietly; see the board.")
                    .foregroundStyle(.secondary)
                Text("Try switching the risk profile to Strict, or press Reset.").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if store.showOffer { OfferPanel(store: store) }
                    HStack {
                        Text("WAITING FOR YOU · \(queue.count)").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Text("Floor rules first").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(queue.enumerated()), id: \.element.id) { index, task in
                        AttentionCard(store: store, task: task,
                                      isOpen: manual[task.id] ?? (index == 0),
                                      onToggle: { manual[task.id] = !(manual[task.id] ?? (index == 0)) })
                            .id(task.id + store.choice.rawValue)
                    }
                }
                .padding(24)
            }
        }
    }
}

struct AttentionCard: View {
    @ObservedObject var store: CockpitStore
    let task: SampleTask
    let isOpen: Bool
    let onToggle: () -> Void
    let gate: Gate
    @State private var openEvidence: Bool
    @State private var openRules: Bool
    @State private var openDetail = false
    @State private var modifying = false
    @State private var note = ""

    init(store: CockpitStore, task: SampleTask, isOpen: Bool, onToggle: @escaping () -> Void) {
        self.store = store; self.task = task; self.isOpen = isOpen; self.onToggle = onToggle
        let g = store.gate(for: task)
        self.gate = g
        _openEvidence = State(initialValue: g.detailLevel >= 2)
        _openRules = State(initialValue: g.detailLevel >= 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(gate.tag).font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(gate.fromFloor ? Color.red : Color.orange).foregroundColor(.white).clipShape(Capsule())
                Text(task.title).font(.title3.bold())
                Spacer()
                Text(task.role).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.gray.opacity(0.25)).clipShape(Capsule())
                Button(action: onToggle) { Image(systemName: isOpen ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless)
            }
            Text(task.plain).font(.body)
            HStack(spacing: 8) {
                Text(task.reversible ? "Reversible" : "Not reversible").font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background((task.reversible ? Color.green : Color.red).opacity(0.2))
                    .foregroundColor(task.reversible ? .green : .red).clipShape(Capsule())
                Text(gate.plainReason).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { store.resolve(task, .passed) } label: { Label("Pass", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).tint(.green)
                Button { modifying.toggle() } label: { Label("Modify…", systemImage: "pencil") }
                    .buttonStyle(.bordered)
                Button { store.resolve(task, .rejected) } label: { Label("Reject", systemImage: "xmark") }
                    .buttonStyle(.bordered).tint(.red)
            }
            if modifying {
                HStack {
                    TextField("What should change?", text: $note).textFieldStyle(.roundedBorder)
                    Button("Send") { store.resolve(task, .modified(note.isEmpty ? "(no note)" : note)) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if isOpen {
                Divider()
                DisclosureGroup("Evidence", isExpanded: $openEvidence) {
                    VStack(alignment: .leading, spacing: 4) { ForEach(task.evidence, id: \.self) { Text("• \($0)") } }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
                DisclosureGroup("Rules for this situation", isExpanded: $openRules) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("• Technical: \(gate.reason)")
                        ForEach(task.ruleNotes, id: \.self) { Text("• \($0)") }
                        Text("Action class: \(task.action.rawValue) · Profile: \(store.choice.rawValue)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
                DisclosureGroup("Full detail", isExpanded: $openDetail) {
                    Text(task.summary + "\n" + task.detail).font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
                Text(String(format: "Agent confidence %.2f", task.confidence)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(gate.fromFloor ? Color.red.opacity(0.6) : Color.orange.opacity(0.6), lineWidth: 2))
    }
}

struct OfferPanel: View {
    @ObservedObject var store: CockpitStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stop asking about unsure routine work?").font(.headline)
            Text("You've passed \(store.smartPasses) tasks the agent was unsure about. Offer: only ask when its confidence is under \(String(format: "%.2f", relaxedConfidenceThreshold)) (now \(String(format: "%.2f", store.threshold))).")
                .font(.callout)
            Text("Always-ask and project rules are not part of this offer and can't be relaxed here. Sample offer: accepting changes the sample threshold only.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Yes, relax it") { store.answerOffer(accept: true) }.buttonStyle(.borderedProminent)
                Button("No, keep asking") { store.answerOffer(accept: false) }.buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.blue.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blue.opacity(0.5), lineWidth: 1.5))
    }
}

struct LogFooter: View {
    @ObservedObject var store: CockpitStore

    var body: some View {
        HStack(alignment: .top) {
            Text("Activity log (real EventLog)").font(.caption.bold()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if store.log.events.isEmpty {
                    Text("No decisions yet").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(store.log.events.suffix(3).reversed()), id: \.revision) { e in
                    Text("rev \(e.revision) · \(e.kind) · \(e.payload)").font(.caption).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(12)
    }
}
