import SwiftUI
import HITMCore

public struct NeedsYouPanel: View {
    public init(store: CockpitStore) { self.store = store }
    @ObservedObject var store: CockpitStore

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
                    let focusedID = store.focusedTask?.id
                    ForEach(queue) { task in
                        AttentionCard(store: store, task: task, isFocused: task.id == focusedID)
                            .id(task.id + store.choice.rawValue)
                    }
                }
                .padding(24)
            }
        }
    }
}

/// One compact queue row. Tapping the row focuses it (the detail card shows it); Pass / Modify / Reject act on this item.
struct AttentionCard: View {
    @ObservedObject var store: CockpitStore
    let task: SampleTask
    let isFocused: Bool
    @State private var modifying = false
    @State private var note = ""

    var body: some View {
        let gate = store.gate(for: task)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(gate.tag, systemImage: gate.icon).small(bold: true).lineLimit(1).fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(gate.fromFloor ? Color.red : Color.orange).foregroundColor(.white).clipShape(Capsule())
                Text(task.role).small().lineLimit(1).fixedSize().padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.gray.opacity(0.25)).clipShape(Capsule())
                Spacer(minLength: 0)
                if isFocused {
                    Label("Showing details", systemImage: "eye.fill").small(bold: true).lineLimit(1).fixedSize()
                }
            }
            Text(task.title).font(.title3.bold()).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(gate.plainReason).font(.callout).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { store.resolve(task, .passed) } label: { Label("Pass", systemImage: "checkmark").lineLimit(1).fixedSize() }
                    .buttonStyle(.borderedProminent).tint(.green)
                Button { modifying.toggle() } label: { Label("Modify…", systemImage: "pencil").lineLimit(1).fixedSize() }
                    .buttonStyle(.bordered)
                Button { store.resolve(task, .rejected) } label: { Label("Reject", systemImage: "xmark").lineLimit(1).fixedSize() }
                    .buttonStyle(.bordered).tint(.red)
                Spacer(minLength: 0)
            }
            if modifying {
                HStack {
                    TextField("What should change?", text: $note).textFieldStyle(.roundedBorder)
                    Button("Send") { store.resolve(task, .modified(note.isEmpty ? "(no note)" : note)) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(isFocused ? 0.22 : 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(isFocused ? Color.primary : (gate.fromFloor ? Color.red.opacity(0.6) : Color.orange.opacity(0.6)),
                          style: StrokeStyle(lineWidth: isFocused ? 4 : 2)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { store.focus(task.id) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isFocused ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Show details") { store.focus(task.id) }
        .modifier(RowHover())
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


/// Gaze/pointer highlight on visionOS; a no-op on macOS.
struct RowHover: ViewModifier {
    func body(content: Content) -> some View {
        #if os(visionOS)
        content.hoverEffect()
        #else
        content
        #endif
    }
}
