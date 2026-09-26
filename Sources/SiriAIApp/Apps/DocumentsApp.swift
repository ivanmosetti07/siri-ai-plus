import AppKit
import SiriCore
import SwiftUI

// MARK: - Pages, Numbers e Keynote (i documenti di Siri AI+)
//
// Come le app di iWork: i documenti con le anteprime, «Nuovo» e «Crea con Siri AI+» (la richiesta parte nella chat a destra).
// Ogni documento si apre in una scheda con il suo editor; Siri AI+ vede quello davanti e lo modifica.
// I documenti vivono nelle chat in cui sono nati (come prima): qui si vedono tutti insieme.

extension ArtifactKind {
    var newLabel: String {
        switch self {
        case .pages: String(localized: "Nuovo documento")
        case .numbers: String(localized: "Nuovo foglio di calcolo")
        case .keynote: String(localized: "Nuova presentazione")
        }
    }

    func countLabel(_ count: Int) -> String {
        switch self {
        case .pages: count == 0 ? String(localized: "Nessun documento") : count == 1 ? String(localized: "1 documento") : String(localized: "\(count) documenti")
        case .numbers: count == 0 ? String(localized: "Nessun foglio di calcolo") : count == 1 ? String(localized: "1 foglio di calcolo") : String(localized: "\(count) fogli di calcolo")
        case .keynote: count == 0 ? String(localized: "Nessuna presentazione") : count == 1 ? String(localized: "1 presentazione") : String(localized: "\(count) presentazioni")
        }
    }

    var searchPrompt: String {
        switch self {
        case .pages: String(localized: "Cerca nei documenti")
        case .numbers: String(localized: "Cerca nei fogli")
        case .keynote: String(localized: "Cerca nelle presentazioni")
        }
    }

    /// Inizio della richiesta quando lo si fa scrivere a Siri AI+.
    var assistantPrompt: String {
        switch self {
        case .pages: String(localized: "Scrivi un documento su ")
        case .numbers: String(localized: "Crea un foglio di calcolo per ")
        case .keynote: String(localized: "Crea una presentazione su ")
        }
    }

    /// Anteprima: pagina verticale, foglio orizzontale, slide 16:9.
    var thumbnailSize: CGSize {
        switch self {
        case .pages: CGSize(width: 150, height: 194)
        case .numbers: CGSize(width: 196, height: 146)
        case .keynote: CGSize(width: 224, height: 126)
        }
    }
}

extension AppState {
    struct DocumentEntry: Identifiable {
        let artifact: ArtifactModel
        let conversation: Conversation
        var id: UUID { artifact.id }
        /// Ultima modifica; per i documenti di prima, la data della loro chat.
        var date: Date { artifact.modified ?? conversation.created }
    }

    /// Documenti di un tipo, dal più recente, con la chat in cui sono nati.
    func documents(of kind: ArtifactKind) -> [DocumentEntry] {
        var result: [DocumentEntry] = []
        for conversation in conversations {
            for message in conversation.messages {
                if case .artifact(let artifact) = message.content, artifact.kind == kind {
                    result.append(DocumentEntry(artifact: artifact, conversation: conversation))
                }
            }
        }
        return result.sorted { $0.date > $1.date }
    }

    func artifact(_ id: UUID) -> ArtifactModel? {
        for conversation in conversations {
            for message in conversation.messages {
                if case .artifact(let artifact) = message.content, artifact.id == id { return artifact }
            }
        }
        return nil
    }

    func conversation(containing artifact: ArtifactModel) -> Conversation? {
        conversations.first { conversation in
            conversation.messages.contains { if case .artifact(let item) = $0.content { item.id == artifact.id } else { false } }
        }
    }

    /// Copia subito dopo l'originale, nella stessa chat.
    func duplicateDocument(_ artifact: ArtifactModel) {
        guard let conversation = conversation(containing: artifact),
              let index = conversation.messages.firstIndex(where: { if case .artifact(let item) = $0.content { item.id == artifact.id } else { false } })
        else { return }
        let copy = ArtifactModel(kind: artifact.kind, title: String(localized: "\(artifact.title) copia"), content: artifact.content, projectID: artifact.projectID)
        copy.modified = .now
        conversation.messages.insert(Message(content: .artifact(copy)), at: index + 1)
        saveConversations()
        showToast(String(localized: "Copia creata: «\(copy.title)»"), symbol: "plus.square.on.square")
    }

    /// Toglie il documento dall'elenco e dalla sua chat (i file già salvati o esportati restano dove sono).
    func deleteDocument(_ artifact: ArtifactModel) {
        closeTabEverywhere(.document(artifact.id))
        if openArtifact?.id == artifact.id { openArtifact = nil }
        for conversation in conversations {
            conversation.messages.removeAll { if case .artifact(let item) = $0.content { item.id == artifact.id } else { false } }
        }
        saveConversations()
        log(icon: "artifact:\(artifact.kind.rawValue)", title: String(localized: "\(artifact.kind.noun) eliminat\(artifact.kind.ending)"), detail: artifact.title, status: .done)
        showToast(String(localized: "«\(artifact.title)» eliminat\(artifact.kind.ending)"), symbol: "trash")
    }

    /// Porta nella colonna destra la chat in cui è nato il documento.
    func showConversation(of artifact: ArtifactModel) {
        guard let conversation = conversation(containing: artifact) else { return }
        select(conversation)
    }

    /// «Crea con Siri AI+»: la richiesta comincia nel campo di scrittura della chat.
    func startDocumentWithAssistant(_ kind: ArtifactKind) {
        if !input.hasPrefix(kind.assistantPrompt) { input = kind.assistantPrompt + input }
        showAssistant = true
        composerFocusRequest += 1
    }
}

extension ArtifactModel {
    /// Testo in cui cercare: il documento, le celle dei fogli, i testi delle slide.
    var searchText: String {
        switch content {
        case .document(let text): String(text.string.prefix(4000))
        case .sheet(let spreadsheet): spreadsheet.sheets.flatMap { $0.cells.values }.joined(separator: " ")
        case .deck(let deck): deck.slides.flatMap { $0.elements.map(\.text) }.joined(separator: " ")
        }
    }
}

// MARK: - Vista

struct DocumentsAppView: View {
    @Environment(AppState.self) private var state
    let kind: ArtifactKind
    @State private var search = ""
    @State private var renaming: ArtifactModel?
    @State private var newTitle = ""
    @State private var deleting: ArtifactModel?

    private var entries: [AppState.DocumentEntry] {
        let all = state.documents(of: kind)
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.artifact.title.localizedCaseInsensitiveContains(query) || $0.artifact.searchText.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let entries = entries
        let size = kind.thumbnailSize
        VStack(spacing: 0) {
            AppHeader(kind: kind, title: kind.app, subtitle: kind.countLabel(state.documents(of: kind).count),
                      search: $search, searchPrompt: kind.searchPrompt) {
                Button { state.newArtifact(kind) } label: { Image(systemName: "plus") }
                    .iconHelp(kind.newLabel)
            }
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: size.width + 12, maximum: size.width + 48), spacing: 18, alignment: .top)],
                          alignment: .leading, spacing: 26) {
                    if search.isEmpty {
                        NewDocumentCard(kind: kind) { state.newArtifact(kind) }
                        AssistantDocumentCard(kind: kind) { state.startDocumentWithAssistant(kind) }
                    }
                    ForEach(entries) { entry in
                        DocumentCard(entry: entry, open: state.appTabs.contains(.document(entry.id))) { state.open(entry.artifact) }
                            .contextMenu { menu(for: entry) }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                if entries.isEmpty {
                    Text(search.isEmpty ? String(localized: "Quelli che crei qui o chiedi nella chat compaiono in questo elenco.") : String(localized: "Nessun risultato per «\(search)»."))
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 24)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .clipShape(.rect(cornerRadius: 26))
        .glassCard(radius: 26)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 14)
        // Siri AI+ sa quali documenti ci sono («apri il curriculum», «riassumi l'ultimo documento»).
        .onChange(of: state.documents(of: kind).map(\.id), initial: true) { _, _ in
            state.publish(.documents(kind, entries: state.documents(of: kind)), for: .docs(kind))
        }
        .alert("Rinomina", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Titolo", text: $newTitle)
            Button("Rinomina") {
                let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if let renaming, !title.isEmpty { renaming.title = title; state.saveConversations() }
                renaming = nil
            }
            Button("Annulla", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Eliminare «\(deleting?.title ?? "")»?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { artifact in
            Button("Elimina", role: .destructive) { state.deleteDocument(artifact) }
        } message: { _ in
            Text("Sparisce da questo elenco e dalla chat in cui è nato. I file già salvati o esportati restano dove sono.")
        }
    }

    @ViewBuilder
    private func menu(for entry: AppState.DocumentEntry) -> some View {
        Button("Apri") { state.open(entry.artifact) }
        Button("Rinomina…") { newTitle = entry.artifact.title; renaming = entry.artifact }
        Button("Duplica") { state.duplicateDocument(entry.artifact) }
        Button("Mostra la chat del documento") { state.showConversation(of: entry.artifact) }
        Divider()
        Button("Elimina…", role: .destructive) { deleting = entry.artifact }
    }
}

/// Un documento dell'elenco: anteprima vera, titolo e data, come nel gestore documenti di iWork.
private struct DocumentCard: View {
    let entry: AppState.DocumentEntry
    let open: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let size = entry.artifact.kind.thumbnailSize
        Button(action: action) {
            VStack(spacing: 9) {
                DocumentThumbnail(artifact: entry.artifact)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(hovering ? 0.24 : 0.14), radius: hovering ? 10 : 5, y: hovering ? 5 : 2)
                    .scaleEffect(hovering ? 1.03 : 1)
                VStack(spacing: 2) {
                    Text(entry.artifact.title.isEmpty ? String(localized: "Senza titolo") : entry.artifact.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 4) {
                        if open { Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityLabel("Aperto") }
                        Text(entry.date.listStamp)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .frame(width: size.width + 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.quick, value: hovering)
        .help(open ? String(localized: "Già aperto in una scheda") : String(localized: "Apri"))
    }
}

/// «Nuovo»: la pagina bianca con il più, come in Pages.
private struct NewDocumentCard: View {
    let kind: ArtifactKind
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let size = kind.thumbnailSize
        Button(action: action) {
            VStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.95 : 0.8))
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(kind.tint)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                VStack(spacing: 2) {
                    Text(kind.newLabel).font(.system(size: 12.5, weight: .semibold))
                    Text("Vuoto").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.quick, value: hovering)
    }
}

/// «Crea con Siri AI+»: la richiesta comincia nella chat a destra.
private struct AssistantDocumentCard: View {
    let kind: ArtifactKind
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let size = kind.thumbnailSize
        Button(action: action) {
            VStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x5AC8FA), Color(hex: 0x6E6BFF), Color(hex: 0xC86BFA)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing).opacity(hovering ? 1 : 0.85))
                    .overlay {
                        Image(systemName: "sparkles")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                VStack(spacing: 2) {
                    Text("Crea con Siri AI+").font(.system(size: 12.5, weight: .semibold))
                    Text("Descrivilo nella chat").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.quick, value: hovering)
        .help("Scrivi nella chat a destra cosa ti serve: Siri AI+ lo prepara")
    }
}

// MARK: - Anteprime

private struct DocumentThumbnail: View {
    let artifact: ArtifactModel

    var body: some View {
        switch artifact.content {
        case .document(let text):
            Image(nsImage: PageThumbnail.image(for: artifact, text: text))
                .resizable()
                .interpolation(.high)
        case .sheet(let spreadsheet):
            SheetThumbnail(sheet: spreadsheet.sheets.first)
        case .deck(let deck):
            if let first = deck.slides.first {
                SlideCanvas(slide: first, theme: deck.theme)
            } else {
                Rectangle().fill(deck.theme.background)
            }
        }
    }
}

/// Prima pagina disegnata con il testo vero (caratteri, titoli, colori, immagini), rifatta solo quando il documento cambia.
@MainActor
private enum PageThumbnail {
    private static var cache: [UUID: (revision: Int, image: NSImage)] = [:]
    static let page = NSSize(width: 612, height: 792)

    static func image(for artifact: ArtifactModel, text: NSAttributedString) -> NSImage {
        if let hit = cache[artifact.id], hit.revision == artifact.revision { return hit.image }
        let snippet = text.attributedSubstring(from: NSRange(location: 0, length: min(text.length, 3000)))
        let image = NSImage(size: page, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            snippet.draw(with: NSRect(x: 56, y: 48, width: rect.width - 112, height: rect.height - 96),
                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
        cache[artifact.id] = (artifact.revision, image)
        return image
    }
}

/// Prime righe e colonne del primo foglio, come la miniatura di Numbers.
private struct SheetThumbnail: View {
    let sheet: Sheet?

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            guard let sheet else { return }
            let columns = max(1, min(sheet.columns, 5))
            let rows = max(1, min(sheet.rows, 8))
            let cellWidth = size.width / CGFloat(columns)
            let cellHeight = size.height / CGFloat(rows)
            // Riga d'intestazione in grigio, come le tabelle di Numbers.
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: cellHeight)), with: .color(Color(hex: 0xEEF0F3)))
            for row in 0..<rows {
                for column in 0..<columns {
                    let text = sheet.display(CellRef(col: column, row: row))
                    guard !text.isEmpty else { continue }
                    let rect = CGRect(x: CGFloat(column) * cellWidth + 3, y: CGFloat(row) * cellHeight, width: cellWidth - 6, height: cellHeight)
                    let label = Text(text)
                        .font(.system(size: 7, weight: row == 0 ? .semibold : .regular))
                        .foregroundStyle(Color(hex: 0x2B2D31))
                    context.draw(context.resolve(label), in: rect.insetBy(dx: 0, dy: (cellHeight - 9) / 2))
                }
            }
            var lines = Path()
            for column in 1..<columns {
                lines.move(to: CGPoint(x: CGFloat(column) * cellWidth, y: 0))
                lines.addLine(to: CGPoint(x: CGFloat(column) * cellWidth, y: size.height))
            }
            for row in 1..<rows {
                lines.move(to: CGPoint(x: 0, y: CGFloat(row) * cellHeight))
                lines.addLine(to: CGPoint(x: size.width, y: CGFloat(row) * cellHeight))
            }
            context.stroke(lines, with: .color(Color(hex: 0xD5D8DD)), lineWidth: 0.5)
        }
    }
}

// MARK: - Documento in una scheda

/// Scheda di un documento: il suo editor (con Siri AI+ a destra che lo vede e lo modifica).
struct DocumentTab: View {
    @Environment(AppState.self) private var state
    let id: UUID

    var body: some View {
        if let artifact = state.artifact(id) {
            ArtifactEditor(artifact: artifact)
        } else {
            AppPlaceholder(symbol: "doc.questionmark", title: String(localized: "Documento non trovato"),
                           message: String(localized: "È stato eliminato, oppure la chat in cui era è stata cancellata."),
                           actionTitle: String(localized: "Chiudi la scheda")) { state.closeTab(.document(id)) }
                .clipShape(.rect(cornerRadius: 26))
                .glassCard(radius: 26)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 14)
        }
    }
}
