import AppKit
import SiriCore
import SwiftUI

// MARK: - Struttura comune delle app
//
// Tutte le app (Calendario, Promemoria, Mail, Note, File, Messaggi) hanno la stessa forma, come un'unica app Apple:
// intestazione con icona, titolo, ricerca e azioni · colonna delle fonti (liste, caselle, cartelle) · elenco · dettaglio.

/// Intestazione di un'app: icona, titolo e sottotitolo, ricerca, azioni e menu «Altro».
/// Per le app di Apple `source`, per Pages, Numbers e Keynote di Siri AI+ `kind`.
struct AppHeader<Actions: View>: View {
    var source: SourceKind?
    var kind: ArtifactKind?
    let title: String
    var subtitle: String?
    var search: Binding<String>?
    var searchPrompt = "Cerca"
    var onSearch: (() -> Void)?
    var onRefresh: (() -> Void)?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            if let kind { Tile(kind, size: 30) } else if let source { Tile(source, size: 30) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 19, weight: .bold)).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let search {
                AppSearchField(text: search, prompt: searchPrompt, onSubmit: onSearch)
                    .frame(minWidth: 140, maxWidth: 240)
            }
            HStack(spacing: 6) { actions }
                .controlSize(.regular)
            Menu {
                if let source { Button("Apri \(source.systemAppName)") { source.openSystemApp() } }
                if kind != nil {
                    Button("Mostra i documenti salvati nel Finder") { NSWorkspace.shared.open(ArtifactFactory.defaultFolder) }
                }
                if let onRefresh { Button("Aggiorna", action: onRefresh).keyboardShortcut("r") }
                if source != nil {
                    Divider()
                    Button("Permessi delle app…") { AppState.shared?.openSettings("App") }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .iconHelp("Altro")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

extension AppHeader where Actions == EmptyView {
    init(source: SourceKind, title: String, subtitle: String? = nil) {
        self.init(source: source, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Campo di ricerca arrotondato, come nelle barre degli strumenti di macOS.
struct AppSearchField: View {
    @Binding var text: String
    var prompt = "Cerca"
    var onSubmit: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .onSubmit { onSubmit?() }
            if !text.isEmpty {
                Button { text = ""; onSubmit?() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .iconHelp("Cancella la ricerca")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

/// Pulsante con icona per le intestazioni (Nuovo, Elimina, Rispondi…).
struct AppIconButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let symbol: String
    let help: String
    var prominent = false
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(prominent ? Color.accentColor : Color.primary)
        .opacity(isEnabled ? 1 : 0.3)
        .iconHelp(help)
    }
}

/// Tre colonne: fonti · elenco · dettaglio. Sotto una certa larghezza la colonna delle fonti si nasconde
/// (ci si arriva dal menu nell'elenco) e il dettaglio resta sempre visibile.
struct AppColumns<Sources: View, Items: View, Detail: View>: View {
    var sourcesWidth: CGFloat = 214
    var itemsWidth: CGFloat = 320
    @ViewBuilder var sources: Sources
    @ViewBuilder var items: Items
    @ViewBuilder var detail: Detail

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= sourcesWidth + itemsWidth + 380
            let listWidth = min(itemsWidth, max(240, geometry.size.width * 0.38))
            HStack(spacing: 0) {
                if wide {
                    sources
                        .frame(width: sourcesWidth)
                        .background(Color.primary.opacity(0.025))
                    Divider()
                }
                items
                    .frame(width: listWidth)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .environment(\.appSourcesVisible, wide)
        }
    }
}

/// Fonti · contenuto · pannello dei dettagli (solo quando c'è qualcosa aperto), come Promemoria e Calendario.
/// Se lo spazio non basta la colonna delle fonti si nasconde e il contenuto mostra un menu al suo posto.
struct AppSplit<Sources: View, Main: View, Inspector: View>: View {
    var sourcesWidth: CGFloat = 220
    var inspectorWidth: CGFloat = 310
    var minimumMain: CGFloat = 400
    var showInspector: Bool
    @ViewBuilder var sources: Sources
    @ViewBuilder var main: Main
    @ViewBuilder var inspector: Inspector

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width - (showInspector ? inspectorWidth : 0) >= sourcesWidth + minimumMain
            HStack(spacing: 0) {
                if wide {
                    sources
                        .frame(width: sourcesWidth)
                        .background(Color.primary.opacity(0.025))
                    Divider()
                }
                main
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showInspector {
                    Divider()
                    inspector
                        .frame(width: inspectorWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .environment(\.appSourcesVisible, wide)
            .animation(DS.Motion.standard, value: showInspector)
        }
    }
}

private struct AppSourcesVisibleKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// Falso quando la colonna delle fonti è nascosta (finestra stretta): l'elenco mostra un menu per sceglierle.
    var appSourcesVisible: Bool {
        get { self[AppSourcesVisibleKey.self] }
        set { self[AppSourcesVisibleKey.self] = newValue }
    }
}

/// Riga della colonna delle fonti: icona colorata, nome, numero.
struct SourceRowLabel: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor
    var count: Int?
    var indent = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            if let count, count > 0 {
                Text("\(count)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.leading, CGFloat(indent) * 14)
    }
}

/// Testa dell'elenco centrale: titolo grande colorato e numero (come in Promemoria).
struct ListHeading<Trailing: View>: View {
    let title: String
    var tint: Color = .primary
    var count: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Nelle colonne strette il titolo si rimpicciolisce prima di troncarsi («Tutte le no…»).
            Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
            Spacer(minLength: 6)
            trailing
            if let count { Text(count).font(.system(size: 20, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

extension ListHeading where Trailing == EmptyView {
    init(title: String, tint: Color = .primary, count: String? = nil) {
        self.init(title: title, tint: tint, count: count) { EmptyView() }
    }
}

/// Stato vuoto leggero dentro le app (nessun elemento, niente selezionato, errore).
struct AppPlaceholder: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let message {
                Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.glass).padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Avviso di permesso mancante dentro un'app, con il pulsante che risolve.
struct AccessNotice: View {
    let symbol: String
    let title: String
    let message: String
    var primary: (label: String, action: () -> Void)?
    var secondary: (label: String, action: () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(LinearGradient(colors: Hue.orange, startPoint: .top, endPoint: .bottom), in: Circle())
            Text(title).font(.system(size: 17, weight: .bold)).multilineTextAlignment(.center)
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let primary { Button(primary.label, action: primary.action).buttonStyle(.glassProminent) }
                if let secondary { Button(secondary.label, action: secondary.action).buttonStyle(.glass) }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Gruppo di campi nel pannello dei dettagli (come le sezioni di un modulo di sistema).
struct InspectorGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// Riga etichetta + controllo in un gruppo del pannello dei dettagli.
struct InspectorRow<Content: View>: View {
    let label: String
    var divider = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            if divider { Divider().opacity(0.6) }
        }
    }
}

/// Barra in fondo al pannello dei dettagli: azioni distruttive a sinistra, salvataggio a destra.
struct InspectorFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Iniziali su un cerchio colorato (mittenti di Mail, conversazioni di Messaggi).
struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 32

    private var initials: String {
        let words = name.replacingOccurrences(of: "\"", with: "").split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
        let letters = words.prefix(2).compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private var colors: [Color] {
        let palette = [Hue.blue, Hue.green, Hue.orange, Hue.purple, Hue.pink, Hue.teal, Hue.indigo, Hue.red]
        let index = abs(name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % palette.count
        return palette[index]
    }

    var body: some View {
        Group {
            if initials.contains(where: \.isLetter) {
                Text(initials).font(.system(size: size * 0.38, weight: .semibold))
            } else {
                // Numeri ed email senza nome nei Contatti.
                Image(systemName: "person.fill").font(.system(size: size * 0.42))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom), in: Circle())
        .accessibilityHidden(true)
    }
}

extension Date {
    /// Come negli elenchi di Mail e Messaggi: ora se è oggi, «Ieri», giorno della settimana, poi la data.
    var listStamp: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return formatted(.dateTime.hour().minute().locale(Dates.locale)) }
        if cal.isDateInYesterday(self) { return "Ieri" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: self), to: cal.startOfDay(for: .now)).day, days < 7 {
            return formatted(.dateTime.weekday(.wide).locale(Dates.locale)).capitalized
        }
        return formatted(.dateTime.day().month(.twoDigits).year(.twoDigits).locale(Dates.locale))
    }
}

/// Prove dell'interfaccia (`--ephemeral --select-first`): ogni app apre il primo elemento, senza modificare nulla.
enum AppTesting {
    static let ephemeral = CommandLine.arguments.contains("--ephemeral")
    static let selectFirst = CommandLine.arguments.contains("--select-first") && ephemeral

    /// Valore dopo un argomento di prova (`--calendar-mode Mese`), solo nelle istanze di prova.
    static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard ephemeral, let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

extension AppState {
    /// Esito di un'azione fatta nelle app: toast e riga nel registro delle attività.
    func appDone(_ source: SourceKind, _ title: String, detail: String = "") {
        showToast(title)
        log(icon: "source:\(source.rawValue)", title: title, detail: detail.isEmpty ? source.label : detail, status: .done)
    }

    func appFailed(_ source: SourceKind, _ title: String, _ error: Error) {
        showToast("\(title): \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
        log(icon: "source:\(source.rawValue)", title: title, detail: error.localizedDescription, status: .failed)
    }
}
