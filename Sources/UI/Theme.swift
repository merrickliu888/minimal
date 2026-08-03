import SwiftUI

/// Shared visual language: neutral grays, light-blue accent, vibrancy-
/// friendly translucency, restrained corners and shadows.
enum Theme {
    static let accent = Color(red: 0.42, green: 0.67, blue: 0.98)
    static let surface = Color(nsColor: .windowBackgroundColor).opacity(0.55)
    static let surfaceStroke = Color.white.opacity(0.12)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let failure = Color(red: 0.92, green: 0.44, blue: 0.40)

    static let cornerRadius: CGFloat = 12
    static let pillRadius: CGFloat = 26
}

/// NSVisualEffectView-backed background for overlay surfaces.
struct VibrantBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.state = .active
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

extension View {
    /// Standard overlay card chrome: blur, hairline stroke, rounded corners,
    /// soft shadow.
    func overlayCard(cornerRadius: CGFloat = Theme.cornerRadius) -> some View {
        background(VibrantBackground())
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }
}

/// Small key-cap hint, e.g. ⏎ or A.
struct KeyHint: View {
    let symbol: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(symbol)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
