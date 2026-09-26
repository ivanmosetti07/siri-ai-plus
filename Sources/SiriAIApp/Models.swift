import AppKit
import Foundation
import Observation
import SiriCore
import SwiftUI

// MARK: - Conversazioni e messaggi

@Observable
final class Conversation: Identifiable {
    let id: UUID
    var title: String
    let created: Date
    var messages: [Message] = []
    /// Le conversazioni di un progetto sono le sue sottotask.
    var projectID: UUID?
    var pinned = false
    /// Chat figlia: al termine il riepilogo torna alla chat madre.
    var parentID: UUID?
    var returned = false
    /// Chat di un agente: aggiornamenti, risultati e approvazioni.
    var agentID: UUID?
    /// Spazio della conversazione (personale, lavoro, programmazioni; nil = lavoro).
    var space: String?
    /// Modello scelto per questa chat (versione e ragionamento compresi); nil = quello dello spazio.
    var model: ModelSelection?
    /// Chat figlia: ciò che si diceva nella chat madre quando è stata aperta.
    var inherited: String?
    /// Segnaposto ↔ dati veri di questa chat (anonimizzazione verso ChatGPT e Claude). Resta sul Mac.
    var privacyVault: PIIVault?

    init(id: UUID = UUID(), title: String = "Nuova conversazione", created: Date = .now, projectID: UUID? = nil, parentID: UUID? = nil) {
        self.id = id
        self.title = title
        self.created = created
        self.projectID = projectID
        self.parentID = parentID
    }
}

struct Message: Identifiable {
    enum Content {
        case user(text: String, sources: [SourceKind], attachments: [String])
        case text(String)
        case thinking(String)
        case agenda(Agenda)
        case event(EventCardModel)
        case reminders(RemindersCardModel)
        case confirm(ConfirmCardModel)
        case mail(MailCardModel)
        case plan(PlanCardModel)
        case artifact(ArtifactModel)
        case unavailable(UnavailableCardModel)
        case image(ImageCardModel)
        case files([String])
        case fileWrite(FileWriteCardModel)
        case fileOp(FileOpCardModel)
        case mcp(MCPCallCardModel)
        case web(WebAnswer)
        case items(AppItems)
        case note(NoteCardModel)
        /// Testo da aggiungere a una nota che esiste già.
        case noteAppend(NoteAppendCardModel)
        /// Inoltro di un'email ricevuta.
        case forward(MailForwardCardModel)
        case imessage(MessageCardModel)
        case taskPlan(TaskPlanCardModel)
        case chatLink(ChatLink)
        case agentDraft(AgentDraftCardModel)
        case website(WebsiteCardModel)
        case notice(String)
        /// Come ha lavorato l'assistente: strumenti usati, tempi, esiti.
        case trace(RequestTrace)
        /// Dati sostituiti con i segnaposto prima di inviare a ChatGPT o Claude.
        case privacy(PrivacyReport)

        /// Modello della scheda (per sapere in quale conversazione si trova).
        var card: AnyObject? {
            switch self {
            case .event(let m): m
            case .reminders(let m): m
            case .confirm(let m): m
            case .mail(let m): m
            case .plan(let m): m
            case .artifact(let m): m
            case .unavailable(let m): m
            case .image(let m): m
            case .fileWrite(let m): m
            case .fileOp(let m): m
            case .mcp(let m): m
            case .note(let m): m
            case .noteAppend(let m): m
            case .forward(let m): m
            case .imessage(let m): m
            case .taskPlan(let m): m
            case .agentDraft(let m): m
            case .website(let m): m
            default: nil
            }
        }
    }

    let id = UUID()
    var content: Content

    var isPending: Bool {
        switch content {
        case .event(let m): m.status == .draft
        case .reminders(let m): m.status == .draft
        case .confirm(let m): m.status == .awaiting
        case .mail(let m): m.status == .draft || m.status == .awaiting
        case .plan(let m): m.status == .awaiting
        case .fileWrite(let m): m.status == .awaiting
        case .fileOp(let m): m.status == .awaiting
        case .mcp(let m): m.status == .awaiting
        case .note(let m): m.status == .awaiting
        case .noteAppend(let m): m.status == .awaiting
        case .forward(let m): m.status == .draft || m.status == .awaiting
        case .imessage(let m): m.status == .awaiting
        case .website(let m): m.status == .awaiting
        default: false
        }
    }
}

// MARK: - Modelli delle schede

/// Un'azione appena confermata si può annullare per qualche minuto.
enum UndoWindow {
    static let duration: TimeInterval = 10 * 60
    static func isOpen(_ date: Date?) -> Bool { date.map { Date.now.timeIntervalSince($0) < duration } ?? false }
}

@Observable final class EventCardModel: Identifiable {
    /// Evento creato e momento della conferma (per «Annulla»).
    var createdID: String?
    var doneAt: Date?
    /// Modifica di un evento che esiste già (com'era prima): il salvataggio aggiorna quello invece di crearne uno.
    let edit: EventEditDraft?
    /// Inizio dopo la modifica salvata: serve per ritrovare l'evento e annullare.
    var savedStart: Date?
    var draft: EventDraft { didSet { if draft.start != oldValue.start || draft.end != oldValue.end { refreshConflicts() } } }
    var status: ItemStatus = .draft
    var conflicts: [EventItem] = []
    var error: String?

    init(_ draft: EventDraft, edit: EventEditDraft? = nil, checkConflicts: Bool = true) {
        self.draft = draft
        self.edit = edit
        if checkConflicts { refreshConflicts() }
    }

    func refreshConflicts() {
        // L'evento che si sta spostando non è in conflitto con sé stesso.
        conflicts = draft.isAllDay ? [] : EventKitService.conflicts(start: draft.start, end: draft.end).filter { $0.identifier != edit?.identifier }
    }

    /// Sposta l'evento subito dopo l'ultimo conflitto, mantenendo la durata.
    func moveAfterConflicts() {
        guard let last = conflicts.map(\.end).max() else { return }
        let duration = draft.end.timeIntervalSince(draft.start)
        draft.start = last
        draft.end = last.addingTimeInterval(duration)
    }
}

@Observable final class RemindersCardModel {
    var createdIDs: [String] = []
    var doneAt: Date?
    var drafts: [ReminderDraft]
    var list: String
    var status: ItemStatus = .draft
    var error: String?
    /// Modifica di un promemoria che esiste già (com'era prima).
    let edit: ReminderEditDraft?

    init(_ drafts: [ReminderDraft], list: String, edit: ReminderEditDraft? = nil) {
        self.drafts = drafts
        self.list = list
        self.edit = edit
    }

    var includedCount: Int { drafts.filter { $0.included && !$0.title.isEmpty }.count }
}

@Observable final class ConfirmCardModel {
    let action: PendingAction
    var status: ItemStatus = .awaiting
    var error: String?

    init(_ action: PendingAction) { self.action = action }

    var isDestructive: Bool {
        switch action.kind {
        case .deleteEvent, .deleteReminder: true
        case .completeReminder: false
        }
    }

    var source: SourceKind { action.source }
}

@Observable final class MailCardModel {
    var recipients: String
    var subject: String
    var body: String
    /// .draft → .awaiting (riepilogo prima dell'invio) → .done
    var status: ItemStatus = .draft
    /// Risposta a un'email ricevuta: si apre in Mail nella stessa conversazione, con la citazione.
    let reply: MailReplyDraft?
    var error: String?

    init(_ draft: MailDraft) {
        recipients = draft.recipients.joined(separator: ", ")
        subject = draft.subject
        body = draft.body
        reply = nil
    }

    init(reply: MailReplyDraft) {
        recipients = reply.to
        subject = reply.subject
        body = reply.body
        self.reply = reply
    }

    var recipientList: [String] {
        recipients.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var missingAddresses: Bool { recipientList.contains { !$0.contains("@") } }
}

@Observable final class PlanCardModel {
    var plan: PlanDraft
    var status: ItemStatus = .awaiting
    var stepStatus: [UUID: ItemStatus] = [:]
    var stepResult: [UUID: String] = [:]

    init(_ plan: PlanDraft) { self.plan = plan }

    var sources: [SourceKind] {
        var seen: [SourceKind] = []
        for step in plan.steps where step.included {
            if let source = step.kind.source, !seen.contains(source) { seen.append(source) }
        }
        return seen
    }
}

enum UnavailableKind: String, Codable, Equatable {
    case comingSoon, notConnected, notSelected, readOnly
}

@Observable final class UnavailableCardModel {
    let source: SourceKind
    let kind: UnavailableKind
    let prompt: String
    var resolved = false

    init(source: SourceKind, kind: UnavailableKind, prompt: String) {
        self.source = source; self.kind = kind; self.prompt = prompt
    }
}

/// Immagini generate con Image Playground: file PNG su disco.
@Observable final class ImageCardModel: Identifiable {
    let id = UUID()
    var prompt: String
    var style: String
    var paths: [String] = []
    var status: ItemStatus = .running
    var error: String?

    init(prompt: String, style: String) {
        self.prompt = prompt
        self.style = style
    }

    var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }
    /// Su questo Mac la generazione diretta non è supportata: si passa dal foglio di Image Playground.
    var needsSheet: Bool { status == .awaiting && paths.isEmpty }
}

/// Piano di un compito complesso con lo stato dei passi (eseguiti dai sub-agent).
@Observable final class TaskPlanCardModel {
    /// Il piano è già stato salvato come skill.
    var savedAsSkill = false
    var plan: TaskPlan
    var running = false
    let parallel: Int

    init(_ plan: TaskPlan, parallel: Int) {
        self.plan = plan
        self.parallel = parallel
    }
}

/// Pagina web generata: si salva (nel progetto dopo conferma) e si apre nel browser integrato.
@Observable final class WebsiteCardModel {
    var draft: WebsiteDraft
    let projectID: UUID?
    var status: ItemStatus = .awaiting
    var savedFolder: String?
    var error: String?

    init(_ draft: WebsiteDraft, projectID: UUID?) {
        self.draft = draft
        self.projectID = projectID
    }
}

/// Agente proposto in chat, da creare con un clic.
@Observable final class AgentDraftCardModel {
    var spec: AgentSpec
    var created = false

    init(_ spec: AgentSpec, created: Bool = false) {
        self.spec = spec
        self.created = created
    }
}

/// Collegamento tra chat madre e chat figlia; con `summary` è il riepilogo riportato alla madre.
struct ChatLink: Codable, Equatable {
    var childID: UUID
    var title: String
    var summary: String?
    var projectName: String?
}

/// Nuova nota nell'app Note, dopo conferma.
@Observable final class NoteCardModel {
    var draft: NoteDraft
    var status: ItemStatus = .awaiting
    var error: String?

    init(_ draft: NoteDraft) { self.draft = draft }
}

/// Righe da aggiungere in fondo a una nota esistente, dopo conferma.
@Observable final class NoteAppendCardModel {
    var draft: NoteAppendDraft
    var text: String
    var status: ItemStatus = .awaiting
    var error: String?
    var doneAt: Date?
    /// Contenuto della nota prima e dopo l'aggiunta (per «Annulla»).
    var previousHTML: String?
    var savedHTML: String?

    init(_ draft: NoteAppendDraft) {
        self.draft = draft
        text = draft.lines.joined(separator: "\n")
    }

    var lines: [String] { text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}

/// Inoltro di un'email: si apre in Mail con gli allegati e il destinatario.
@Observable final class MailForwardCardModel {
    var draft: MailForwardDraft
    var status: ItemStatus = .draft
    var error: String?

    init(_ draft: MailForwardDraft) { self.draft = draft }
}

/// iMessage da inviare, dopo conferma esplicita.
@Observable final class MessageCardModel {
    var draft: MessageDraft
    var status: ItemStatus = .awaiting
    var error: String?

    init(_ draft: MessageDraft) { self.draft = draft }
}

/// Spostamento, rinomina, nuova cartella o cestino nel progetto, dopo conferma.
@Observable final class FileOpCardModel {
    /// Dove è finito nel Cestino (per rimetterlo a posto).
    var trashedURL: URL?
    var doneAt: Date?
    var draft: FileOpDraft
    let projectID: UUID?
    var status: ItemStatus = .awaiting
    var error: String?

    init(_ draft: FileOpDraft, projectID: UUID?) {
        self.draft = draft
        self.projectID = projectID
    }
}

/// Creazione o modifica di un file del progetto, dopo conferma.
@Observable final class FileWriteCardModel {
    /// Copia del file com'era prima della modifica (nil se il file è nuovo).
    var backupPath: String?
    var doneAt: Date?
    var draft: FileWriteDraft
    let projectID: UUID?
    var status: ItemStatus = .awaiting
    var error: String?

    init(_ draft: FileWriteDraft, projectID: UUID?) {
        self.draft = draft
        self.projectID = projectID
    }
}

/// Chiamata a uno strumento di un server MCP.
@Observable final class MCPCallCardModel {
    let draft: MCPCallDraft
    var status: ItemStatus = .awaiting
    var result: String?
    var error: String?

    init(_ draft: MCPCallDraft) { self.draft = draft }
}

// MARK: - Artefatti

@Observable final class ArtifactModel: Identifiable {
    enum Content {
        case document(NSAttributedString)
        case sheet(Spreadsheet)
        case deck(Deck)
    }

    struct Version: Identifiable {
        let id = UUID()
        let date: Date
        let label: String
        let content: Content
    }

    let id: UUID
    let kind: ArtifactKind
    var title: String { didSet { modified = .now } }
    var content: Content { didSet { revision += 1; modified = .now } }
    /// Ultima modifica (nil per i documenti salvati prima del 23/9/2026: vale la data della loro chat).
    var modified: Date?
    var versions: [Version] = []
    var exportedURL: URL?
    var lastExport: Date?
    var projectID: UUID?
    /// Aumenta a ogni modifica: gli editor lo usano per sapere quando ricaricare.
    var revision = 0

    init(id: UUID = UUID(), kind: ArtifactKind, title: String, content: Content, projectID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.projectID = projectID
        versions = [Version(date: .now, label: "Creato da Siri AI+", content: content)]
    }

    var document: NSAttributedString? { if case .document(let d) = content { d } else { nil } }
    var spreadsheet: Spreadsheet? { if case .sheet(let s) = content { s } else { nil } }
    var deck: Deck? { if case .deck(let d) = content { d } else { nil } }

    var summary: String {
        switch content {
        case .document(let text):
            let words = text.string.split(whereSeparator: \.isWhitespace).count
            return words == 1 ? "1 parola" : "\(words) parole"
        case .sheet(let sheet): return sheet.sheets.count == 1 ? "1 foglio" : "\(sheet.sheets.count) fogli"
        case .deck(let deck): return "\(deck.slides.count) slide"
        }
    }

    /// Testo breve per il modello: cosa c'è nell'artefatto aperto.
    var contextSummary: String {
        switch content {
        case .document(let text): String(text.string.prefix(900))
        case .sheet(let sheet): sheet.sheets.first.map { "Foglio «\($0.name)»:\n" + $0.summary() } ?? ""
        case .deck(let deck): deck.summary()
        }
    }

    var stateLabel: String {
        if let lastExport { "Salvato alle \(lastExport.formatted(date: .omitted, time: .shortened))" } else { "Bozza in Siri AI+" }
    }

    func snapshot(_ label: String) {
        versions.insert(Version(date: .now, label: label, content: content), at: 0)
        if versions.count > 30 { versions.removeLast() }
    }

    func restore(_ version: Version) {
        snapshot("Prima del ripristino")
        content = version.content
    }
}

// MARK: - Progetti

@Observable final class ProjectModel: Identifiable {
    let id: UUID
    var name: String
    var folder: URL
    var pinned: Bool
    let created: Date
    var lastOpened: Date
    var allowWrite: Bool
    /// Istruzioni AGENTS.md condensate per il modello, con la firma del file da cui derivano.
    var agentsDigest: String?
    var agentsSignature: String?
    /// Sintesi di MEMORY.md (ricalcolata quando il file cambia).
    var memoryDigest: String?
    var memorySignature: String?
    /// Connettori usati in questo progetto (nil = tutti quelli attivi).
    var connectorIDs: Set<UUID>?
    /// Spazio del progetto (nil = lavoro).
    var space: String?

    init(id: UUID = UUID(), name: String, folder: URL, pinned: Bool = false, created: Date = .now, lastOpened: Date = .now, allowWrite: Bool = true) {
        self.id = id
        self.name = name
        self.folder = folder
        self.pinned = pinned
        self.created = created
        self.lastOpened = lastOpened
        self.allowWrite = allowWrite
    }

    var files: ProjectFiles { ProjectFiles(root: folder) }
    var exists: Bool { FileManager.default.fileExists(atPath: folder.path) }
}

struct StoredProject: Codable {
    var id: UUID
    var name: String
    var folder: String
    var pinned: Bool
    var created: Date
    var lastOpened: Date
    var allowWrite: Bool?
    var agentsDigest: String?
    var agentsSignature: String?
    var memoryDigest: String?
    var memorySignature: String?
    var connectorIDs: [UUID]?
    var space: String?
}

extension ProjectModel {
    var stored: StoredProject {
        StoredProject(id: id, name: name, folder: folder.path, pinned: pinned, created: created, lastOpened: lastOpened,
                      allowWrite: allowWrite, agentsDigest: agentsDigest, agentsSignature: agentsSignature,
                      memoryDigest: memoryDigest, memorySignature: memorySignature,
                      connectorIDs: connectorIDs.map { Array($0) }, space: space)
    }

    convenience init(_ stored: StoredProject) {
        self.init(id: stored.id, name: stored.name, folder: URL(fileURLWithPath: stored.folder), pinned: stored.pinned,
                  created: stored.created, lastOpened: stored.lastOpened, allowWrite: stored.allowWrite ?? true)
        agentsDigest = stored.agentsDigest
        agentsSignature = stored.agentsSignature
        memoryDigest = stored.memoryDigest
        memorySignature = stored.memorySignature
        connectorIDs = stored.connectorIDs.map(Set.init)
        space = stored.space
    }

    /// Il connettore è usato in questo progetto?
    func uses(_ serverID: UUID) -> Bool { connectorIDs?.contains(serverID) ?? true }
}

// MARK: - Registro attività

struct ActivityEntry: Identifiable, Codable {
    var id = UUID()
    var date = Date.now
    var icon: String
    var title: String
    var detail: String
    var status: ItemStatus
}

// MARK: - Preferenze delle fonti

struct SourcePref: Codable, Equatable {
    var enabled: Bool
    var allowWrite: Bool
}

// MARK: - Salvataggio su disco

struct StoredConversation: Codable {
    var id: UUID
    var title: String
    var created: Date
    var messages: [StoredMessage]
    var projectID: UUID?
    var pinned: Bool?
    var parentID: UUID?
    var returned: Bool?
    var agentID: UUID?
    var space: String?
    var model: ModelSelection?
    var inherited: String?
    var privacyVault: PIIVault?
}

extension StoredConversation {
    private enum Keys: String, CodingKey { case id, title, created, messages, projectID, pinned, parentID, returned, agentID, space, model, inherited, privacyVault }

    /// Un messaggio illeggibile (formato cambiato, file troncato) si scarta da solo: la conversazione resta.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Conversazione"
        created = (try? c.decode(Date.self, forKey: .created)) ?? .now
        messages = ((try? c.decode([Lossy<StoredMessage>].self, forKey: .messages)) ?? []).compactMap(\.value)
        projectID = try? c.decodeIfPresent(UUID.self, forKey: .projectID)
        pinned = try? c.decodeIfPresent(Bool.self, forKey: .pinned)
        parentID = try? c.decodeIfPresent(UUID.self, forKey: .parentID)
        returned = try? c.decodeIfPresent(Bool.self, forKey: .returned)
        agentID = try? c.decodeIfPresent(UUID.self, forKey: .agentID)
        space = try? c.decodeIfPresent(String.self, forKey: .space)
        // Un modello non più disponibile (come Gemini) si scarta: la chat usa quello dello spazio.
        model = (try? c.decodeIfPresent(ModelSelection.self, forKey: .model)) ?? nil
        inherited = try? c.decodeIfPresent(String.self, forKey: .inherited)
        privacyVault = (try? c.decodeIfPresent(PIIVault.self, forKey: .privacyVault)) ?? nil
    }
}

struct StoredArtifact: Codable {
    var id: UUID
    var kind: ArtifactKind
    var title: String
    /// RTFD (testo con immagini); `document` è il formato RTF delle versioni precedenti.
    var documentRTFD: Data?
    var document: Data?
    var spreadsheet: Spreadsheet?
    var presentation: Deck?
    var sheet: SheetDraft?
    var deck: DeckDraft?
    var exportedURL: URL?
    var lastExport: Date?
    var projectID: UUID?
    var modified: Date?
}

enum StoredMessage: Codable {
    case user(text: String, sources: [SourceKind], attachments: [String])
    case text(String)
    case notice(String)
    case agenda(Agenda)
    case event(draft: EventDraft, status: ItemStatus, error: String?)
    case reminders(drafts: [ReminderDraft], list: String, status: ItemStatus)
    case confirm(action: PendingAction, status: ItemStatus)
    case mail(recipients: String, subject: String, body: String, status: ItemStatus)
    case plan(plan: PlanDraft, status: ItemStatus, stepStatus: [UUID: ItemStatus], stepResult: [UUID: String])
    case artifact(StoredArtifact)
    case unavailable(source: SourceKind, kind: UnavailableKind, prompt: String, resolved: Bool)
    case image(prompt: String, style: String, paths: [String], status: ItemStatus)
    case files([String])
    case fileWrite(draft: FileWriteDraft, projectID: UUID?, status: ItemStatus, error: String?)
    case fileOp(draft: FileOpDraft, projectID: UUID?, status: ItemStatus, error: String?)
    case mcp(draft: MCPCallDraft, status: ItemStatus, result: String?, error: String?)
    case web(WebAnswer)
    case items(AppItems)
    case note(draft: NoteDraft, status: ItemStatus, error: String?)
    case eventEdit(edit: EventEditDraft, draft: EventDraft, status: ItemStatus, error: String?)
    case reminderEdit(edit: ReminderEditDraft, draft: ReminderDraft, list: String, status: ItemStatus)
    case noteAppend(draft: NoteAppendDraft, text: String, status: ItemStatus, error: String?)
    case mailReply(reply: MailReplyDraft, recipients: String, subject: String, body: String, status: ItemStatus)
    case mailForward(draft: MailForwardDraft, status: ItemStatus, error: String?)
    case imessage(draft: MessageDraft, status: ItemStatus, error: String?)
    case taskPlan(TaskPlan)
    case chatLink(ChatLink)
    case agentDraft(spec: AgentSpec, created: Bool)
    case website(draft: WebsiteDraft, projectID: UUID?, status: ItemStatus, savedFolder: String?)
    case trace(RequestTrace)
    case privacy(PrivacyReport)
}

extension ItemStatus {
    /// Un'azione interrotta dalla chiusura dell'app non è più in corso.
    var restored: ItemStatus { self == .running ? .failed : self }
}

extension ArtifactModel {
    @MainActor var stored: StoredArtifact {
        var result = StoredArtifact(id: id, kind: kind, title: title, exportedURL: exportedURL, lastExport: lastExport, projectID: projectID)
        result.modified = modified
        switch content {
        case .document(let text):
            result.documentRTFD = try? text.data(from: NSRange(location: 0, length: text.length),
                                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        case .sheet(let sheet): result.spreadsheet = sheet
        case .deck(let deck): result.presentation = deck
        }
        return result
    }

    /// Carica anche i formati delle versioni precedenti (RTF, SheetDraft, DeckDraft).
    @MainActor convenience init?(_ stored: StoredArtifact) {
        let content: Content
        if let deck = stored.presentation {
            content = .deck(deck)
        } else if let deck = stored.deck {
            content = .deck(Deck(from: deck))
        } else if let sheet = stored.spreadsheet {
            content = .sheet(sheet)
        } else if let sheet = stored.sheet {
            content = .sheet(Spreadsheet(from: sheet))
        } else if let data = stored.documentRTFD,
                  let text = NSAttributedString(rtfd: data, documentAttributes: nil) {
            content = .document(text)
        } else if let data = stored.document,
                  let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            content = .document(text)
        } else {
            return nil
        }
        self.init(id: stored.id, kind: stored.kind, title: stored.title, content: content, projectID: stored.projectID)
        exportedURL = stored.exportedURL
        lastExport = stored.lastExport
        modified = stored.modified
    }
}

extension Message {
    @MainActor var stored: StoredMessage? {
        switch content {
        case .user(let text, let sources, let attachments): .user(text: text, sources: sources, attachments: attachments)
        case .text(let text): .text(text)
        case .notice(let text): .notice(text)
        case .thinking: nil
        case .agenda(let agenda): .agenda(agenda)
        case .event(let m):
            if let edit = m.edit { .eventEdit(edit: edit, draft: m.draft, status: m.status, error: m.error) }
            else { .event(draft: m.draft, status: m.status, error: m.error) }
        case .reminders(let m):
            if let edit = m.edit, let draft = m.drafts.first { .reminderEdit(edit: edit, draft: draft, list: m.list, status: m.status) }
            else { .reminders(drafts: m.drafts, list: m.list, status: m.status) }
        case .confirm(let m): .confirm(action: m.action, status: m.status)
        case .mail(let m):
            if let reply = m.reply { .mailReply(reply: reply, recipients: m.recipients, subject: m.subject, body: m.body, status: m.status) }
            else { .mail(recipients: m.recipients, subject: m.subject, body: m.body, status: m.status) }
        case .plan(let m): .plan(plan: m.plan, status: m.status, stepStatus: m.stepStatus, stepResult: m.stepResult)
        case .artifact(let a): .artifact(a.stored)
        case .unavailable(let m): .unavailable(source: m.source, kind: m.kind, prompt: m.prompt, resolved: m.resolved)
        case .image(let m): .image(prompt: m.prompt, style: m.style, paths: m.paths, status: m.status)
        case .files(let paths): .files(paths)
        case .fileWrite(let m): .fileWrite(draft: m.draft, projectID: m.projectID, status: m.status, error: m.error)
        case .fileOp(let m): .fileOp(draft: m.draft, projectID: m.projectID, status: m.status, error: m.error)
        case .mcp(let m): .mcp(draft: m.draft, status: m.status, result: m.result, error: m.error)
        case .web(let answer): .web(answer)
        case .items(let items): .items(items)
        case .note(let m): .note(draft: m.draft, status: m.status, error: m.error)
        case .noteAppend(let m): .noteAppend(draft: m.draft, text: m.text, status: m.status, error: m.error)
        case .forward(let m): .mailForward(draft: m.draft, status: m.status, error: m.error)
        case .imessage(let m): .imessage(draft: m.draft, status: m.status, error: m.error)
        case .taskPlan(let m): .taskPlan(m.plan)
        case .chatLink(let link): .chatLink(link)
        case .agentDraft(let m): .agentDraft(spec: m.spec, created: m.created)
        case .website(let m): .website(draft: m.draft, projectID: m.projectID, status: m.status, savedFolder: m.savedFolder)
        case .trace(let trace): .trace(trace)
        case .privacy(let report): .privacy(report)
        }
    }

    @MainActor init?(_ stored: StoredMessage) {
        switch stored {
        case .user(let text, let sources, let attachments):
            self.init(content: .user(text: text, sources: sources, attachments: attachments))
        case .text(let text): self.init(content: .text(text))
        case .notice(let text): self.init(content: .notice(text))
        case .agenda(let agenda): self.init(content: .agenda(agenda))
        case .event(let draft, let status, let error):
            // Conflitti solo per le bozze ancora aperte (all'avvio EventKit può non essere pronto).
            let m = EventCardModel(draft, checkConflicts: false)
            m.status = status.restored
            if m.status == .draft { Task { @MainActor in m.refreshConflicts() } }
            m.error = error
            self.init(content: .event(m))
        case .reminders(let drafts, let list, let status):
            let m = RemindersCardModel(drafts, list: list)
            m.status = status.restored
            self.init(content: .reminders(m))
        case .confirm(let action, let status):
            let m = ConfirmCardModel(action)
            m.status = status.restored
            self.init(content: .confirm(m))
        case .mail(let recipients, let subject, let body, let status):
            let m = MailCardModel(MailDraft(recipients: [], subject: subject, body: body))
            m.recipients = recipients
            m.status = status.restored
            self.init(content: .mail(m))
        case .plan(let plan, let status, let stepStatus, let stepResult):
            let m = PlanCardModel(plan)
            m.status = status.restored
            m.stepStatus = stepStatus.mapValues(\.restored)
            m.stepResult = stepResult
            self.init(content: .plan(m))
        case .artifact(let stored):
            guard let artifact = ArtifactModel(stored) else { return nil }
            self.init(content: .artifact(artifact))
        case .unavailable(let source, let kind, let prompt, let resolved):
            let m = UnavailableCardModel(source: source, kind: kind, prompt: prompt)
            m.resolved = resolved
            self.init(content: .unavailable(m))
        case .image(let prompt, let style, let paths, let status):
            let m = ImageCardModel(prompt: prompt, style: style)
            m.paths = paths
            m.status = status.restored
            self.init(content: .image(m))
        case .files(let paths): self.init(content: .files(paths))
        case .web(let answer): self.init(content: .web(answer))
        case .fileOp(let draft, let projectID, let status, let error):
            let m = FileOpCardModel(draft, projectID: projectID)
            m.status = status.restored
            m.error = error
            self.init(content: .fileOp(m))
        case .items(let items): self.init(content: .items(items))
        case .taskPlan(var plan):
            // Un passo rimasto "in corso" alla chiusura dell'app non è più in corso.
            for index in plan.steps.indices where plan.steps[index].status == "corso" { plan.steps[index].status = "errore" }
            self.init(content: .taskPlan(TaskPlanCardModel(plan, parallel: DeviceProfile.recommendedSubAgents)))
        case .chatLink(let link): self.init(content: .chatLink(link))
        case .agentDraft(let spec, let created): self.init(content: .agentDraft(AgentDraftCardModel(spec, created: created)))
        case .website(let draft, let projectID, let status, let savedFolder):
            let m = WebsiteCardModel(draft, projectID: projectID)
            m.status = status.restored
            m.savedFolder = savedFolder
            self.init(content: .website(m))
        case .trace(let trace): self.init(content: .trace(trace))
        case .privacy(let report): self.init(content: .privacy(report))
        case .note(let draft, let status, let error):
            let m = NoteCardModel(draft)
            m.status = status.restored
            m.error = error
            self.init(content: .note(m))
        case .eventEdit(let edit, let draft, let status, let error):
            let m = EventCardModel(draft, edit: edit, checkConflicts: false)
            m.status = status.restored
            if m.status == .draft { Task { @MainActor in m.refreshConflicts() } }
            m.error = error
            self.init(content: .event(m))
        case .reminderEdit(let edit, let draft, let list, let status):
            let m = RemindersCardModel([draft], list: list, edit: edit)
            m.status = status.restored
            self.init(content: .reminders(m))
        case .noteAppend(let draft, let text, let status, let error):
            let m = NoteAppendCardModel(draft)
            m.text = text
            m.status = status.restored
            m.error = error
            self.init(content: .noteAppend(m))
        case .mailReply(let reply, let recipients, let subject, let body, let status):
            let m = MailCardModel(reply: reply)
            m.recipients = recipients
            m.subject = subject
            m.body = body
            m.status = status.restored
            self.init(content: .mail(m))
        case .mailForward(let draft, let status, let error):
            let m = MailForwardCardModel(draft)
            m.status = status.restored
            m.error = error
            self.init(content: .forward(m))
        case .imessage(let draft, let status, let error):
            let m = MessageCardModel(draft)
            m.status = status.restored
            m.error = error
            self.init(content: .imessage(m))
        case .fileWrite(let draft, let projectID, let status, let error):
            let m = FileWriteCardModel(draft, projectID: projectID)
            m.status = status.restored
            m.error = error
            self.init(content: .fileWrite(m))
        case .mcp(let draft, let status, let result, let error):
            let m = MCPCallCardModel(draft)
            m.status = status.restored
            m.result = result
            m.error = error
            self.init(content: .mcp(m))
        }
    }
}
