import AppKit
import SiriCore
import SwiftUI

/// Note, email, file o messaggi trovati: ogni riga si apre nell'app giusta.
struct AppItemsCard: View {
    @Environment(AppState.self) private var state
    let items: AppItems
    @State private var expanded = false
    var body: some View {
        Card(title: items.title, subtitle: items.rows.count == 1 ? "1 risultato" : "\(items.rows.count) risultati") {
            Tile(items.source, size: 26)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if items.rows.isEmpty {
                    Text("Nessun risultato.").font(DS.Fonts.body).foregroundStyle(.secondary)
                }
                let visible = expanded ? items.rows : Array(items.rows.prefix(5))
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.vertical, 6) }
                    AppItemRow(source: items.source, row: row)
                }
                if items.rows.count > 5 {
                    Button(expanded ? "Mostra meno" : "Mostra tutti (\(items.rows.count))") {
                        withAnimation { expanded.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(DS.Fonts.caption)
                    .padding(.top, 8)
                }
            }
        }
    }
}

struct AppItemRow: View {
    let source: SourceKind
    let row: AppItems.Row

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(DS.Fonts.bodyStrong).lineLimit(1)
                Text(row.subtitle).font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(1)
                if !row.detail.isEmpty {
                    Text(row.detail).font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Button("Apri") { AppOpener.open(row, in: source) }
                .buttonStyle(.link)
                .font(DS.Fonts.caption)
                .help("Apri in Siri AI+")
        }
        .contextMenu {
            Button("Apri in Siri AI+") { AppOpener.open(row, in: source) }
            Button("Apri in \(source.systemAppName)") { AppOpener.openInSystemApp(row, in: source) }
            if source == .files, let path = row.reference {
                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
        }
    }
}

enum AppOpener {
    /// Nell'app dentro Siri AI+, sull'elemento giusto (come un'unica app).
    @MainActor static func open(_ row: AppItems.Row, in source: SourceKind) {
        guard let state = AppState.shared, [.notes, .mail, .files, .messages].contains(source) else {
            openInSystemApp(row, in: source)
            return
        }
        state.openInApp(source, reference: row.reference ?? row.id)
    }

    /// Nell'app di sistema (Note, Mail, Finder, Messaggi).
    @MainActor static func openInSystemApp(_ row: AppItems.Row, in source: SourceKind) {
        switch source {
        case .files:
            if let path = row.reference { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        case .notes:
            if let id = row.reference { Task { await NotesService.open(id: id) } }
        case .mail:
            if let id = row.reference { Task { await MailReader.open(id: id) } }
        case .messages:
            if let handle = row.reference, !handle.isEmpty, let url = URL(string: "imessage:\(handle)") {
                NSWorkspace.shared.open(url)
            } else {
                source.openSystemApp()
            }
        default:
            source.openSystemApp()
        }
    }
}

struct NoteDraftCard: View {
    @Environment(AppState.self) private var state
    @Bindable var model: NoteCardModel

    var body: some View {
        Card(title: "Nuova nota", subtitle: "App Note", status: model.status,
             statusLabel: model.status == .awaiting ? "Da confermare" : model.status == .done ? "Creata" : nil) {
            Tile(.notes, size: 26)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if model.status == .awaiting {
                    TextField("Titolo", text: $model.draft.title).textFieldStyle(.roundedBorder).font(DS.Fonts.bodyStrong)
                    TextEditor(text: $model.draft.body)
                        .font(DS.Fonts.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 90, maxHeight: 220)
                        .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
                    CardActions(primary: "Crea nota", cancel: { model.status = .cancelled }) { state.create(model) }
                } else {
                    Text(model.draft.title).font(DS.Fonts.bodyStrong)
                    Text(model.draft.body).font(DS.Fonts.body).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                    if let error = model.error { Text(error).font(DS.Fonts.caption).foregroundStyle(.red) }
                    if model.status == .done {
                        Button("Apri Note") { SourceKind.notes.openSystemApp() }.buttonStyle(.link).font(DS.Fonts.caption)
                    }
                }
            }
        }
    }
}

/// Righe da aggiungere in fondo a una nota esistente. Se la nota ha liste con caselle, tabelle o allegati,
/// Note li perderebbe riscrivendola da fuori: allora il testo si copia e la nota si apre.
struct NoteAppendCard: View {
    @Environment(AppState.self) private var state
    @Bindable var model: NoteAppendCardModel

    var body: some View {
        Card(title: "Nota «\(model.draft.title)»", subtitle: model.draft.manual ? "App Note · da incollare in fondo" : "App Note · aggiungo in fondo",
             status: model.status, statusLabel: statusLabel) {
            Tile(.notes, size: 26)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if !model.draft.tail.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("…").foregroundStyle(.tertiary)
                        ForEach(Array(model.draft.tail.enumerated()), id: \.offset) { Text($0.element).lineLimit(1) }
                    }
                    .font(DS.Fonts.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Fine della nota: \(model.draft.tail.joined(separator: ", "))")
                }
                if model.status == .awaiting {
                    TextEditor(text: $model.text)
                        .font(DS.Fonts.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 56, maxHeight: 160)
                        .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Testo da aggiungere")
                    if model.draft.manual {
                        InlineBanner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                                     text: "Questa nota ha una lista con caselle, una tabella o degli allegati: modificandola da qui Note li perderebbe. Copio il testo e apro la nota: incollalo in fondo con ⌘V.") { EmptyView() }
                    }
                    CardActions(primary: model.draft.manual ? "Copia e apri la nota" : "Aggiungi alla nota", primaryDisabled: model.lines.isEmpty,
                                cancel: { model.status = .cancelled }) { state.append(model) }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { Label($0.element, systemImage: "plus").font(DS.Fonts.body) }
                    }
                    .foregroundStyle(model.status == .cancelled ? .secondary : .primary)
                    if let error = model.error { Text(error).font(DS.Fonts.caption).foregroundStyle(.red) }
                    if model.status == .done {
                        HStack {
                            if !model.draft.manual { UndoButton(since: model.doneAt, available: model.previousHTML != nil) { state.undo(model) } }
                            Spacer()
                            Button("Apri in Note") { Task { await NotesService.open(id: model.draft.noteID) } }.buttonStyle(.link).font(DS.Fonts.caption)
                        }
                    }
                }
            }
        }
    }

    private var statusLabel: String? {
        switch model.status {
        case .awaiting: "Da confermare"
        case .copied: "Copiato"
        case .done: "Aggiunto"
        default: nil
        }
    }
}

/// Inoltro di un'email ricevuta, con gli allegati: si apre in Mail con il destinatario e si invia da lì.
struct MailForwardCard: View {
    @Environment(AppState.self) private var state
    @Bindable var model: MailForwardCardModel

    var body: some View {
        Card(title: "Inoltra «\(model.draft.subject.isEmpty ? "(senza oggetto)" : model.draft.subject)»",
             subtitle: model.status == .opened || model.status == .done ? "Bozza aperta in Mail: invia da lì" : "Da \(model.draft.from) · \(model.draft.date)", status: model.status) {
            Tile(.mail)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if model.status == .draft || model.status == .awaiting {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            FieldLabel("A")
                            TextField("Nome", text: $model.draft.recipientName).textFieldStyle(.plain)
                        }
                        Divider().gridCellColumns(2)
                        GridRow {
                            FieldLabel("Indirizzo")
                            TextField("nome@esempio.it", text: $model.draft.recipientAddress).textFieldStyle(.plain)
                        }
                    }
                    .font(DS.Fonts.body)
                    .disabled(model.status == .awaiting)
                    if model.draft.recipientAddress.isEmpty {
                        Label("Non trovo l'indirizzo nei Contatti: scrivilo qui o aggiungilo in Mail.", systemImage: "info.circle")
                            .font(DS.Fonts.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.error { Text(error).font(DS.Fonts.caption).foregroundStyle(.red) }
                if model.status == .draft {
                    CardActions(primary: "Inoltra…", cancel: { model.status = .cancelled }) { withAnimation(DS.Motion.standard) { model.status = .awaiting } }
                } else if model.status == .awaiting {
                    InlineBanner(symbol: "arrowshape.turn.up.right", tint: .orange,
                                 text: "Aprirò in Mail l'inoltro con gli allegati\(model.draft.recipientAddress.isEmpty ? "" : " per \(model.draft.recipientAddress)"). L'invio parte solo quando premi Invia in Mail.") {
                        Button("Indietro") { withAnimation { model.status = .draft } }.controlSize(.small)
                        Button("Apri in Mail") { state.openForward(model) }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                } else if model.status == .opened || model.status == .done {
                    Text("A \(model.draft.recipientName.isEmpty ? model.draft.recipientAddress : model.draft.recipientName)").font(DS.Fonts.body).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct MessageDraftCard: View {
    @Environment(AppState.self) private var state
    @Bindable var model: MessageCardModel
    @State private var confirming = false
    var body: some View {
        Card(title: "Messaggio a \(model.draft.recipient.isEmpty ? "…" : model.draft.recipient)", subtitle: "iMessage", status: model.status,
             statusLabel: model.status == .awaiting ? "Da confermare" : model.status == .done ? "Inviato" : nil) {
            Tile(.messages, size: 26)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if model.status == .awaiting {
                    HStack {
                        TextField("Destinatario", text: $model.draft.recipient).textFieldStyle(.roundedBorder)
                        TextField("Numero o email", text: $model.draft.handle).textFieldStyle(.roundedBorder)
                    }
                    if model.draft.handle.isEmpty {
                        Text("Non ho trovato il recapito nei Contatti: scrivi il numero o l'email.")
                            .font(DS.Fonts.caption).foregroundStyle(.orange)
                    }
                    TextEditor(text: $model.draft.text)
                        .font(DS.Fonts.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 60, maxHeight: 160)
                        .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
                    CardActions(primary: "Invia…", primaryDisabled: model.draft.handle.isEmpty || model.draft.text.trimmingCharacters(in: .whitespaces).isEmpty,
                                cancel: { model.status = .cancelled }) { confirming = true }
                } else {
                    Text(model.draft.text).font(DS.Fonts.body).textSelection(.enabled)
                    if let error = model.error { Text(error).font(DS.Fonts.caption).foregroundStyle(.red) }
                }
            }
        }
        .confirmationDialog("Inviare il messaggio a \(model.draft.recipient) (\(model.draft.handle))?", isPresented: $confirming) {
            Button("Invia") { state.send(model) }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text(model.draft.text)
        }
    }
}
