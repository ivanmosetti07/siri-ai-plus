import EventKit
import Foundation

// MARK: - Calendario (app Calendario dentro Siri AI+)

/// Un calendario di Calendario, con il suo account.
public struct CalendarInfo: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let title: String
    public let color: RGB
    public let account: String
    public let writable: Bool

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Un evento (o un'occorrenza di un evento che si ripete) come lo mostra la griglia.
public struct CalendarEvent: Identifiable, Sendable, Equatable {
    /// Identificativo + inizio: le occorrenze dello stesso evento restano distinte.
    public let id: String
    public let identifier: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendarID: String
    public let calendarTitle: String
    public let color: RGB
    public let location: String?
    public let isRecurring: Bool
    public let writable: Bool
}

/// Tutto quello che si può vedere e modificare di un evento.
public struct EventDetail: Sendable, Equatable {
    public enum Repeat: String, CaseIterable, Sendable {
        case never, daily, weekdays, weekly, biweekly, monthly, yearly, custom

        public var label: String {
            switch self {
            case .never: Language.t("Mai", "Never")
            case .daily: Language.t("Ogni giorno", "Every Day")
            case .weekdays: Language.t("Nei giorni feriali", "Every Weekday")
            case .weekly: Language.t("Ogni settimana", "Every Week")
            case .biweekly: Language.t("Ogni 2 settimane", "Every 2 Weeks")
            case .monthly: Language.t("Ogni mese", "Every Month")
            case .yearly: Language.t("Ogni anno", "Every Year")
            case .custom: Language.t("Personalizzata", "Custom")
            }
        }
    }

    public enum Alert: Int, CaseIterable, Sendable {
        /// Minuti prima dell'inizio (-1 = nessun avviso).
        case none = -1, atStart = 0, five = 5, ten = 10, fifteen = 15, thirty = 30, hour = 60, twoHours = 120, day = 1440, twoDays = 2880

        public var label: String {
            switch self {
            case .none: Language.t("Nessuno", "None")
            case .atStart: Language.t("All'ora dell'evento", "At time of event")
            case .five: Language.t("5 minuti prima", "5 minutes before")
            case .ten: Language.t("10 minuti prima", "10 minutes before")
            case .fifteen: Language.t("15 minuti prima", "15 minutes before")
            case .thirty: Language.t("30 minuti prima", "30 minutes before")
            case .hour: Language.t("1 ora prima", "1 hour before")
            case .twoHours: Language.t("2 ore prima", "2 hours before")
            case .day: Language.t("1 giorno prima", "1 day before")
            case .twoDays: Language.t("2 giorni prima", "2 days before")
            }
        }
    }

    /// Vuoto per un evento nuovo.
    public var identifier: String
    /// Inizio dell'occorrenza aperta (per ritrovarla negli eventi che si ripetono).
    public var occurrence: Date
    public var title: String
    public var location: String
    public var notes: String
    public var url: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendarID: String
    public var repeatRule: Repeat
    public var alert: Alert
    public var attendees: [String]
    public var organizer: String?
    public var isRecurring: Bool
    public var writable: Bool

    public var isNew: Bool { identifier.isEmpty }

    public init(identifier: String = "", occurrence: Date? = nil, title: String = "", location: String = "", notes: String = "", url: String = "",
                start: Date, end: Date, isAllDay: Bool = false, calendarID: String, repeatRule: Repeat = .never, alert: Alert = .none,
                attendees: [String] = [], organizer: String? = nil, isRecurring: Bool = false, writable: Bool = true) {
        self.identifier = identifier; self.occurrence = occurrence ?? start; self.title = title; self.location = location
        self.notes = notes; self.url = url; self.start = start; self.end = end; self.isAllDay = isAllDay; self.calendarID = calendarID
        self.repeatRule = repeatRule; self.alert = alert; self.attendees = attendees; self.organizer = organizer
        self.isRecurring = isRecurring; self.writable = writable
    }
}

public enum CalendarStore {
    static var ek: EKEventStore { Store.shared.ek }
    private static let writeLock = NSLock()

    public static var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Tutti i calendari, per account (i compleanni e gli abbonamenti sono in sola lettura).
    public static func calendars() -> [CalendarInfo] {
        ek.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: RGB($0.cgColor),
                                account: $0.source?.title ?? Language.t("Altro", "Other"), writable: $0.allowsContentModifications) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    /// Calendario predefinito per i nuovi eventi (quello dello spazio, se c'è).
    public static var defaultCalendarID: String {
        let name = EventKitService.defaultCalendar
        let writable = ek.calendars(for: .event).filter(\.allowsContentModifications)
        return (writable.first { $0.title == name } ?? ek.defaultCalendarForNewEvents ?? writable.first)?.calendarIdentifier ?? ""
    }

    /// Eventi nell'intervallo, solo dai calendari indicati (nil = tutti).
    public static func events(from start: Date, to end: Date, calendarIDs: Set<String>?) -> [CalendarEvent] {
        var calendars: [EKCalendar]?
        if let calendarIDs {
            calendars = ek.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
            if calendars?.isEmpty == true { return [] }
        }
        return ek.events(matching: ek.predicateForEvents(withStart: start, end: end, calendars: calendars))
            .sorted { ($0.startDate, $0.isAllDay ? 0 : 1) < ($1.startDate, $1.isAllDay ? 0 : 1) }
            .map(item)
    }

    static func item(_ event: EKEvent) -> CalendarEvent {
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        return CalendarEvent(id: identifier + "@\(event.startDate.timeIntervalSince1970)", identifier: identifier,
                             title: event.title?.isEmpty == false ? event.title! : Language.t("Nuovo evento", "New Event"),
                             start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                             calendarID: event.calendar.calendarIdentifier, calendarTitle: event.calendar.title,
                             color: RGB(event.calendar.cgColor),
                             location: event.location?.isEmpty == false ? event.location : nil,
                             isRecurring: event.hasRecurrenceRules, writable: event.calendar.allowsContentModifications)
    }

    /// Cerca per titolo, luogo o note nei 12 mesi intorno a oggi.
    public static func search(_ text: String, calendarIDs: Set<String>?) -> [CalendarEvent] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let cal = Calendar.current
        let from = cal.date(byAdding: .month, value: -6, to: .now)!
        let to = cal.date(byAdding: .month, value: 6, to: .now)!
        var calendars: [EKCalendar]?
        if let calendarIDs { calendars = ek.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) } }
        return ek.events(matching: ek.predicateForEvents(withStart: from, end: to, calendars: calendars))
            .filter { event in
                [event.title, event.location, event.notes].compactMap { $0 }
                    .contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(200)
            .map(item)
    }

    /// L'occorrenza che inizia in quel momento, o l'evento con quell'identificativo.
    static func occurrence(identifier: String, start: Date) -> EKEvent? {
        EventKitService.occurrence(identifier: identifier, start: start)
    }

    public static func detail(identifier: String, start: Date) -> EventDetail? {
        guard let event = occurrence(identifier: identifier, start: start) else { return nil }
        return detail(of: event)
    }

    static func detail(of event: EKEvent) -> EventDetail {
        let alert: EventDetail.Alert = event.alarms?.first.flatMap { alarm in
            guard alarm.absoluteDate == nil else { return nil }
            return EventDetail.Alert(rawValue: Int((-alarm.relativeOffset / 60).rounded()))
        } ?? .none
        return EventDetail(identifier: event.eventIdentifier ?? event.calendarItemIdentifier, occurrence: event.startDate,
                           title: event.title ?? "", location: event.location ?? "", notes: event.notes ?? "",
                           url: event.url?.absoluteString ?? "", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                           calendarID: event.calendar.calendarIdentifier, repeatRule: repeatRule(of: event), alert: alert,
                           attendees: (event.attendees ?? []).map { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") },
                           organizer: event.organizer?.name, isRecurring: event.hasRecurrenceRules,
                           writable: event.calendar.allowsContentModifications)
    }

    static func repeatRule(of event: EKEvent) -> EventDetail.Repeat {
        guard let rules = event.recurrenceRules, let rule = rules.first else { return .never }
        // Con una fine o più regole la ripetizione resta com'è (si cambia in Calendario).
        guard rules.count == 1, rule.recurrenceEnd == nil else { return .custom }
        switch rule.frequency {
        case .daily: return rule.interval == 1 ? .daily : .custom
        case .weekly:
            let days = rule.daysOfTheWeek?.map(\.dayOfTheWeek.rawValue).sorted() ?? []
            if days == [2, 3, 4, 5, 6], rule.interval == 1 { return .weekdays }
            if days.count > 1 { return .custom }
            return rule.interval == 1 ? .weekly : rule.interval == 2 ? .biweekly : .custom
        case .monthly: return rule.interval == 1 ? .monthly : .custom
        case .yearly: return rule.interval == 1 ? .yearly : .custom
        @unknown default: return .custom
        }
    }

    static func rule(for value: EventDetail.Repeat) -> EKRecurrenceRule? {
        switch value {
        case .never, .custom: nil
        case .daily: EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case .weekdays: EKRecurrenceRule(recurrenceWith: .weekly, interval: 1,
                                         daysOfTheWeek: [.monday, .tuesday, .wednesday, .thursday, .friday].map { EKRecurrenceDayOfWeek($0) },
                                         daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
        case .weekly: EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case .biweekly: EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)
        case .monthly: EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case .yearly: EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        }
    }

    /// Crea o salva un evento. `futureEvents`: per gli eventi che si ripetono, la modifica vale anche per i successivi.
    /// Restituisce identificativo e inizio (per riaprirlo).
    @discardableResult
    public static func save(_ detail: EventDetail, futureEvents: Bool = false) throws -> (identifier: String, start: Date) {
        writeLock.lock(); defer { writeLock.unlock() }
        let event: EKEvent
        if detail.isNew {
            event = EKEvent(eventStore: ek)
        } else {
            guard let existing = occurrence(identifier: detail.identifier, start: detail.occurrence) else {
                throw storeError(Language.t("L'evento non esiste più o è stato spostato.", "The event no longer exists or has been moved."))
            }
            event = existing
        }
        guard let calendar = ek.calendar(withIdentifier: detail.calendarID) ?? (detail.isNew ? ek.defaultCalendarForNewEvents : event.calendar),
              calendar.allowsContentModifications else {
            throw storeError(Language.t("Il calendario scelto è in sola lettura.", "The chosen calendar is read-only."))
        }
        if !detail.isNew, !event.calendar.allowsContentModifications { throw storeError(Language.t("Il calendario «\(event.calendar.title)» è in sola lettura.", "The calendar “\(event.calendar.title)” is read-only.")) }
        event.calendar = calendar
        event.title = detail.title.trimmingCharacters(in: .whitespaces).isEmpty ? Language.t("Nuovo evento", "New Event") : detail.title
        event.location = detail.location.isEmpty ? nil : detail.location
        event.notes = detail.notes.isEmpty ? nil : detail.notes
        event.url = URL(string: detail.url.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? URL(string: "https://" + $0.absoluteString) : $0 }
        event.isAllDay = detail.isAllDay
        if detail.isAllDay {
            // Tutto il giorno: dal primo giorno alla fine dell'ultimo (compreso).
            let cal = Calendar.current
            event.startDate = cal.startOfDay(for: detail.start)
            let lastDay = max(cal.startOfDay(for: detail.end), cal.startOfDay(for: detail.start))
            event.endDate = cal.date(bySettingHour: 23, minute: 59, second: 59, of: lastDay) ?? lastDay.addingTimeInterval(86_399)
        } else {
            event.startDate = detail.start
            event.endDate = max(detail.end, detail.start.addingTimeInterval(300))
        }
        // La ripetizione si tocca solo se è stata cambiata: una regola con una fine non va persa.
        let currentRepeat: EventDetail.Repeat = detail.isNew ? .never : repeatRule(of: event)
        var span: EKSpan = futureEvents ? .futureEvents : .thisEvent
        if detail.repeatRule != .custom, detail.repeatRule != currentRepeat {
            for existing in event.recurrenceRules ?? [] { event.removeRecurrenceRule(existing) }
            if let rule = rule(for: detail.repeatRule) { event.addRecurrenceRule(rule) }
            span = .futureEvents
        }
        // Avviso: si sostituiscono solo quelli relativi (gli altri sono stati messi altrove e restano).
        for alarm in event.alarms ?? [] where alarm.absoluteDate == nil { event.removeAlarm(alarm) }
        if detail.alert != .none { event.addAlarm(EKAlarm(relativeOffset: -Double(detail.alert.rawValue) * 60)) }
        try ek.save(event, span: span, commit: true)
        Hooks.didModify()
        return (event.eventIdentifier ?? event.calendarItemIdentifier, event.startDate)
    }

    /// Sposta un evento (trascinato nella griglia) mantenendo tutto il resto.
    public static func move(identifier: String, start: Date, to newStart: Date, end newEnd: Date) throws {
        guard var detail = detail(identifier: identifier, start: start) else { throw storeError(Language.t("L'evento non esiste più.", "The event no longer exists.")) }
        detail.start = newStart
        detail.end = newEnd
        try save(detail)
    }

    public static func delete(identifier: String, start: Date, futureEvents: Bool = false) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard let event = occurrence(identifier: identifier, start: start) else { throw storeError(Language.t("L'evento non esiste più.", "The event no longer exists.")) }
        guard event.calendar.allowsContentModifications else { throw storeError(Language.t("Il calendario «\(event.calendar.title)» è in sola lettura.", "The calendar “\(event.calendar.title)” is read-only.")) }
        try ek.remove(event, span: futureEvents ? .futureEvents : .thisEvent, commit: true)
        Hooks.didModify()
    }

    /// Copia dell'evento, lo stesso giorno subito dopo (o nello stesso orario se è di tutto il giorno).
    @discardableResult
    public static func duplicate(identifier: String, start: Date) throws -> (identifier: String, start: Date) {
        guard var copy = detail(identifier: identifier, start: start) else { throw storeError(Language.t("L'evento non esiste più.", "The event no longer exists.")) }
        copy.identifier = ""
        copy.repeatRule = copy.repeatRule == .custom ? .never : copy.repeatRule
        copy.title += Language.t(" (copia)", " (copy)")
        return try save(copy)
    }

    static func storeError(_ message: String) -> NSError {
        NSError(domain: AppInfo.name, code: 10, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
