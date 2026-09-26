import AppKit
import SiriCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Composer

struct Composer: View {
    @Environment(AppState.self) private var state
    @Environment(\.compactLayout) private var compact
    var placeholder = String(localized: "Chiedi a Siri AI+…")
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPicker = false
    @State private var showImporter = false
    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            if !state.picked.isEmpty || !state.attachments.isEmpty || state.planNext {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if state.planNext {
                            Chip(label: String(localized: "Piano con sub-agent"), leading: AnyView(Image(systemName: "list.bullet.clipboard").font(.system(size: 11)))) {
                                state.planNext = false
                            }
                            .help("La richiesta diventa un compito a passi: catena di pensieri, sub-agent (anche in parallelo) e risposta finale")
                        }
                        ForEach(Array(state.picked).sorted { $0.rawValue < $1.rawValue }) { source in
                            Chip(label: source.label, leading: AnyView(Tile(source, size: 14))) { state.picked.remove(source) }
                        }
                        ForEach(state.attachments) { file in
                            Chip(label: file.name, leading: AnyView(Image(systemName: file.imageURL == nil ? "doc" : "photo").font(.system(size: 11)))) {
                                state.attachments.removeAll { $0.id == file.id }
                            }
                        }
                    }
                }
            }
            if state.dictation.isListening {
                HStack(spacing: 10) {
                    Waveform(level: state.dictation.level)
                    Text(state.dictation.transcript.isEmpty ? String(localized: "In ascolto…") : state.dictation.transcript)
                        .font(DS.Fonts.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if let error = state.dictation.error {
                Text(error).font(DS.Fonts.caption).foregroundStyle(.orange)
            }
            if state.currentIsResponding {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(state.orbLabel).font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("In corso").font(DS.Fonts.micro).foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
            }
            TextField(state.planNext ? String(localized: "Descrivi il compito: lo divido in passi e lo affido ai sub-agent…") : placeholder,
                      text: $state.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit { state.send() }
                .disabled(state.availabilityProblem != nil)
            HStack(spacing: 4) {
                toolsMenu
                Button {
                    showPicker.toggle()
                } label: {
                    HStack(spacing: 5) {
                        if state.picked.isEmpty {
                            Image(systemName: "square.stack.3d.up").font(.system(size: 12, weight: .medium))
                            if !compact { Text("Fonti").font(DS.Fonts.caption) }
                        } else {
                            Text("\(state.picked.count) fonti").font(DS.Fonts.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Scegli le fonti per questa richiesta")
                .popover(isPresented: $showPicker, arrowEdge: .top) { SourcePicker() }
                ModelMenu()
                Spacer()
                ComposerButton(symbol: "waveform.circle", help: String(localized: "Modalità vocale (⌥⌘V)")) { state.voice.start(with: state) }
                ComposerButton(symbol: state.dictation.isListening ? "waveform" : "mic",
                               help: state.dictation.isListening ? String(localized: "Termina la dettatura") : String(localized: "Detta"),
                               active: state.dictation.isListening) {
                    state.dictation.toggle { text in
                        state.input = state.input.isEmpty ? text : state.input + " " + text
                    }
                }
                if state.currentIsResponding {
                    Button { state.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 28, height: 28).background(Color.primary.opacity(0.75), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .iconHelp(String(localized: "Interrompi"))
                } else {
                    Button { state.send() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(state.canSend ? Color.accentColor : Color.secondary.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!state.canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .iconHelp(String(localized: "Invia (⌘↩)"))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .modifier(IntelligenceSurface(active: state.currentIsResponding, radius: DS.Radius.composer))
        .frame(maxWidth: DS.readingWidth)
        .padding(.horizontal, compact ? 12 : 28)
        .padding(.bottom, compact ? 12 : 16)
        .frame(maxWidth: .infinity)
        .onAppear { focused = true }
        .onChange(of: state.composerFocusRequest) { focused = true }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .pdf, .rtf, .text, .utf8PlainText, .image],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { state.attach(urls) }
        }
        // Documenti, foto e screenshot trascinati sul campo di scrittura diventano allegati.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            state.attach(files)
            return true
        }
    }
}

extension Composer {
    /// Il menu «+»: tutto ciò che Siri AI+ sa fare, in un posto solo (come in ChatGPT).
    var toolsMenu: some View {
        let connected = state.mcp.servers.filter { server in
            if case .ready = state.mcp.status[server.id] ?? .off { return true } else { return false }
        }
        return Menu {
            Button { showImporter = true } label: { Label("Allega file…", systemImage: "paperclip") }
            Button { begin(String(localized: "Genera un'immagine di ")) } label: { Label("Crea un'immagine", systemImage: "photo.on.rectangle.angled") }
            Button { begin(String(localized: "Cerca sul web ")) } label: { Label("Cerca sul web", systemImage: "globe") }
            // Come «Ricerca approfondita» in ChatGPT: la prossima richiesta diventa un compito a passi, con qualunque modello.
            Toggle(isOn: Bindable(state).planNext) { Label("Piano con sub-agent", systemImage: "list.bullet.clipboard") }
            Divider()
            Button { state.newArtifact(.pages) } label: { Label("Nuovo documento", systemImage: "doc.richtext") }
            Button { state.newArtifact(.numbers) } label: { Label("Nuovo foglio di calcolo", systemImage: "tablecells") }
            Button { state.newArtifact(.keynote) } label: { Label("Nuova presentazione", systemImage: "play.rectangle") }
            Divider()
            Button { state.editingAgent = AgentSpec(name: "", goal: "") } label: { Label("Nuovo Genius…", systemImage: "person.badge.plus") }
            if !connected.isEmpty {
                Menu {
                    ForEach(connected) { server in
                        Button("Usa \(server.name)") { begin("@\(server.name) ") }
                    }
                } label: { Label("Usa un connettore", systemImage: "puzzlepiece.extension") }
            }
            Button { state.voice.start(with: state) } label: { Label("Modalità vocale", systemImage: "waveform") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Allega, crea immagini e documenti, cerca sul web, piano con sub-agent, Genius e connettori")
    }

    /// Prepara la richiesta con un inizio («Genera un'immagine di …») e riporta il cursore nel campo.
    func begin(_ prefix: String) {
        if !state.input.hasPrefix(prefix) { state.input = prefix + state.input }
        focused = true
    }
}

struct ComposerButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 28, height: 28)
                .background(active ? Color.accentColor.opacity(0.12) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct Chip: View {
    let label: String
    let leading: AnyView
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            leading
            Text(label).font(DS.Fonts.caption).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rimuovi \(label)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

struct Waveform: View {
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<5) { i in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 4 + 14 * max(0.15, level) * (0.6 + 0.4 * sin(t * 9 + Double(i))))
                }
            }
            .frame(height: 18)
        }
    }
}

// MARK: - Selettore fonti

struct SourcePicker: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Fonti per questa richiesta").font(DS.Fonts.bodyStrong)
                Text("Senza selezione, Siri AI+ sceglie da sola tra le fonti collegate.").font(DS.Fonts.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 8), count: 4), spacing: 12) {
                ForEach(SourceKind.allCases.filter(\.usableInChat)) { source in
                    SourcePickerCell(source: source)
                }
            }
            HStack {
                Button("Automatiche") { state.picked.removeAll() }
                    .disabled(state.picked.isEmpty)
                Spacer()
                Button("Applica") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 340)
    }
}

struct SourcePickerCell: View {
    @Environment(AppState.self) private var state
    let source: SourceKind

    private var available: Bool { state.isEnabled(source) }
    private var selected: Bool { state.picked.contains(source) }

    var body: some View {
        Button {
            if selected { state.picked.remove(source) } else { state.picked.insert(source) }
        } label: {
            VStack(spacing: 6) {
                Tile(source, size: 34, dimmed: !available)
                    .overlay(alignment: .bottomTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .offset(x: 5, y: 5)
                        }
                    }
                Text(source.label).font(DS.Fonts.caption).lineLimit(1)
                Text(available ? " " : (source.support == .comingSoon ? String(localized: "In arrivo") : String(localized: "Non collegata")))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 72)
            .padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityLabel("\(source.label)\(selected ? String(localized: ", selezionata") : "")")
    }
}

/// Scelta del modello che risponde, direttamente dal campo di scrittura (solo quelli configurati): per ChatGPT e Claude
/// anche la versione e il ragionamento. Vale per la chat aperta.
struct ModelMenu: View {
    @Environment(AppState.self) private var state
    @Environment(\.compactLayout) private var compact

    var body: some View {
        if state.current?.kind == .quick {
            Label("Apple Intelligence sul Mac", systemImage: "apple.logo")
                .font(DS.Fonts.caption).foregroundStyle(.secondary)
                .help("Per una prova con ChatGPT o Claude usa l'anteprima nella Chat rapida.")
        } else {
            ModelPicker(current: state.selection, compact: compact, showsTools: true) { state.choose($0) }
        }
    }
}
