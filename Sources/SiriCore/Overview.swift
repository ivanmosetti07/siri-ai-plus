import AppKit
import EventKit
import Foundation

/// Letture dirette da EventKit, senza passare dal modello.
public struct EventItem: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let identifier: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendar: String
    public let color: RGB
    public let location: String?

    public init(id: String, identifier: String, title: String, start: Date, end: Date, isAllDay: Bool, calendar: String, color: RGB, location: String?) {
        self.id = id; self.identifier = identifier; self.title = title; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.calendar = calendar; self.color = color; self.location = location
    }
}

public struct ReminderItem: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let list: String
    public let due: Date?
    public let dueHasTime: Bool
    public let highPriority: Bool
    public let color: RGB

    public init(id: String, title: String, list: String, due: Date?, dueHasTime: Bool, highPriority: Bool, color: RGB) {
        self.id = id; self.title = title; self.list = list; self.due = due
        self.dueHasTime = dueHasTime; self.highPriority = highPriority; self.color = color
    }
}

public struct RGB: Sendable, Equatable, Codable {
    public let red: Double, green: Double, blue: Double

    public init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }

    init(_ cgColor: CGColor?) {
        let c = cgColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) } ?? .systemBlue
        red = c.redComponent; green = c.greenComponent; blue = c.blueComponent
    }
}

public enum Overview {
    public static func events(on day: Date = .now) -> [EventItem] {
        let start = Calendar.current.startOfDay(for: day)
        return events(from: start, to: Calendar.current.date(byAdding: .day, value: 1, to: start)!)
    }

    public static func events(from start: Date, to end: Date) -> [EventItem] {
        if let world = FixtureWorld.active { return world.events(from: start, to: end) }
        let ek = Store.shared.ek
        // Solo i calendari dello spazio in uso.
        var calendars: [EKCalendar]?
        if let names = SpaceScope.current.calendars {
            calendars = ek.calendars(for: .event).filter { names.contains($0.title) }
            if calendars?.isEmpty == true { return [] }
        }
        return ek.events(matching: ek.predicateForEvents(withStart: start, end: end, calendars: calendars))
            .sorted { ($0.startDate, $0.isAllDay ? 0 : 1) < ($1.startDate, $1.isAllDay ? 0 : 1) }
            .map {
                let identifier = $0.eventIdentifier ?? $0.calendarItemIdentifier
                return EventItem(
                    id: identifier + "\($0.startDate.timeIntervalSince1970)",
                    identifier: identifier,
                    title: $0.title ?? Language.t("(senza titolo)", "(untitled)"),
                    start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay,
                    calendar: $0.calendar.title, color: RGB($0.calendar.cgColor),
                    location: $0.location?.isEmpty == false ? $0.location : nil
                )
            }
    }

    /// Promemoria da completare, prima quelli con scadenza.
    public static func openReminders(limit: Int = 40, list: String? = nil) async -> [ReminderItem] {
        if let world = FixtureWorld.active { return world.openReminders(limit: limit, list: list) }
        let ek = Store.shared.ek
        // Solo le liste dello spazio, anche quando la richiesta ne nomina una.
        let scoped = SpaceScope.current.reminderLists.map { names in ek.calendars(for: .reminder).filter { names.contains($0.title) } }
            ?? ek.calendars(for: .reminder)
        var calendars = list.flatMap { name in scoped.filter { $0.title.localizedCaseInsensitiveContains(name) } }
        if calendars?.isEmpty != false, SpaceScope.current.reminderLists != nil {
            calendars = scoped
            if scoped.isEmpty { return [] }
        }
        let predicate = ek.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: calendars?.isEmpty == false ? calendars : nil
        )
        let items: [ReminderItem] = await withCheckedContinuation { continuation in
            ek.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).map { r in
                    ReminderItem(
                        id: r.calendarItemIdentifier,
                        title: r.title ?? Language.t("(senza titolo)", "(untitled)"),
                        list: r.calendar.title,
                        due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                        dueHasTime: r.dueDateComponents?.hour != nil,
                        highPriority: (1...4).contains(r.priority),
                        color: RGB(r.calendar.cgColor)
                    )
                }
                continuation.resume(returning: items)
            }
        }
        return Array(items.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.prefix(limit))
    }

    /// Quanti promemoria (delle liste dello spazio) sono stati completati da `start` a ora: i progressi della giornata.
    public static func completedReminders(since start: Date) async -> Int {
        if FixtureWorld.active != nil { return 0 }
        let ek = Store.shared.ek
        let calendars = SpaceScope.current.reminderLists.map { names in ek.calendars(for: .reminder).filter { names.contains($0.title) } }
        if calendars?.isEmpty == true { return 0 }
        let predicate = ek.predicateForCompletedReminders(withCompletionDateStarting: start, ending: .now, calendars: calendars)
        return await withCheckedContinuation { continuation in
            ek.fetchReminders(matching: predicate) { continuation.resume(returning: $0?.count ?? 0) }
        }
    }

    public static func setCompleted(reminderID: String, _ completed: Bool) throws {
        if let refused = FixtureWorld.refuse("Promemoria: completamento") { throw refused }
        let ek = Store.shared.ek
        guard let reminder = ek.calendarItem(withIdentifier: reminderID) as? EKReminder else { return }
        reminder.isCompleted = completed
        try ek.save(reminder, commit: true)
    }
}
