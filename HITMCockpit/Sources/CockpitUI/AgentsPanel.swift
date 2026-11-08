import SwiftUI

/// The "Now" lines for Planner / Implementer / Reviewer. `.horizontal` is the flat strip, `.vertical` the volume column.
public struct AgentsPanel: View {
    @ObservedObject var store: CockpitStore
    var axis: Axis

    public init(store: CockpitStore, axis: Axis = .horizontal) { self.store = store; self.axis = axis }

    public var body: some View {
        if axis == .horizontal {
            HStack(spacing: 10) {
                Text("NOW").small(bold: true).foregroundStyle(.secondary)
                ForEach(store.agentLines) { pill($0, wrap: false) }
                Text(store.isLive ? "(from recent cards)" : "(sample activity)").small().foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("AGENTS NOW").small(bold: true).foregroundStyle(.secondary)
                ForEach(store.agentLines) { pill($0, wrap: true) }
                Text(store.isLive ? "(from recent cards)" : "(sample activity)").small().foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private func pill(_ line: AgentLine, wrap: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(line.state))
            Text(line.id).small(bold: true)
            Text(line.text).small().lineLimit(wrap ? nil : 1)
            Text(stateWord(line.state)).small().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.gray.opacity(0.15))
        .clipShape(wrap ? AnyShape(RoundedRectangle(cornerRadius: 10)) : AnyShape(Capsule()))
    }

    private func icon(_ s: AgentLine.State) -> String {
        switch s { case .working: return "gearshape.fill"; case .waiting: return "hand.raised.fill"; case .idle: return "moon.zzz" }
    }
    private func stateWord(_ s: AgentLine.State) -> String {
        switch s { case .working: return "(working)"; case .waiting: return "(waiting)"; case .idle: return "" }
    }
}
