import SwiftUI
import HITMCore

/// The focused waiting decision, answered in a fixed order under fixed headings. Read-only: the buttons live on the queue rows.
public struct DecisionDetailCard: View {
    @ObservedObject var store: CockpitStore
    public init(store: CockpitStore) { self.store = store }

    public var body: some View {
        if let task = store.focusedTask,
           let brief = DecisionBrief(task: task, gate: store.gate(for: task), profile: store.choice, waiting: store.waiting) {
            VStack(alignment: .leading, spacing: 0) {
                // Fixed header: stays put while the sections below scroll.
                VStack(alignment: .leading, spacing: 4) {
                    Text("DECISION DETAILS").small(bold: true).foregroundStyle(.secondary)
                    Text(brief.what.title).font(.title3.bold()).lineLimit(2)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                Divider()
                ScrollView {
                    BriefContent(brief: brief).padding(20)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                Text("Nothing selected").font(.title3.bold())
                Text("When something is waiting for you, its details appear here.").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
        }
    }
}

struct SampleMarker: View {
    var body: some View {
        Label("SAMPLE (invented for UX review)", systemImage: "flask.fill").small(bold: true)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.yellow).foregroundColor(.black).clipShape(Capsule())
    }
}

struct BriefContent: View {
    let brief: DecisionBrief

    private func heading(_ t: String) -> some View { Text(t).font(.headline) }

    private var evidenceBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Evidence", systemImage: "doc.text.magnifyingglass").font(.headline)
                if brief.contentIsSample { SampleMarker() }
            }
            switch brief.evidence {
            case .proof(let lines):
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in Text("• \(l)").font(.body) }
            case .noProofAttached:
                Text("No proof attached").font(.body).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.15)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                heading("What is it")
                HStack(spacing: 8) {
                    Text("Agent role: \(brief.what.role)").font(.callout).foregroundStyle(.secondary)
                    Label(brief.what.reversible ? "Reversible" : "Not reversible",
                          systemImage: brief.what.reversible ? "arrow.uturn.backward.circle" : "exclamationmark.triangle.fill")
                        .small(bold: true).lineLimit(1).fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background((brief.what.reversible ? Color.green : Color.red).opacity(0.35))
                        .foregroundColor(.primary).clipShape(Capsule())
                }
                Text(brief.what.plain).font(.body)
                HStack(spacing: 8) {
                    Text("Exactly what changes").font(.callout.bold())
                    if brief.contentIsSample { SampleMarker() }
                }
                Text(brief.what.summary).font(.callout)
                Text(brief.what.detail).font(.system(.callout, design: .monospaced))
            }
            evidenceBlock
            VStack(alignment: .leading, spacing: 6) {
                heading("Why it flagged")
                Text(brief.why.plainReason).font(.body)
                Text(brief.why.technicalReason).font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                heading("What your decision covers")
                Text(brief.scope.text).font(.body)
                if brief.scope.broaderRulesLater {
                    Text("Broader rules come later.").font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                heading("How this was worked out")
                Text(brief.how.method).font(.body)
                ForEach(Array(brief.how.inputs.enumerated()), id: \.offset) { _, i in Text("• \(i)").font(.callout) }
                ForEach(Array(brief.how.unavailable.enumerated()), id: \.offset) { _, u in
                    Label("\(u.name): \(u.status)", systemImage: "nosign")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                heading("What happens next")
                Text(brief.next.pass).font(.body)
                Text(brief.next.modify).font(.body)
                Text(brief.next.reject).font(.body)
                if !brief.next.unblocks.isEmpty {
                    Text("Also waiting on you from \(brief.what.role): \(brief.next.unblocks.map { $0.title }.joined(separator: ", "))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
