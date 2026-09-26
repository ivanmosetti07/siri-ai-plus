import SiriCore
import SwiftUI

/// Siri AI+ nella colonna destra: sempre la stessa conversazione, consapevole di ciò che è aperto al centro.
struct AssistantPanel: View {
    @Environment(AppState.self) private var state

    /// Ciò che è aperto al centro: le app e i documenti con la loro icona, i progetti con la cartella.
    private enum ContextIcon {
        case tile(Tile)
        case symbol(String)
    }

    private var contextLabel: (icon: ContextIcon, text: String)? {
        switch state.section {
        // Con un elemento selezionato il riquadro dice quale («Fattura di marzo»): Siri AI+ lavora su quello.
        case .app(let source): (.tile(Tile(source, size: 14)), state.screenItem.flatMap { $0.kind == .overview ? nil : $0.title } ?? source.label)
        case .browser: (.tile(.safari(size: 14)), state.browser.url == nil ? "Safari" : state.browser.title.isEmpty ? "questa pagina" : state.browser.title)
        case .artifact: state.openArtifact.map { (.tile(Tile($0.kind, size: 14)), $0.title) }
        case .appLauncher: nil
        case .file(let url): (.symbol("doc.text"), url.lastPathComponent)
        case .chats: (.symbol("bubble.left.and.bubble.right"), "chat affiancate")
        case .documents(let kind): (.tile(Tile(kind, size: 14)), kind.app)
        case .project: state.currentProject.map { (.symbol("folder.fill"), $0.name) }
        default: state.currentProject.map { (.symbol("folder.fill"), $0.name) }
        }
    }

    private var suggestions: [String] {
        if let item = state.screenItem, !item.suggestions.isEmpty { return item.suggestions }
        return switch state.section {
        case .app(.calendar): ["Cosa ho questa settimana?", "Fissa una riunione domani alle 10", "Sono libero giovedì pomeriggio?"]
        case .app(.reminders): ["Cosa devo fare oggi?", "Crea i promemoria per il lancio", "Ricordami di chiamare Marco venerdì alle 9"]
        case .app(.mail): ["Scrivi un'email al team con gli aggiornamenti", "Prepara una risposta cortese per rimandare la call"]
        case .documents(.pages): ["Scrivi una relazione sul lancio del prodotto", "Prepara una lettera di presentazione", "Scrivi il verbale della riunione di oggi"]
        case .documents(.numbers): ["Crea un budget mensile con entrate e uscite", "Prepara una tabella per confrontare tre preventivi", "Crea un piano dei pagamenti per il 2027"]
        case .documents(.keynote): ["Crea una presentazione sul progetto in 6 slide", "Prepara le slide per la riunione di lunedì", "Trasforma i miei appunti in una presentazione"]
        case .artifact:
            switch state.openArtifact?.kind {
            case .pages?: ["Aggiungi una sezione sui rischi", "Rendi il tono più formale", "Riassumi il documento in 5 punti"]
            case .numbers?: ["Qual è la voce più costosa?", "Aggiungi un foglio con lo scenario pessimista"]
            case .keynote?: ["Aggiungi due slide sui prossimi passi", "Genera un'immagine per la copertina"]
            case nil: []
            }
        case .browser:
            state.browser.url == nil
                ? ["Apri il sito del Post", "Cerca le recensioni del nuovo MacBook Air", "Quali sono le notizie di oggi?"]
                : ["Riassumi questa pagina", "Quali sono i punti principali?", "Traduci in italiano i passaggi chiave"]
        case .project: ["Quali file ci sono nel progetto?", "Riassumi il file AGENTS.md", "Crea un file note-riunione.md con l'ordine del giorno"]
        case .schedule, .agents:
            ["Cosa fanno gli agenti stanotte?", "Crea un agente che ogni lunedì alle 9 prepara la settimana", "Quali agenti aspettano una mia approvazione?"]
        default:
            state.space == .personale
                ? ["Cosa ho oggi?", "Crea una nota con la lista della spesa", "Idee per il weekend"]
                : ["Organizza la mia giornata", "Che tempo fa domani a \(state.weather.city)?", "Spiegami come funziona un mutuo a tasso variabile", "Genera un'immagine di un faro al tramonto"]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let conversation = state.current, conversation.parentID != nil { ChildChatBanner(conversation: conversation) }
            if let conversation = state.current, !conversation.messages.isEmpty {
                ConversationThread(conversation: conversation)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Spacer()
                    OrbView(state: state.orb, size: 44).frame(maxWidth: .infinity).padding(.bottom, 10)
                    Text("Chiedi a Siri AI+").font(DS.Fonts.section).frame(maxWidth: .infinity).padding(.bottom, 8)
                    ForEach(suggestions, id: \.self) { text in
                        SuggestionRow(symbol: "sparkle", text: text) { state.send(text) }
                    }
                    Spacer()
                }
                .padding(12)
                .frame(maxHeight: .infinity)
            }
            // Nella chat già avviata, azioni rapide su ciò che è selezionato nell'app («Rispondi a Mario», «Riassumi questa nota»).
            if let item = state.screenItem, !item.suggestions.isEmpty, let conversation = state.current, !conversation.messages.isEmpty, !state.isResponding {
                ScreenActionsRow(suggestions: Array(item.suggestions.prefix(3))) { state.send($0) }
            }
            Composer(placeholder: contextLabel.map { "Chiedi a Siri AI+ su \($0.text)…" } ?? "Chiedi a Siri AI+…")
        }
        .environment(\.compactLayout, true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            OrbView(state: state.orb, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(state.current?.title ?? "Siri AI+").font(DS.Fonts.bodyStrong).lineLimit(1)
                // Chat di un progetto: il progetto resta il contesto anche con le app aperte, e si vede.
                if let project = state.current?.projectID.flatMap({ id in state.projects.first { $0.id == id } }) {
                    (Text(Image(systemName: "folder.fill")) + Text(" \(project.name) · \(state.orbLabel)"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .help("Chat del progetto «\(project.name)»: la sua cartella resta il contesto, in lettura e scrittura, anche con le app aperte")
                } else {
                    Text(state.orbLabel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let context = contextLabel {
                Label {
                    Text(context.text)
                } icon: {
                    switch context.icon {
                    case .tile(let tile): tile
                    case .symbol(let name): Image(systemName: name)
                    }
                }
                    .font(DS.Fonts.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .frame(maxWidth: 130)
                    .help("Siri AI+ sta lavorando su \(context.text)")
            }
            ContextRing(usage: state.contextUsage, threshold: state.compactionThreshold,
                        model: state.activeModelLabel, window: state.contextBudget.label)
            Menu {
                Button("Nuova conversazione") { state.newConversationHere() }
                Button("Nuova chat figlia…") { state.showChildSheet = true }
                    .disabled(state.current?.messages.isEmpty != false)
                Button("Modalità vocale") { state.voice.start(with: state) }
                Button("Compatta ora") { state.compactNow() }
                    .disabled(state.isResponding || state.current?.messages.isEmpty != false)
                Divider()
                if let current = state.current, !current.messages.isEmpty {
                    Button(current.pinned ? "Togli dai fissati" : "Fissa conversazione") { state.togglePin(current) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// Anello che mostra quanta finestra di contesto usa la conversazione; si colora avvicinandosi alla soglia.
struct ContextRing: View {
    let usage: Double
    let threshold: Double
    var model = "Apple Intelligence"
    var window = ContextBudget.apple.label

    private var tint: Color { usage >= threshold ? .orange : usage >= threshold * 0.75 ? .yellow : .secondary }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, usage)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .animation(.smooth, value: usage)
        .help("Contesto usato: \(Int(usage * 100))% della finestra di \(model) (\(window)). Oltre il \(Int(threshold * 100))% la conversazione viene compattata o accorciata automaticamente.")
        .accessibilityLabel("Contesto usato \(Int(usage * 100)) per cento")
    }
}

/// Azioni rapide sull'elemento selezionato nell'app, sopra il campo di scrittura.
private struct ScreenActionsRow: View {
    let suggestions: [String]
    let send: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { text in
                    Button { send(text) } label: {
                        Label(text, systemImage: "sparkle")
                            .font(DS.Fonts.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(text)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
    }
}
