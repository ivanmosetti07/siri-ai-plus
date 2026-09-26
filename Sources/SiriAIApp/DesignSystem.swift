import AppKit
import SiriCore
import SwiftUI

// MARK: - Token

enum DS {
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        /// Campi, righe e piccoli contenitori.
        static let control: CGFloat = 10
        static let md: CGFloat = 12
        static let card: CGFloat = 18
        static let panel: CGFloat = 16
        static let lg: CGFloat = 18
        /// Campo di scrittura.
        static let composer: CGFloat = 24
    }

    /// Tipografia: stili di sistema (seguono le dimensioni del testo scelte nelle Impostazioni di Sistema).
    enum Fonts {
        static let micro = Font.caption2
        static let microStrong = Font.caption2.weight(.semibold)
        static let caption = Font.subheadline
        static let captionStrong = Font.subheadline.weight(.medium)
        static let callout = Font.callout
        static let body = Font.body
        static let bodyStrong = Font.body.weight(.semibold)
        /// Testo della conversazione: un punto sopra il corpo, per la lettura.
        static let message = Font.system(size: 14)
        static let section = Font.title3.weight(.semibold)
        static let title = Font.title.weight(.semibold)
        static let display = Font.largeTitle.weight(.semibold)
        static let mono = Font.system(.callout, design: .monospaced)
    }

    /// Animazioni: durate uniche per tutta l'app.
    enum Motion {
        static let quick = Animation.snappy(duration: 0.15)
        static let standard = Animation.smooth(duration: 0.25)
        static let smooth = Animation.smooth(duration: 0.35)
    }

    enum Shadow {
        static let cardColor = Color.black.opacity(0.05)
        static let cardRadius: CGFloat = 8
        static let cardY: CGFloat = 2
    }

    /// Colonna di lettura della conversazione.
    static let readingWidth: CGFloat = 720
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    init(_ rgb: RGB) { self.init(red: rgb.red, green: rgb.green, blue: rgb.blue) }

    // Colori di sistema: seguono chiaro/scuro, «Aumenta contrasto» e il colore di evidenziazione.
    /// Schede e contenitori.
    static let surface = Color(nsColor: .controlBackgroundColor)
    /// Aree secondarie dentro le schede (testi modificabili, anteprime).
    static let surfaceSubtle = Color(nsColor: .quaternarySystemFill)
    /// Sfondo delle viste principali.
    static let canvas = Color(nsColor: .textBackgroundColor)
    /// Bolla dei messaggi dell'utente.
    static let bubble = Color(nsColor: .tertiarySystemFill)
    static let hairline = Color(nsColor: .separatorColor)
    static let paper = Color(nsColor: .textBackgroundColor)
}

// MARK: - Fonti e artefatti

extension SourceKind {
    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .mail: "envelope.fill"
        case .reminders: "checklist"
        case .notes: "note.text"
        case .files: "folder.fill"
        case .photos: "photo.fill"
        case .messages: "message.fill"
        case .contacts: "person.crop.circle.fill"
        case .voiceMemos: "waveform"
        }
    }

    var fill: AnyShapeStyle {
        switch self {
        case .calendar: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFF5A4E), Color(hex: 0xE3342A)], startPoint: .top, endPoint: .bottom))
        case .mail: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x3EA2FF), Color(hex: 0x1470EA)], startPoint: .top, endPoint: .bottom))
        case .reminders: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x8577FF), Color(hex: 0x5B4BE0)], startPoint: .top, endPoint: .bottom))
        case .notes: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFFD84D), Color(hex: 0xF2B705)], startPoint: .top, endPoint: .bottom))
        case .files: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x45BDEB), Color(hex: 0x1A93CB)], startPoint: .top, endPoint: .bottom))
        case .photos: AnyShapeStyle(AngularGradient(colors: [Color(hex: 0xFF9F0A), Color(hex: 0xFF375F), Color(hex: 0xBF5AF2), Color(hex: 0x0A84FF), Color(hex: 0x30D158), Color(hex: 0xFFD60A), Color(hex: 0xFF9F0A)], center: .center))
        case .messages: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x52DB6C), Color(hex: 0x26B444)], startPoint: .top, endPoint: .bottom))
        case .contacts: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xC9B79C), Color(hex: 0x9C8567)], startPoint: .top, endPoint: .bottom))
        case .voiceMemos: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x3A3A3C), Color(hex: 0x1C1C1E)], startPoint: .top, endPoint: .bottom))
        }
    }

    var glyph: Color {
        switch self {
        case .notes: Color.black.opacity(0.72)
        case .voiceMemos: Color(hex: 0xFF453A)
        default: .white
        }
    }
}

enum ArtifactKind: String, CaseIterable, Codable {
    case pages, numbers, keynote

    var app: String {
        switch self {
        case .pages: String(localized: "Pages")
        case .numbers: String(localized: "Numbers")
        case .keynote: String(localized: "Keynote")
        }
    }

    var noun: String {
        switch self {
        case .pages: String(localized: "Documento")
        case .numbers: String(localized: "Foglio")
        case .keynote: String(localized: "Presentazione")
        }
    }

    /// Desinenza per l'accordo: «nuova presentazione», «presentazione salvata».
    /// In inglese non serve: «Presentation saved».
    var ending: String { Language.system == .en ? "" : self == .keynote ? "a" : "o" }

    var symbol: String {
        switch self {
        case .pages: "doc.richtext.fill"
        case .numbers: "chart.bar.fill"
        case .keynote: "play.rectangle.fill"
        }
    }

    var bundleID: String {
        switch self {
        case .pages: "com.apple.iWork.Pages"
        case .numbers: "com.apple.iWork.Numbers"
        case .keynote: "com.apple.iWork.Keynote"
        }
    }

    var tint: Color {
        switch self {
        case .pages: Color(hex: 0xF5820D)
        case .numbers: Color(hex: 0x1FA85A)
        case .keynote: Color(hex: 0x2F6BF0)
        }
    }

    var fill: AnyShapeStyle {
        switch self {
        case .pages: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFFA23A), Color(hex: 0xF07A00)], startPoint: .top, endPoint: .bottom))
        case .numbers: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x3DD06A), Color(hex: 0x1FA35B)], startPoint: .top, endPoint: .bottom))
        case .keynote: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x5A93FF), Color(hex: 0x2C63EE)], startPoint: .top, endPoint: .bottom))
        }
    }
}

/// Icone vere delle app di Apple, lette da macOS una volta sola: le stesse del Dock
/// (seguono anche lo stile scelto in Impostazioni di Sistema › Aspetto).
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(_ bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = icon
        return icon
    }

    /// Le icone di macOS lasciano un margine per l'ombra (il riquadro è 824 punti su 1024):
    /// ingrandite così, il riquadro riempie la cornice come gli altri elementi.
    static let bleed: CGFloat = 1024 / 824
    /// Curvatura degli angoli delle icone di macOS 27 (misurata sulle icone di sistema).
    static let cornerRatio: CGFloat = 0.259
}

/// Icona di un'app: quella vera se l'app è installata, altrimenti un riquadro disegnato nello stesso stile.
struct Tile: View {
    let symbol: String
    let fill: AnyShapeStyle
    var glyph: Color = .white
    var size: CGFloat = 26
    var dimmed = false
    var icon: NSImage?
    /// Disegno di Pages, Numbers o Keynote quando l'app non è installata.
    var artwork: ArtifactKind?

    init(_ source: SourceKind, size: CGFloat = 26, dimmed: Bool = false) {
        symbol = source.symbol; fill = source.fill; glyph = source.glyph; self.size = size; self.dimmed = dimmed
        icon = AppIcons.icon(source.systemBundleID)
    }

    init(_ artifact: ArtifactKind, size: CGFloat = 26) {
        symbol = artifact.symbol; fill = artifact.fill; self.size = size; artwork = artifact
        icon = AppIcons.icon(artifact.bundleID)
    }

    init(symbol: String, fill: AnyShapeStyle, size: CGFloat = 26, bundleID: String? = nil) {
        self.symbol = symbol; self.fill = fill; self.size = size
        icon = bundleID.flatMap { AppIcons.icon($0) }
    }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * AppIcons.bleed, height: size * AppIcons.bleed)
            } else {
                drawn
            }
        }
        .frame(width: size, height: size)
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityHidden(true)
    }

    /// Stessa forma, luce e ombra delle icone di macOS.
    private var drawn: some View {
        let shape = RoundedRectangle(cornerRadius: size * AppIcons.cornerRatio, style: .continuous)
        return shape
            .fill(fill)
            .overlay {
                if let artwork {
                    IWorkGlyph(kind: artwork)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(glyph)
                }
            }
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0)], startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.08), .white.opacity(0.32)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                                        lineWidth: max(0.5, size * 0.012)))
            .shadow(color: .black.opacity(0.18), radius: max(0.5, size * 0.02), y: size * 0.01)
    }
}

/// Pennino di Pages, grafico di Numbers e leggio di Keynote, come nelle loro icone.
private struct IWorkGlyph: View {
    let kind: ArtifactKind

    var body: some View {
        Canvas { gc, canvas in
            let s = canvas.width
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            let white = GraphicsContext.Shading.color(.white)
            switch kind {
            case .pages:
                // Pennino inclinato che scrive: punta in basso a sinistra, fessura e foro ritagliati.
                var nib = Path()
                nib.move(to: p(-0.14, -0.27))
                nib.addLine(to: p(0.14, -0.27))
                nib.addLine(to: p(0.15, -0.03))
                nib.addQuadCurve(to: p(0, 0.27), control: p(0.14, 0.13))
                nib.addQuadCurve(to: p(-0.15, -0.03), control: p(-0.14, 0.13))
                nib.closeSubpath()
                var cut = Path()
                cut.addEllipse(in: CGRect(x: -0.035 * s, y: -0.045 * s, width: 0.07 * s, height: 0.07 * s))
                cut.addRect(CGRect(x: -0.008 * s, y: -0.01 * s, width: 0.016 * s, height: 0.3 * s))
                var local = gc
                local.translateBy(x: 0.56 * s, y: 0.44 * s)
                local.rotate(by: .degrees(45))
                local.fill(nib.subtracting(cut), with: white)
                var line = Path()
                line.move(to: p(0.33, 0.66))
                line.addCurve(to: p(0.2, 0.78), control1: p(0.28, 0.72), control2: p(0.24, 0.77))
                gc.stroke(line, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: max(0.6, 0.025 * s), lineCap: .round))
            case .numbers:
                // Quattro barre come nel grafico dell'icona.
                for (index, top) in [0.5, 0.3, 0.42, 0.22].enumerated() {
                    let x = 0.225 + Double(index) * 0.15
                    gc.fill(Path(roundedRect: CGRect(x: x * s, y: top * s, width: 0.1 * s, height: (0.76 - top) * s), cornerRadius: 0.025 * s), with: white)
                }
            case .keynote:
                // Leggio: piano inclinato, colonna e base.
                var desk = Path()
                desk.move(to: p(0.25, 0.28))
                desk.addLine(to: p(0.75, 0.28))
                desk.addLine(to: p(0.67, 0.42))
                desk.addLine(to: p(0.33, 0.42))
                desk.closeSubpath()
                gc.fill(desk, with: white)
                gc.fill(Path(CGRect(x: 0.445 * s, y: 0.42 * s, width: 0.11 * s, height: 0.3 * s)), with: .color(.white.opacity(0.88)))
                gc.fill(Path(roundedRect: CGRect(x: 0.3 * s, y: 0.7 * s, width: 0.4 * s, height: 0.07 * s), cornerRadius: 0.025 * s), with: white)
            }
        }
    }
}

// MARK: - Stato delle azioni

enum ItemStatus: String, Codable {
    case draft, awaiting, running, opened, copied, done, uncertain, failed, cancelled

    var label: String {
        switch self {
        case .draft: String(localized: "Bozza")
        case .awaiting: String(localized: "Da confermare")
        case .running: String(localized: "In esecuzione")
        case .opened: String(localized: "Bozza aperta")
        case .copied: String(localized: "Testo copiato")
        case .done: String(localized: "Completato")
        case .uncertain: String(localized: "Da verificare")
        case .failed: String(localized: "Errore")
        case .cancelled: String(localized: "Annullato")
        }
    }

    var tint: Color {
        switch self {
        case .draft: .secondary
        case .awaiting: .orange
        case .running: .blue
        case .opened: .blue
        case .copied: .blue
        case .done: .green
        case .uncertain: .orange
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .draft: "pencil"
        case .awaiting: "hand.raised.fill"
        case .running: "circle.dotted"
        case .opened: "envelope.open"
        case .copied: "doc.on.clipboard"
        case .done: "checkmark"
        case .uncertain: "questionmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark"
        }
    }
}

struct StatusPill: View {
    let status: ItemStatus
    var label: String?

    var body: some View {
        HStack(spacing: 4) {
            if status == .running {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: status.symbol).font(.system(size: 9, weight: .bold))
            }
            Text(label ?? status.label).font(DS.Fonts.captionStrong)
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Contenitore delle schede

struct Card<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String?
    var status: ItemStatus?
    var statusLabel: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: 10) {
                accessory
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(DS.Fonts.bodyStrong)
                    if let subtitle { Text(subtitle).font(DS.Fonts.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                if let status { StatusPill(status: status, label: statusLabel) }
            }
            content
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: DS.readingWidth, alignment: .leading)
        .modifier(CardSurface(radius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Superficie delle schede: vetro sull'aurora; nel pannello di destra (già in vetro) un velo leggero, per non sovrapporre vetro a vetro.
struct CardSurface: ViewModifier {
    var radius: CGFloat = 22
    @Environment(\.compactLayout) private var compact

    func body(content: Content) -> some View {
        if compact {
            content
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        }
    }
}

/// Banner in linea per conferme e avvisi dentro le schede.
struct InlineBanner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(DS.Fonts.body).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, 10)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }
}

// MARK: - Orb

enum OrbState: Equatable {
    case idle, listening, thinking, waiting, done, error

    var label: String {
        switch self {
        case .idle: String(localized: "Pronto")
        case .listening: String(localized: "In ascolto…")
        case .thinking: String(localized: "Sto elaborando…")
        case .waiting: String(localized: "In attesa della tua conferma")
        case .done: String(localized: "Fatto")
        case .error: String(localized: "Serve la tua attenzione")
        }
    }

    fileprivate var palette: [Color] {
        switch self {
        case .idle, .listening, .thinking:
            [Color(hex: 0x5AC8FA), Color(hex: 0x6E6BFF), Color(hex: 0xC86BFA), Color(hex: 0xFF6F91), Color(hex: 0x64E3FF)]
        case .waiting:
            [Color(hex: 0xFFB547), Color(hex: 0xFF8A5B), Color(hex: 0xFFD36B), Color(hex: 0xFF9F43), Color(hex: 0xFFC98A)]
        case .done:
            [Color(hex: 0x34D399), Color(hex: 0x5AC8FA), Color(hex: 0x7BE495), Color(hex: 0x3CC2A6), Color(hex: 0xA7F3D0)]
        case .error:
            [Color(hex: 0xFF6B6B), Color(hex: 0xFF8FA3), Color(hex: 0xB8BEC9), Color(hex: 0xE0677A), Color(hex: 0xFFB3B3)]
        }
    }

    fileprivate var speed: Double {
        switch self {
        case .idle: 0.22
        case .listening: 0.8
        case .thinking: 1.5
        case .waiting: 0.35
        case .done: 0.5
        case .error: 0.28
        }
    }

    fileprivate var pulse: (amount: Double, rate: Double) {
        switch self {
        case .idle: (0.015, 0.8)
        case .listening: (0.06, 4)
        case .thinking: (0.025, 2.4)
        case .waiting: (0.035, 1.4)
        case .done: (0.02, 1)
        case .error: (0.02, 1)
        }
    }
}

/// Sfera tridimensionale di Siri AI+: macchie di colore in movimento lento dentro una bolla di vetro.
struct OrbView: View {
    var state: OrbState = .idle
    var size: CGFloat = 28
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Con la finestra in secondo piano l'orb si ferma: niente lavoro per chi non guarda.
    @Environment(\.controlActiveState) private var activeState
    /// Diagnostica: SIRIAI_SKY_ALWAYS=1 anima anche nelle finestre di prova (per misurare i consumi).
    private static let alwaysAnimate = ProcessInfo.processInfo.environment["SIRIAI_SKY_ALWAYS"] != nil

    var body: some View {
        TimelineView(.animation(minimumInterval: state == .idle ? 1 / 10 : 1 / 30,
                                // A riposo l'orb è fermo (come Siri): ogni suo fotogramma costringe a ridisegnare il vetro che lo contiene.
                                paused: !animated || reduceMotion || state == .idle || (activeState == .inactive && !Self.alwaysAnimate))) { context in
            let t = animated && !reduceMotion ? context.date.timeIntervalSinceReferenceDate : 12
            let scale = 1 + state.pulse.amount * sin(t * state.pulse.rate * .pi)
            ZStack {
                if state == .listening || state == .thinking {
                    Circle()
                        .fill(RadialGradient(colors: [state.palette[1].opacity(0.35), .clear], center: .center, startRadius: size * 0.3, endRadius: size * 0.75))
                        .frame(width: size * 1.5, height: size * 1.5)
                        .scaleEffect(1 + 0.08 * sin(t * 3))
                }
                Canvas { gc, canvasSize in
                    draw(in: &gc, size: canvasSize, t: t)
                }
                .frame(width: size, height: size)
                .scaleEffect(scale)
            }
            .frame(width: size, height: size)
        }
        .id(state)
        .transition(.opacity.animation(.easeInOut(duration: 0.4)))
        .accessibilityLabel("Siri AI+: \(state.label)")
    }

    private func draw(in gc: inout GraphicsContext, size canvasSize: CGSize, t: Double) {
        let rect = CGRect(origin: .zero, size: canvasSize)
        let r = canvasSize.width / 2
        let center = CGPoint(x: r, y: r)
        let colors = state.palette
        let speed = state.speed
        let circle = Path(ellipseIn: rect)

        gc.clip(to: circle)
        gc.fill(circle, with: .radialGradient(Gradient(colors: [colors[0].opacity(0.9), colors[1]]), center: center, startRadius: 0, endRadius: r))

        // Macchie di colore morbide con sfumature radiali: stesso effetto della sfocatura, a una frazione del costo.
        for i in 0..<4 {
            let phase = Double(i) * 1.7
            let orbit = r * (0.28 + 0.1 * Double(i % 2))
            let angle = t * speed * (i.isMultiple(of: 2) ? 1 : -0.8) + phase
            let p = CGPoint(x: center.x + orbit * cos(angle), y: center.y + orbit * sin(angle * 1.1))
            let blobR = r * (0.85 + 0.1 * sin(t * speed * 1.3 + phase))
            let color = colors[(i + 1) % colors.count]
            gc.fill(Path(ellipseIn: CGRect(x: p.x - blobR, y: p.y - blobR, width: blobR * 2, height: blobR * 2)),
                    with: .radialGradient(Gradient(stops: [.init(color: color.opacity(0.95), location: 0),
                                                           .init(color: color.opacity(0.6), location: 0.45),
                                                           .init(color: color.opacity(0), location: 1)]),
                                          center: p, startRadius: 0, endRadius: blobR))
        }

        // Ombreggiatura e riflesso: danno volume alla sfera.
        gc.fill(circle, with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.22)]),
                                               center: CGPoint(x: r * 1.25, y: r * 1.35), startRadius: r * 0.2, endRadius: r * 1.4))
        gc.fill(circle, with: .radialGradient(Gradient(colors: [.white.opacity(0.85), .white.opacity(0)]),
                                               center: CGPoint(x: r * 0.68, y: r * 0.55), startRadius: 0, endRadius: r * 0.62))
        gc.stroke(Path(ellipseIn: rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.white.opacity(0.55)), lineWidth: max(0.5, r * 0.03))
    }
}


// MARK: - Componenti comuni

/// Azioni in fondo a una scheda: sempre nello stesso ordine (spiegazione, secondarie, principale a destra).
struct CardActions<Secondary: View>: View {
    var note: String?
    var primary: String
    var primaryRole: ButtonRole?
    var primaryDisabled = false
    var cancel: (() -> Void)?
    @ViewBuilder var secondary: Secondary
    let action: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.sm) { noteView; Spacer(minLength: DS.Space.sm); buttons }
            VStack(alignment: .trailing, spacing: DS.Space.sm) { noteView.frame(maxWidth: .infinity, alignment: .leading); HStack(spacing: DS.Space.sm) { buttons } }
        }
    }

    @ViewBuilder private var noteView: some View {
        if let note { Text(note).font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }

    @ViewBuilder private var buttons: some View {
        secondary
        if let cancel { Button("Annulla", action: cancel).keyboardShortcut(.cancelAction) }
        Button(primary, role: primaryRole, action: action)
            .buttonStyle(.borderedProminent)
            .tint(primaryRole == .destructive ? .red : .accentColor)
            .disabled(primaryDisabled)
    }
}

extension CardActions where Secondary == EmptyView {
    init(note: String? = nil, primary: String, primaryRole: ButtonRole? = nil, primaryDisabled: Bool = false,
         cancel: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.init(note: note, primary: primary, primaryRole: primaryRole, primaryDisabled: primaryDisabled, cancel: cancel,
                  secondary: { EmptyView() }, action: action)
    }
}

/// Area di testo dentro una scheda (bozze, contenuti di file, argomenti).
struct CardTextArea<Content: View>: View {
    var minHeight: CGFloat = 80
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(DS.Space.sm)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
    }
}

/// Avviso temporaneo in basso (salvataggi, conferme): si chiude da solo.
struct ToastView: View {
    let toast: AppState.Toast

    var body: some View {
        Label(toast.text, systemImage: toast.symbol)
            .font(DS.Fonts.callout)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .accessibilityAddTraits(.isStaticText)
    }
}

extension View {
    /// Aiuto al passaggio del mouse e nome per VoiceOver insieme (per i pulsanti con la sola icona).
    func iconHelp(_ text: String) -> some View {
        help(text).accessibilityLabel(text)
    }
}
