import SwiftUI
import HITMCore

public struct NeedsYouPanel: View {
    public init(store: CockpitStore) { self.store = store }
    @ObservedObject var store: CockpitStore
    @State private var manual: [String: Bool] = [:]

    public var body: some View {
        let queue = store.waiting
        if queue.isEmpty {
            VStack(spacing: 10) {
                if store.showOffer { OfferPanel(store: store).padding(24) }
                Text("All clear").font(.largeTitle.bold())
                Text("Nothing is waiting for you. \(store.quiet.count) tasks proceeded quietly; see the quiet shelf.")
                    .foregroundStyle(.secondary)
                Text("Try switching the risk profile to Strict, or press Reset.").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if store.showOffer { OfferPanel(store: store) }
                    HStack {
                        Text("WAITING FOR YOU · \(queue.count)").small(bold: true).foregroundStyle(.secondary)
                        Spacer()
                        Text("Floor rules first").small().foregroundStyle(.secondary)
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
                Label(gate.tag, systemImage: gate.icon).small(bold: true)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(gate.fromFloor ? Color.red : Color.orange).foregroundColor(.white).clipShape(Capsule())
                Text(task.title).font(.title3.bold())
                Spacer()
                Text(task.role).small().padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.gray.opacity(0.25)).clipShape(Capsule())
                Button(action: onToggle) { Image(systemName: isOpen ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless)
            }
            Text(task.plain).font(.body)
            HStack(spacing: 8) {
                Label(task.reversible ? "Reversible" : "Not reversible", systemImage: task.reversible ? "arrow.uturn.backward.circle" : "exclamationmark.triangle.fill").small(bold: true)
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
                            .small().foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
                DisclosureGroup("Full detail", isExpanded: $openDetail) {
                    Text(task.summary + "\n" + task.detail).font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
                Text(String(format: "Agent confidence %.2f", task.confidence)).small().foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(gate.fromFloor ? Color.red.opacity(0.6) : Color.orange.opacity(0.6), lineWidth: 2))
    }
}

public struct OfferPanel: View {
    public init(store: CockpitStore) { self.store = store }
    @ObservedObject var store: CockpitStore

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stop asking about unsure routine work?").font(.headline)
            Text("You've passed \(store.smartPasses) tasks the agent was unsure about. Offer: only ask when its confidence is under \(String(format: "%.2f", relaxedConfidenceThreshold)) (now \(String(format: "%.2f", store.threshold))).")
                .font(.callout)
            Text("Always-ask and project rules are not part of this offer and can't be relaxed here. Sample offer: accepting changes the sample threshold only.")
                .small().foregroundStyle(.secondary)
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

