import SwiftUI

/// Window id the visionOS app uses for the bounded volume scene.
public let cockpitVolumeWindowID = "volume"

private struct SpatialTextKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True in the volume: small captions are raised to the system callout size so nothing readable is tiny.
    var spatialText: Bool {
        get { self[SpatialTextKey.self] }
        set { self[SpatialTextKey.self] = newValue }
    }
}

struct SmallText: ViewModifier {
    @Environment(\.spatialText) private var spatial
    var bold = false
    func body(content: Content) -> some View {
        let f: Font = spatial ? .callout : .caption
        content.font(bold ? f.bold() : f)
    }
}
extension View {
    func small(bold: Bool = false) -> some View { modifier(SmallText(bold: bold)) }
}

/// Pushes a view back by a small fixed distance on visionOS; a no-op elsewhere. Static, never animated.
struct PushedBack: ViewModifier {
    let points: CGFloat
    func body(content: Content) -> some View {
        #if os(visionOS)
        content.offset(z: -points)
        #else
        content
        #endif
    }
}

public struct SampleBadge: View {
    public init() {}
    public var body: some View {
        Text("PROTOTYPE SAMPLE DATA")
            .small(bold: true).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.yellow).foregroundColor(.black).clipShape(Capsule())
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
