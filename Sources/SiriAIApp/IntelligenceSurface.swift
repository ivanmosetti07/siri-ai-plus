import SwiftUI

/// Shared identity: content stays quiet; light belongs to the assistant's controls.
struct IntelligenceSurface: ViewModifier {
    var active = false
    var radius: CGFloat = 24
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.compactLayout) private var compact

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency { RoundedRectangle(cornerRadius: radius).fill(Color.surface) }
                // Nel pannello di destra, già in vetro, il campo è un velo leggero.
                else if compact { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(0.06)) }
            }
            .glassEffect(compact ? .identity : .regular, in: .rect(cornerRadius: radius))
            .overlay {
                TimelineView(.animation(minimumInterval: 1 / 20, paused: !active || reduceMotion)) { context in
                    let angle = active && !reduceMotion ? context.date.timeIntervalSinceReferenceDate * 35 : 0
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(AngularGradient(colors: [.cyan, .indigo, .purple, .pink, .cyan], center: .center,
                                                      angle: .degrees(angle)), lineWidth: contrast == .increased ? 2 : 1.2)
                        .opacity(active ? 0.8 : 0.22)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .shadow(color: .indigo.opacity(active ? 0.12 : 0.035), radius: active ? 20 : 10, y: 5)
    }
}

struct IntelligenceHero: View {
    let title: String
    let subtitle: String
    var state: OrbState = .idle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [.indigo.opacity(0.12), .purple.opacity(0.04), .clear],
                                         center: .center, startRadius: 10, endRadius: 95))
                    .frame(width: 190, height: 150)
                OrbView(state: state, size: 76)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .frame(width: 27, height: 27)
                            .glassEffect(.regular, in: .circle)
                            .offset(x: 3, y: 1)
                    }
                    .scaleEffect(hovering && !reduceMotion ? 1.06 : 1)
                    .rotation3DEffect(.degrees(hovering && !reduceMotion ? 9 : 0), axis: (x: -1, y: 1, z: 0))
            }
            .frame(height: 100)
            .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .tracking(-0.8)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.7), value: hovering)
    }
}
