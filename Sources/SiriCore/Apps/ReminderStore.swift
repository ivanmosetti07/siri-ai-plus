import EventKit
import Foundation

// MARK: - Promemoria (app Promemoria dentro Siri AI+)

public struct ReminderListInfo: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let title: String
    public let color: RGB
    public let account: String
    public let writable: Bool

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Un promemoria con tutto quello che si può modificare.
public struct ReminderEntry: Identifiable, Sendable, Equatable {
    public enum Priority: Int, CaseIterable, Sendable {
        case none = 0, high = 1, medium = 5, low = 9

        public var label: String {
            switch self {
            case .none: Language.t("Nessuna", "None")
            case .low: Language.t("Bassa", "Low")
            case .medium: Language.t("Media", "Medium")
            case .high: Language.t("Alta", "High")
            }
        }

        /// Il valore di EventKit (0–9) nella priorità più vicina.
        public init(level: Int) {
            switch level {
            case 1...4: self = .high
            case 5: self = .medium
            case 6...9: self = .low
            default: self = .none
            }
        }

        /// Punti esclamativi come in Promemoria.
        public var marks: String {
            switch self {
            case .none: ""
            case .low: "!"
            case .medium: "!!"
            case .high: "!!!"
            }
        }
    }

    /// Vuoto per un promemoria nuovo.
    public var id: String
    public var title: String
    public var notes: String
    public var url: String
    public var listID: String
    public var listTitle: String
    public var color: RGB
    public var due: Date?
    public var dueHasTime: Bool
    public var priority: Priority
    public var isCompleted: Bool
    public var completedAt: Date?
    public var isRecurring: Bool
    public var created: Date?

    public var isNew: Bool { id.isEmpty }

    public init(id: String = "", title: String = "", notes: String = "", url: String = "", listID: String, listTitle: String = "",
                color: RGB = RGB(red: 0.2, green: 0.5, blue: 1), due: Date? = nil, dueHasTime: Bool = false, priority: Priority = .none,
                isCompleted: Bool = false, completedAt: Date? = nil, isRecurring: Bool = false, created: Date? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.url = url; self.listID = listID; self.listTitle = listTitle
        self.color = color; self.due = due; self.dueHasTime = dueHasTime; self.priority = priority; self.isCompleted = isCompleted
        self.completedAt = completedAt; self.isRecurring = isRecurring; self.created = created
    }

    /// Scaduto (prima di oggi, o prima di adesso se ha un orario).
    public var isOverdue: Bool {
        guard let due, !isCompleted else { return false }
        return dueHasTime ? due < .now : due < Calendar.current.startOfDay(for: .now)
    }
}

public enum ReminderStore {
    static var ek: EKEventStore { Store.shared.ek }
    private static let writeLock = NSLock()

    public static var authorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    public static func lists() -> [ReminderListInfo] {
        ek.calendars(for: .reminder)
            .map { ReminderListInfo(id: $0.calendarIdentifier, title: $0.title, color: RGB($0.cgColor),
                                    account: $0.source?.title ?? Language.t("Altro", "Other"), writable: $0.allowsContentModifications) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    public static var defaultListID: String {
        let name = EventKitService.defaultReminderList
        let all = ek.calendars(for: .reminder)
        return (all.first { $0.title == name } ?? ek.defaultCalendarForNewReminders() ?? all.first)?.calendarIdentifier ?? ""
    }

    /// Promemoria da fare (o completati negli ultimi 12 mesi) delle liste indicate (nil = tutte).
    public static func fetch(completed: Bool, listIDs: Set<String>?) async -> [ReminderEntry] {
        var calendars: [EKCalendar]?
        if let listIDs {
            calendars = ek.calendars(for: .reminder).filter { listIDs.contains($0.calendarIdentifier) }
            if calendars?.isEmpty == true { return [] }
        }
        let predicate = completed
            ? ek.predicateForCompletedReminders(withCompletionDateStarting: Calendar.current.date(byAdding: .year, value: -1, to: .now),
                                                ending: nil, calendars: calendars)
            : ek.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        let entries: [ReminderEntry] = await withCheckedContinuation { continuation in
            ek.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(entry))
            }
        }
        return entries
    }

    static func entry(_ reminder: EKReminder) -> ReminderEntry {
        ReminderEntry(id: reminder.calendarItemIdentifier, title: reminder.title ?? "", notes: reminder.notes ?? "",
                      url: reminder.url?.absoluteString ?? "", listID: reminder.calendar.calendarIdentifier,
                      listTitle: reminder.calendar.title, color: RGB(reminder.calendar.cgColor),
                      due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                      dueHasTime: reminder.dueDateComponents?.hour != nil,
                      priority: .init(level: reminder.priority), isCompleted: reminder.isCompleted,
                      completedAt: reminder.completionDate, isRecurring: reminder.hasRecurrenceRules, created: reminder.creationDate)
    }

    /// Crea o salva un promemoria; restituisce l'identificativo.
    @discardableResult
    public static func save(_ entry: ReminderEntry) throws -> String {
        writeLock.lock(); defer { writeLock.unlock() }
        let reminder: EKReminder
        if entry.isNew {
            reminder = EKReminder(eventStore: ek)
        } else {
            guard let existing = ek.calendarItem(withIdentifier: entry.id) as? EKReminder else { throw storeError(Language.t("Il promemoria non esiste più.", "The reminder no longer exists.")) }
            reminder = existing
        }
        guard let list = ek.calendar(withIdentifier: entry.listID) ?? ek.defaultCalendarForNewReminders() else {
            throw storeError(Language.t("Nessuna lista di promemoria disponibile.", "No reminder list available."))
        }
        guard list.allowsContentModifications else { throw storeError(Language.t("La lista «\(list.title)» è in sola lettura.", "The list “\(list.title)” is read-only.")) }
        reminder.calendar = list
        reminder.title = entry.title.trimmingCharacters(in: .whitespaces).isEmpty ? Language.t("Nuovo promemoria", "New Reminder") : entry.title
        reminder.notes = entry.notes.isEmpty ? nil : entry.notes
        reminder.url = URL(string: entry.url.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? URL(string: "https://" + $0.absoluteString) : $0 }
        reminder.priority = entry.priority.rawValue
        let oldDue = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        let hadTime = reminder.dueDateComponents?.hour != nil
        if entry.isNew || oldDue != entry.due || hadTime != entry.dueHasTime {
            // L'avviso segue la scadenza: via quello della scadenza vecchia, nuovo avviso se c'è un orario.
            for alarm in reminder.alarms ?? [] {
                if let date = alarm.absoluteDate, let oldDue, abs(date.timeIntervalSince(oldDue)) < 60 { reminder.removeAlarm(alarm) }
            }
            if let due = entry.due {
                let units: Set<Calendar.Component> = entry.dueHasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
                reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due)
                if entry.dueHasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
            } else {
                reminder.dueDateComponents = nil
            }
        }
        if entry.isCompleted != reminder.isCompleted { reminder.isCompleted = entry.isCompleted }
        try ek.save(reminder, commit: true)
        Hooks.didModify()
        return reminder.calendarItemIdentifier
    }

    public static func setCompleted(_ id: String, _ completed: Bool) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard let reminder = ek.calendarItem(withIdentifier: id) as? EKReminder else { throw storeError(Language.t("Il promemoria non esiste più.", "The reminder no longer exists.")) }
        reminder.isCompleted = completed
        try ek.save(reminder, commit: true)
        Hooks.didModify()
    }

    public static func delete(_ id: String) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard let reminder = ek.calendarItem(withIdentifier: id) as? EKReminder else { throw storeError(Language.t("Il promemoria non esiste più.", "The reminder no longer exists.")) }
        try ek.remove(reminder, commit: true)
        Hooks.didModify()
    }

    // MARK: Liste

    /// Nuova lista nello stesso account della lista predefinita.
    @discardableResult
    public static func createList(title: String, color: RGB) throws -> String {
        writeLock.lock(); defer { writeLock.unlock() }
        let list = EKCalendar(for: .reminder, eventStore: ek)
        list.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? Language.t("Nuova lista", "New List") : title
        list.cgColor = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        guard let source = ek.defaultCalendarForNewReminders()?.source ?? ek.sources.first(where: { $0.sourceType == .calDAV || $0.sourceType == .local }) else {
            throw storeError(Language.t("Non trovo un account in cui creare la lista.", "I can't find an account to create the list in."))
        }
        list.source = source
        try ek.saveCalendar(list, commit: true)
        Hooks.didModify()
        return list.calendarIdentifier
    }

    public static func updateList(_ id: String, title: String, color: RGB) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard let list = ek.calendar(withIdentifier: id) else { throw storeError(Language.t("La lista non esiste più.", "The list no longer exists.")) }
        guard list.allowsContentModifications else { throw storeError(Language.t("La lista «\(list.title)» non si può modificare.", "The list “\(list.title)” can't be edited.")) }
        list.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? list.title : title
        list.cgColor = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        try ek.saveCalendar(list, commit: true)
        Hooks.didModify()
    }

    /// Elimina la lista con tutti i suoi promemoria.
    public static func deleteList(_ id: String) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard let list = ek.calendar(withIdentifier: id) else { throw storeError(Language.t("La lista non esiste più.", "The list no longer exists.")) }
        try ek.removeCalendar(list, commit: true)
        Hooks.didModify()
    }

    static func storeError(_ message: String) -> NSError {
        NSError(domain: AppInfo.name, code: 11, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
