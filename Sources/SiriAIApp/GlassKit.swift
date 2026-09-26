import SiriCore
import SwiftUI

// MARK: - Il linguaggio visivo di Siri AI+
//
// Ogni sezione segue lo stesso schema, come la Home:
// intestazione grande (occhiello maiuscolo, titolo, sottotitolo, azioni) → pillole in vetro per le viste →
// eventuale pannello in evidenza → schede e pannelli in vetro. Lo sfondo è l'aurora dello spazio.

/// Intestazione delle sezioni: occhiello maiuscolo, titolo grande, sottotitolo e azioni a destra.
struct PageHeader<Trailing: View>: View {
    var eyebrow: String?
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.5)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { trailing }
                .controlSize(.large)
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(eyebrow: String? = nil, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Icona su un tondo colorato, come nelle pillole di Salute.
struct IconBadge: View {
    let symbol: String
    var colors: [Color]
    var size: CGFloat = 26
    var multicolor = false

    var body: some View {
        Group {
            if multicolor {
                Image(systemName: symbol).symbolRenderingMode(.multicolor).font(.system(size: size * 0.5))
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.44, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .background(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom), in: Circle())
        .accessibilityHidden(true)
    }
}

/// Colori delle icone, sempre gli stessi in tutta l'app.
enum Hue {
    static let red = [Color(hex: 0xFF5A4E), Color(hex: 0xE3342A)]
    static let orange = [Color(hex: 0xFFB340), Color(hex: 0xFF8A00)]
    static let yellow = [Color(hex: 0xFFD84D), Color(hex: 0xF2B705)]
    static let green = [Color(hex: 0x4CD97B), Color(hex: 0x23B455)]
    static let teal = [Color(hex: 0x4FD1D9), Color(hex: 0x14A8B8)]
    static let blue = [Color(hex: 0x4BA3FF), Color(hex: 0x1E6FEA)]
    static let indigo = [Color(hex: 0x7D7BFF), Color(hex: 0x5146E0)]
    static let purple = [Color(hex: 0xC47BFF), Color(hex: 0x8E4BEA)]
    static let pink = [Color(hex: 0xFF7BAC), Color(hex: 0xE83E7C)]
    static let gray = [Color(hex: 0xA5ABB6), Color(hex: 0x7A818D)]
    static let sky = [Color(hex: 0x3B8BEB), Color(hex: 0x7CC0F5)]

    static func of(_ space: Space) -> [Color] {
        switch space {
        case .personale: green
        case .lavoro: blue
        case .codice: purple
        }
    }
}

// MARK: - Pillole

struct GlassPill: Identifiable {
    let id: String
    let title: String
    var value: String?
    let symbol: String
    var colors: [Color] = Hue.blue
    var multicolor = false
    var badge: Int = 0
}

/// Le pillole in vetro per passare da una vista all'altra (come in Salute).
/// Con il titolo e il valore diventano due righe; senza valore restano compatte.
struct GlassPills: View {
    let items: [GlassPill]
    @Binding var selection: String
    @Namespace private var space
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 10) {
                    ForEach(items) { item in pill(item) }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        .scrollClipDisabled()
    }

    private func pill(_ item: GlassPill) -> some View {
        let selected = item.id == selection
        return Button {
            withAnimation(.spring(duration: 0.5, bounce: 0.22)) { selection = item.id }
        } label: {
            HStack(spacing: 9) {
                IconBadge(symbol: item.symbol, colors: item.colors, size: item.value == nil ? 22 : 26, multicolor: item.multicolor)
                VStack(alignment: .leading, spacing: 0) {
                    if let value = item.value {
                        Text(item.title).font(.system(size: 11.5, weight: .semibold)).opacity(0.7)
                        Text(value).font(.system(size: 14, weight: .semibold)).contentTransition(.numericText())
                    } else {
                        Text(item.title).font(.system(size: 13.5, weight: .semibold))
                    }
                }
                .fixedSize()
                if item.badge > 0 {
                    Text("\(item.badge)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.orange, in: Capsule())
                }
            }
            .foregroundStyle(selected ? Color.black.opacity(0.85) : Color.primary)
            .padding(.leading, 8)
            .padding(.trailing, 15)
            .padding(.vertical, item.value == nil ? 6 : 7)
            .background {
                if selected {
                    Capsule().fill(.white.opacity(0.95))
                        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "selezione", in: space)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Pagine

/// Una pagina di sezione: scorre, ha larghezza di lettura e si apre sollevandosi con una leggera sfocatura.
struct GlassPage<Content: View>: View {
    var maxWidth: CGFloat = 980
    @ViewBuilder var content: Content
    @State private var opened = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .frame(maxWidth: maxWidth, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 14)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
        }
        .modifier(PageOpening(progress: opened ? 1 : 0))
        .onAppear {
            guard !opened else { return }
            if reduceMotion || WeatherBackdrop.stillFrames { opened = true } else {
                withAnimation(.spring(duration: 0.7, bounce: 0.12)) { opened = true }
            }
        }
    }
}

/// Apertura delle sezioni: più leggera di quella della Home (si solleva di poco e si mette a fuoco).
struct PageOpening: ViewModifier, Animatable {
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let closed = 1 - min(1, max(0, progress))
        content
            .rotation3DEffect(.degrees(closed * 18), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.5)
            .offset(y: closed * 24)
            .blur(radius: closed * 10)
            .opacity(min(1, progress * 1.6))
    }
}

/// Stato vuoto: simbolo grande con alone, titolo, spiegazione e una sola azione chiara.
struct GlassEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var colors: [Color] = Hue.blue
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                .shadow(color: (colors.first ?? .blue).opacity(0.45), radius: 18, y: 6)
            Text(title).font(.system(size: 20, weight: .bold)).multilineTextAlignment(.center)
            Text(message).font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

/// Riga dentro i pannelli in vetro: icona colorata, titolo, sottotitolo e un accessorio a destra.
struct GlassRow<Trailing: View>: View {
    let symbol: String
    var colors: [Color] = Hue.blue
    let title: String
    var subtitle: String?
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: symbol, colors: colors, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                trailing
                if action != nil {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

extension GlassRow where Trailing == EmptyView {
    init(symbol: String, colors: [Color] = Hue.blue, title: String, subtitle: String? = nil, action: (() -> Void)? = nil) {
        self.init(symbol: symbol, colors: colors, title: title, subtitle: subtitle, action: action) { EmptyView() }
    }
}

/// Titolo di un gruppo di schede («La tua giornata», «Modelli»…).
struct GroupTitle: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 22, weight: .bold)) }
}

extension View {
    /// Contenitore in vetro con angoli ampi (schede, pannelli, liste).
    func glassCard(radius: CGFloat = 24) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: radius))
    }
}
