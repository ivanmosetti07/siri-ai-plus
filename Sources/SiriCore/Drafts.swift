import EventKit
import Foundation

// MARK: - Fonti

public enum SourceKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case calendar, mail, reminders, notes, files, photos, messages, contacts, voiceMemos

    public var id: String { rawValue }

    /// Foto è stata tolta: il caso resta solo per leggere i dati salvati.
    public static var allCases: [SourceKind] { [.calendar, .reminders, .mail, .notes, .files, .messages, .contacts, .voiceMemos] }

    /// Si può scegliere come fonte di una richiesta nella chat (Contatti e Memo Vocali per ora vivono solo nelle loro app).
    public var usableInChat: Bool { ![.photos, .contacts, .voiceMemos].contains(self) }

    public var label: String {
        switch self {
        case .calendar: Language.t("Calendario", "Calendar")
        case .mail: "Mail"
        case .reminders: Language.t("Promemoria", "Reminders")
        case .notes: Language.t("Note", "Notes")
        case .files: Language.t("File", "Files")
        case .photos: Language.t("Foto", "Photos")
        case .messages: Language.t("Messaggi", "Messages")
        case .contacts: Language.t("Contatti", "Contacts")
        case .voiceMemos: Language.t("Memo Vocali", "Voice Memos")
        }
    }

    public enum Support: Sendable { case full, composeOnly, comingSoon }

    /// Cosa è davvero implementato oggi.
    public var support: Support {
        switch self {
        case .calendar, .reminders, .mail, .notes, .files, .messages, .contacts, .voiceMemos: .full
        case .photos: .comingSoon
        }
    }

    public var readCapability: String {
        switch self {
        case .calendar: Language.t("Leggere eventi e disponibilità", "Read events and availability")
        case .mail: Language.t("Leggere e riassumere le email", "Read and summarize emails")
        case .reminders: Language.t("Leggere promemoria e liste", "Read reminders and lists")
        case .notes: Language.t("Cercare e leggere le note", "Search and read notes")
        case .files: Language.t("Cercare e leggere documenti", "Search and read documents")
        case .photos: Language.t("Cercare foto e album sul dispositivo", "Search photos and albums on the device")
        case .messages: Language.t("Leggere le conversazioni", "Read conversations")
        case .contacts: Language.t("Vedere i contatti e i loro recapiti", "See contacts and their details")
        case .voiceMemos: Language.t("Ascoltare e trascrivere le registrazioni", "Listen to and transcribe recordings")
        }
    }

    public var writeCapability: String {
        switch self {
        case .calendar: Language.t("Creare, spostare ed eliminare eventi", "Create, move and delete events")
        case .mail: Language.t("Preparare bozze da inviare con Mail", "Prepare drafts to send with Mail")
        case .reminders: Language.t("Creare e completare promemoria", "Create and complete reminders")
        case .notes: Language.t("Creare e modificare note", "Create and edit notes")
        case .files: Language.t("Salvare documenti", "Save documents")
        case .photos: Language.t("Creare album", "Create albums")
        case .messages: Language.t("Inviare messaggi", "Send messages")
        case .contacts: Language.t("Creare e modificare contatti", "Create and edit contacts")
        case .voiceMemos: Language.t("Registrare nuovi memo", "Record new memos")
        }
    }
}

public enum UnavailableReason: Sendable, Equatable {
    case notConnected, notSelected, comingSoon
}

// MARK: - Bozze

public struct EventDraft: Sendable, Equatable, Codable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendar: String
    public var location: String
    public var notes: String

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false, calendar: String, location: String = "", notes: String = "") {
        self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay
        self.calendar = calendar; self.location = location; self.notes = notes
    }
}

public struct ReminderDraft: Sendable, Equatable, Identifiable, Codable {
    public var id = UUID()
    public var title: String
    public var due: Date?
    public var dueHasTime: Bool
    public var highPriority: Bool
    public var included = true

    public init(title: String, due: Date? = nil, dueHasTime: Bool = false, highPriority: Bool = false) {
        self.title = title; self.due = due; self.dueHasTime = dueHasTime; self.highPriority = highPriority
    }
}

/// Modifica di un evento esistente: com'era e come diventa (solo questa occorrenza, se si ripete).
public struct EventEditDraft: Sendable, Equatable, Codable {
    public var identifier: String
    /// Inizio dell'occorrenza da modificare.
    public var originalStart: Date
    public var before: EventDraft
    public var after: EventDraft
    /// Invitati: il calendario può avvisarli del cambiamento.
    public var attendees: Int

    public init(identifier: String, originalStart: Date, before: EventDraft, after: EventDraft, attendees: Int = 0) {
        self.identifier = identifier; self.originalStart = originalStart; self.before = before; self.after = after; self.attendees = attendees
    }
}

/// Modifica di un promemoria esistente.
public struct ReminderEditDraft: Sendable, Equatable, Codable {
    public var identifier: String
    public var before: ReminderDraft
    public var beforeList: String
    public var after: ReminderDraft
    public var afterList: String

    public init(identifier: String, before: ReminderDraft, beforeList: String, after: ReminderDraft, afterList: String) {
        self.identifier = identifier; self.before = before; self.beforeList = beforeList; self.after = after; self.afterList = afterList
    }
}

public struct MailDraft: Sendable, Equatable, Codable {
    public var recipients: [String]
    public var subject: String
    public var body: String

    public init(recipients: [String], subject: String, body: String) {
        self.recipients = recipients; self.subject = subject; self.body = body
    }
}

public struct DocumentDraft: Sendable, Equatable, Codable {
    public struct Section: Sendable, Equatable, Codable {
        public var title: String
        public var body: String
        public init(title: String, body: String) { self.title = title; self.body = body }
    }
    public var title: String
    public var subtitle: String
    public var sections: [Section]
    /// Testo dettato dall'utente, da mettere così com'è (senza titolo né sezioni generate).
    public var body: String?

    public init(title: String, subtitle: String, sections: [Section]) {
        self.title = title; self.subtitle = subtitle; self.sections = sections
    }

    /// Documento con esattamente il testo indicato; il nome è l'inizio del testo.
    public init(literal text: String) {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        title = words.isEmpty ? Language.t("Documento senza titolo", "Untitled document") : String(words.prefix(60))
        subtitle = ""
        sections = []
        body = text
    }
}

public struct SheetDraft: Sendable, Equatable, Codable {
    public struct Row: Sendable, Equatable, Identifiable, Codable {
        public var id = UUID()
        public var label: String
        public var values: [Double]
        public init(label: String, values: [Double]) { self.label = label; self.values = values }
    }
    public var title: String
    public var columns: [String]
    public var rows: [Row]

    public init(title: String, columns: [String], rows: [Row]) {
        self.title = title; self.columns = columns; self.rows = rows
    }
}

public struct DeckDraft: Sendable, Equatable, Codable {
    public struct Slide: Sendable, Equatable, Identifiable, Codable {
        public var id = UUID()
        public var title: String
        public var bullets: [String]
        public init(title: String, bullets: [String]) { self.title = title; self.bullets = bullets }
    }
    public var title: String
    public var subtitle: String
    public var slides: [Slide]

    public init(title: String, subtitle: String, slides: [Slide]) {
        self.title = title; self.subtitle = subtitle; self.slides = slides
    }
}

public struct PlanDraft: Sendable, Equatable, Codable {
    public enum Kind: String, CaseIterable, Sendable, Codable {
        case evento, promemoria, email, documento, foglio, presentazione

        public var source: SourceKind? {
            switch self {
            case .evento: .calendar
            case .promemoria: .reminders
            case .email: .mail
            case .documento, .foglio, .presentazione: nil
            }
        }
    }

    public struct Step: Sendable, Equatable, Identifiable, Codable {
        public var id = UUID()
        public var kind: Kind
        public var title: String
        public var when: String?
        public var detail: String
        public var included = true
    }

    public var goal: String
    public var summary: String
    public var steps: [Step]
}

/// Azione distruttiva o di modifica su un elemento esistente, da confermare.
public struct PendingAction: Sendable, Equatable, Codable {
    public enum Kind: Sendable, Equatable, Codable {
        case deleteEvent(identifier: String, start: Date)
        case completeReminder(identifier: String)
        case deleteReminder(identifier: String)
    }
    public var kind: Kind
    public var title: String
    public var detail: String
    /// Fotografia del bersaglio al momento dell'anteprima. Le vecchie schede senza fotografia vanno rifatte.
    public var expectedTitle: String?
    public var expectedContainer: String?

    public init(kind: Kind, title: String, detail: String, expectedTitle: String? = nil, expectedContainer: String? = nil) {
        self.kind = kind; self.title = title; self.detail = detail
        self.expectedTitle = expectedTitle; self.expectedContainer = expectedContainer
    }

    /// App in cui avviene l'azione.
    public var source: SourceKind {
        if case .deleteEvent = kind { return .calendar }
        return .reminders
    }
}

public struct Agenda: Sendable, Codable {
    public var title: String
    public var showsEvents: Bool
    public var showsReminders: Bool
    public var events: [EventItem]
    public var reminders: [ReminderItem]
    public var overdue: [ReminderItem]
}

// MARK: - Servizio EventKit

public enum EventKitService {
    static var ek: EKEventStore { Store.shared.ek }
    /// Le scritture sullo store condiviso non si sovrappongono (chat, agenti e sub-agent possono salvare insieme).
    private static let writeLock = NSLock()

    /// Tutti i calendari modificabili, senza i filtri dello spazio (per le impostazioni).
    public static func allWritableCalendars() -> [String] {
        ek.calendars(for: .event).filter(\.allowsContentModifications).map(\.title)
    }

    public static func allReminderLists() -> [String] { ek.calendars(for: .reminder).map(\.title) }

    /// Calendari dello spazio in uso (tutti se lo spazio non ne sceglie).
    public static func writableCalendars() -> [String] {
        let all = allWritableCalendars()
        guard let names = SpaceScope.current.calendars else { return all }
        let filtered = all.filter(names.contains)
        return filtered.isEmpty ? all : filtered
    }

    public static var defaultCalendar: String {
        let calendars = writableCalendars()
        if let preferred = SpaceScope.current.defaultCalendar, calendars.contains(preferred) { return preferred }
        if let system = ek.defaultCalendarForNewEvents?.title, calendars.contains(system) { return system }
        return calendars.first ?? ek.defaultCalendarForNewEvents?.title ?? ""
    }

    public static func reminderLists() -> [String] {
        let all = allReminderLists()
        guard let names = SpaceScope.current.reminderLists else { return all }
        let filtered = all.filter(names.contains)
        return filtered.isEmpty ? all : filtered
    }

    public static func reminderListColors() -> [String: RGB] {
        Dictionary(ek.calendars(for: .reminder).map { ($0.title, RGB($0.cgColor)) }, uniquingKeysWith: { a, _ in a })
    }

    public static var defaultReminderList: String {
        let lists = reminderLists()
        if let preferred = SpaceScope.current.defaultReminderList, lists.contains(preferred) { return preferred }
        if let system = ek.defaultCalendarForNewReminders()?.title, lists.contains(system) { return system }
        return lists.first ?? ""
    }

    /// Titoli degli eventi (non di tutto il giorno) che si sovrappongono all'intervallo.
    public static func conflicts(start: Date, end: Date) -> [EventItem] {
        guard end > start else { return [] }
        return Overview.events(from: start, to: end).filter { !$0.isAllDay && $0.start < end && $0.end > start }
    }

    @discardableResult
    public static func save(_ draft: EventDraft) throws -> String {
        writeLock.lock(); defer { writeLock.unlock() }
        let event = EKEvent(eventStore: ek)
        event.title = draft.title
        let writable = ek.calendars(for: .event).filter(\.allowsContentModifications)
        guard let calendar = writable.first(where: { $0.title == draft.calendar }) else {
            throw NSError(domain: AppInfo.name, code: 3, userInfo: [NSLocalizedDescriptionKey: Language.t(
                "Il calendario «\(draft.calendar)» non è più disponibile o modificabile. Prepara di nuovo l'evento.",
                "The calendar “\(draft.calendar)” is no longer available or editable. Prepare the event again.")])
        }
        event.calendar = calendar
        event.isAllDay = draft.isAllDay
        event.startDate = draft.start
        event.endDate = max(draft.end, draft.start.addingTimeInterval(draft.isAllDay ? 86_399 : 900))
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        try ek.save(event, span: .thisEvent, commit: true)
        Hooks.didModify()
        return event.eventIdentifier ?? event.calendarItemIdentifier
    }

    @discardableResult
    public static func save(_ drafts: [ReminderDraft], list: String) throws -> [String] {
        writeLock.lock(); defer { writeLock.unlock() }
        let lists = ek.calendars(for: .reminder)
        guard let calendar = lists.first(where: { $0.title == list && $0.allowsContentModifications }) else {
            throw NSError(domain: AppInfo.name, code: 3, userInfo: [NSLocalizedDescriptionKey: Language.t(
                "La lista «\(list)» non è più disponibile o modificabile. Prepara di nuovo il promemoria.",
                "The list “\(list)” is no longer available or editable. Prepare the reminder again.")])
        }
        var created: [EKReminder] = []
        do {
        for draft in drafts where draft.included && !draft.title.isEmpty {
            let reminder = EKReminder(eventStore: ek)
            reminder.title = draft.title
            reminder.calendar = calendar
            reminder.priority = draft.highPriority ? 1 : 0
            if let due = draft.due {
                let units: Set<Calendar.Component> = draft.dueHasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
                reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due)
                if draft.dueHasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
            }
            try ek.save(reminder, commit: false)
            created.append(reminder)
        }
        try ek.commit()
        } catch {
            // Tutto o niente: i promemoria già preparati non restano in sospeso nello store condiviso.
            ek.reset()
            throw error
        }
        Hooks.didModify()
        return created.map(\.calendarItemIdentifier)
    }

    /// Annulla una creazione appena fatta (evento o promemoria).
    public static func remove(identifiers: [String]) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        for id in identifiers {
            if let event = ek.event(withIdentifier: id) { try ek.remove(event, span: .thisEvent, commit: false) }
            else if let item = ek.calendarItem(withIdentifier: id) as? EKReminder { try ek.remove(item, commit: false) }
        }
        try ek.commit()
        Hooks.didModify()
    }

    @discardableResult
    public static func perform(_ action: PendingAction) throws -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        guard let expectedTitle = action.expectedTitle, !expectedTitle.isEmpty,
              let expectedContainer = action.expectedContainer, !expectedContainer.isEmpty else {
            throw NSError(domain: AppInfo.name, code: 5, userInfo: [NSLocalizedDescriptionKey: Language.t(
                "La vecchia anteprima non contiene i dati necessari per verificare il bersaglio. Prepara di nuovo l'azione.",
                "The old preview doesn't contain the data needed to check the target. Prepare the action again.")])
        }
        switch action.kind {
        case .deleteEvent(let identifier, let start):
            let predicate = ek.predicateForEvents(withStart: start.addingTimeInterval(-1), end: start.addingTimeInterval(1), calendars: nil)
            guard let event = ek.events(matching: predicate).first(where: {
                ($0.eventIdentifier ?? $0.calendarItemIdentifier) == identifier && abs($0.startDate.timeIntervalSince(start)) < 1
            }), event.title == expectedTitle, event.calendar.title == expectedContainer else {
                throw NSError(domain: AppInfo.name, code: 1, userInfo: [NSLocalizedDescriptionKey: Language.t(
                    "L'evento è cambiato o non è più nello stesso calendario. Prepara di nuovo l'azione.",
                    "The event changed or is no longer in the same calendar. Prepare the action again.")])
            }
            try ek.remove(event, span: .thisEvent, commit: true)
            Hooks.didModify()
            return !ek.events(matching: predicate).contains { ($0.eventIdentifier ?? $0.calendarItemIdentifier) == identifier && abs($0.startDate.timeIntervalSince(start)) < 1 }
        case .completeReminder(let identifier):
            guard let reminder = ek.calendarItem(withIdentifier: identifier) as? EKReminder else {
                throw NSError(domain: AppInfo.name, code: 2, userInfo: [NSLocalizedDescriptionKey: Language.t("Il promemoria non esiste più.", "The reminder no longer exists.")])
            }
            guard reminder.title == expectedTitle, reminder.calendar.title == expectedContainer, !reminder.isCompleted else {
                throw NSError(domain: AppInfo.name, code: 2, userInfo: [NSLocalizedDescriptionKey: Language.t("Il promemoria è cambiato. Prepara di nuovo l'azione.", "The reminder changed. Prepare the action again.")])
            }
            reminder.isCompleted = true
            try ek.save(reminder, commit: true)
            Hooks.didModify()
            return (ek.calendarItem(withIdentifier: identifier) as? EKReminder)?.isCompleted == true
        case .deleteReminder(let identifier):
            guard let reminder = ek.calendarItem(withIdentifier: identifier) as? EKReminder else {
                throw NSError(domain: AppInfo.name, code: 2, userInfo: [NSLocalizedDescriptionKey: Language.t("Il promemoria non esiste più.", "The reminder no longer exists.")])
            }
            guard reminder.title == expectedTitle, reminder.calendar.title == expectedContainer else {
                throw NSError(domain: AppInfo.name, code: 2, userInfo: [NSLocalizedDescriptionKey: Language.t("Il promemoria è cambiato. Prepara di nuovo l'azione.", "The reminder changed. Prepare the action again.")])
            }
            try ek.remove(reminder, commit: true)
            Hooks.didModify()
            return ek.calendarItem(withIdentifier: identifier) == nil
        }
    }

    // MARK: - Modifiche a eventi e promemoria esistenti

    /// L'occorrenza che inizia in quel momento (per gli eventi che si ripetono) o l'evento con quell'identificativo.
    static func occurrence(identifier: String, start: Date) -> EKEvent? {
        let predicate = ek.predicateForEvents(withStart: start.addingTimeInterval(-1), end: start.addingTimeInterval(1), calendars: nil)
        return ek.events(matching: predicate).first { ($0.eventIdentifier ?? $0.calendarItemIdentifier) == identifier && $0.startDate == start }
            ?? ek.events(matching: predicate).first { ($0.eventIdentifier ?? $0.calendarItemIdentifier) == identifier }
            ?? ek.event(withIdentifier: identifier)
    }

    /// Quanti invitati ha l'evento (il calendario può avvisarli di un cambiamento).
    public static func attendeeCount(identifier: String, start: Date) -> Int {
        occurrence(identifier: identifier, start: start)?.attendees?.count ?? 0
    }

    /// Applica i valori di `draft` all'evento (solo questa occorrenza). Restituisce il nuovo inizio, per ritrovarlo e annullare.
    @discardableResult
    public static func update(identifier: String, start: Date, to draft: EventDraft, expected: EventDraft? = nil) throws -> Date {
        writeLock.lock(); defer { writeLock.unlock() }
        guard let event = occurrence(identifier: identifier, start: start) else {
            throw NSError(domain: AppInfo.name, code: 1, userInfo: [NSLocalizedDescriptionKey: Language.t("L'evento non esiste più o è stato spostato.", "The event no longer exists or has been moved.")])
        }
        guard event.calendar.allowsContentModifications else {
            throw NSError(domain: AppInfo.name, code: 4, userInfo: [NSLocalizedDescriptionKey: Language.t("Il calendario «\(event.calendar.title)» è in sola lettura.", "The calendar “\(event.calendar.title)” is read-only.")])
        }
        if let expected {
            guard event.title == expected.title, event.startDate == expected.start, event.endDate == expected.end,
                  event.calendar.title == expected.calendar else {
                throw NSError(domain: AppInfo.name, code: 4, userInfo: [NSLocalizedDescriptionKey: Language.t("L'evento è cambiato dopo l'anteprima. Preparala di nuovo.", "The event changed after the preview. Prepare it again.")])
            }
        }
        let destination = ek.calendars(for: .event).first { $0.allowsContentModifications && $0.title == draft.calendar }
        guard let destination else {
            throw NSError(domain: AppInfo.name, code: 4, userInfo: [NSLocalizedDescriptionKey: Language.t("Il calendario di destinazione non è disponibile. Preparala di nuovo.", "The destination calendar isn't available. Prepare it again.")])
        }
        event.title = draft.title
        event.isAllDay = draft.isAllDay
        event.startDate = draft.start
        event.endDate = max(draft.end, draft.start.addingTimeInterval(draft.isAllDay ? 86_399 : 900))
        event.location = draft.location.isEmpty ? nil : draft.location
        event.calendar = destination
        try ek.save(event, span: .thisEvent, commit: true)
        Hooks.didModify()
        return event.startDate
    }

    /// Promemoria com'è adesso, con la sua lista.
    public static func reminder(identifier: String) -> (draft: ReminderDraft, list: String)? {
        guard let reminder = ek.calendarItem(withIdentifier: identifier) as? EKReminder else { return nil }
        let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        return (ReminderDraft(title: reminder.title ?? "", due: due, dueHasTime: reminder.dueDateComponents?.hour != nil,
                              highPriority: (1...4).contains(reminder.priority)), reminder.calendar.title)
    }

    /// Nuovo testo, scadenza, priorità o lista di un promemoria. La notifica segue la scadenza.
    public static func update(reminder identifier: String, to draft: ReminderDraft, list: String,
                              expected: ReminderDraft? = nil, expectedList: String? = nil) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard let reminder = ek.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw NSError(domain: AppInfo.name, code: 2, userInfo: [NSLocalizedDescriptionKey: Language.t("Il promemoria non esiste più.", "The reminder no longer exists.")])
        }
        if let expected {
            guard reminder.title == expected.title, reminder.calendar.title == expectedList,
                  reminder.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }) == expected.due else {
                throw NSError(domain: AppInfo.name, code: 2, userInfo: [NSLocalizedDescriptionKey: Language.t("Il promemoria è cambiato dopo l'anteprima. Preparalo di nuovo.", "The reminder changed after the preview. Prepare it again.")])
            }
        }
        guard let destination = ek.calendars(for: .reminder).first(where: { $0.title == list && $0.allowsContentModifications }) else {
            throw NSError(domain: AppInfo.name, code: 2, userInfo: [NSLocalizedDescriptionKey: Language.t("La lista di destinazione non è disponibile. Prepara di nuovo il promemoria.", "The destination list isn't available. Prepare the reminder again.")])
        }
        reminder.title = draft.title
        // La priorità cambia solo se passa da alta a normale o viceversa (una priorità media resta).
        if draft.highPriority != (1...4).contains(reminder.priority) { reminder.priority = draft.highPriority ? 1 : 0 }
        let oldDue = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        let newDue = draft.due
        if oldDue != newDue || (reminder.dueDateComponents?.hour != nil) != draft.dueHasTime {
            // Via la notifica legata alla vecchia scadenza; se la nuova ha un orario, notifica a quell'ora.
            for alarm in reminder.alarms ?? [] where alarm.absoluteDate != nil {
                if let oldDue, abs(alarm.absoluteDate!.timeIntervalSince(oldDue)) < 60 { reminder.removeAlarm(alarm) }
            }
            if let newDue {
                let units: Set<Calendar.Component> = draft.dueHasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
                reminder.dueDateComponents = Calendar.current.dateComponents(units, from: newDue)
                if draft.dueHasTime { reminder.addAlarm(EKAlarm(absoluteDate: newDue)) }
            } else {
                reminder.dueDateComponents = nil
            }
        }
        reminder.calendar = destination
        try ek.save(reminder, commit: true)
        Hooks.didModify()
    }
}
