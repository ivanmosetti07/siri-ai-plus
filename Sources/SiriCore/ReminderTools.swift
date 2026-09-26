import EventKit
import Foundation
import FoundationModels

private struct ReminderInfo: Sendable {
    let identifier: String
    let title: String
    let list: String
    let due: Date?
    let dueHasTime: Bool
    let completed: Bool
    let priority: Int
}

private func fetchReminders(_ predicate: NSPredicate) async -> [ReminderInfo] {
    await withCheckedContinuation { continuation in
        Store.shared.ek.fetchReminders(matching: predicate) { reminders in
            let infos = (reminders ?? []).map { r in
                ReminderInfo(
                    identifier: r.calendarItemIdentifier,
                    title: r.title ?? Language.t("(senza titolo)", "(untitled)"),
                    list: r.calendar.title,
                    due: r.dueDateComponents?.date ?? r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                    dueHasTime: r.dueDateComponents?.hour != nil,
                    completed: r.isCompleted,
                    priority: r.priority
                )
            }
            continuation.resume(returning: infos)
        }
    }
}

struct GetRemindersTool: Tool {
    let name = "get_reminders"
    let description = "Elenca i promemoria, per default solo quelli da completare."
    let parameters = makeSchema("GetRemindersArgs", [
        .optional("list", .string, "Nome della lista promemoria"),
        .optional("due_before", .string, "Solo quelli in scadenza entro questa data, yyyy-MM-dd"),
        .optional("due_after", .string, "Solo quelli in scadenza da questa data in poi, yyyy-MM-dd"),
        .optional("include_completed", .bool, "true per includere anche i completati"),
    ])

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        Console.toolCall(name, [arguments.string("list"), arguments.string("due_before").map { "entro \($0)" }].compactMap { $0 }.joined(separator: " · "))
        let store = Store.shared
        var calendars: [EKCalendar]? = nil
        if let listName = arguments.string("list") {
            guard let list = store.reminderList(named: listName) else {
                return "Errore: lista «\(listName)» non trovata. Usa list_calendars."
            }
            calendars = [list]
        }

        var dueBefore: Date? = nil
        if let parsed = Dates.parse(arguments.string("due_before")) {
            let cal = Calendar.current
            dueBefore = parsed.hasTime ? parsed.date : cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: parsed.date))
        }

        let predicate = arguments.bool("include_completed") == true
            ? store.ek.predicateForReminders(in: calendars)
            : store.ek.predicateForIncompleteReminders(withDueDateStarting: nil, ending: dueBefore, calendars: calendars)
        var items = await fetchReminders(predicate)
        if let dueBefore { items = items.filter { ($0.due ?? .distantFuture) < dueBefore } }
        if let dueAfter = Dates.parse(arguments.string("due_after")) {
            let start = dueAfter.hasTime ? dueAfter.date : Calendar.current.startOfDay(for: dueAfter.date)
            items = items.filter { ($0.due ?? .distantPast) >= start }
        }
        items.sort { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        guard !items.isEmpty else { return "Nessun promemoria trovato." }

        let lines = items.prefix(30).map { item -> String in
            let id = IDRegistry.shared.register(reminder: item.identifier)
            var details = ["lista \(item.list)"]
            if let due = item.due { details.append("scade \(Dates.format(due, time: item.dueHasTime))") }
            if item.priority > 0 && item.priority <= 4 { details.append("priorità alta") }
            if item.completed { details.append("completato") }
            return "[\(id)] «\(item.title)» (\(details.joined(separator: ", ")))"
        }
        let extra = items.count > 30 ? "\n…e altri \(items.count - 30)." : ""
        return lines.joined(separator: "\n") + extra
    }
}

struct CreateReminderTool: Tool {
    let name = "create_reminder"
    let description = "Crea un nuovo promemoria, con scadenza e notifica opzionali."
    let parameters = makeSchema("CreateReminderArgs", [
        .required("title", .string, "Testo del promemoria"),
        .optional("due", .string, "Scadenza, yyyy-MM-dd HH:mm oppure yyyy-MM-dd"),
        .optional("list", .string, "Nome della lista promemoria"),
        .optional("notes", .string, "Note"),
        .optional("priority", .choice(["nessuna", "bassa", "media", "alta"]), "Priorità"),
    ])

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        Console.toolCall(name, "«\(arguments.string("title") ?? "?")»" + (arguments.string("due").map { " · \($0)" } ?? ""))
        guard let title = arguments.string("title") else { return "Errore: testo mancante." }
        let store = Store.shared
        guard let list = store.reminderList(named: arguments.string("list")) else {
            return "Errore: lista non trovata. Usa list_calendars."
        }

        let reminder = EKReminder(eventStore: store.ek)
        reminder.title = title
        reminder.calendar = list
        reminder.notes = arguments.string("notes")
        reminder.priority = switch arguments.string("priority") {
        case "alta": 1
        case "media": 5
        case "bassa": 9
        default: 0
        }

        var dueText = "senza scadenza"
        if let raw = arguments.string("due") {
            guard let due = Dates.parse(raw) else { return "Errore: scadenza non valida. Usa yyyy-MM-dd HH:mm." }
            let units: Set<Calendar.Component> = due.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due.date)
            if due.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
            dueText = "scadenza \(Dates.format(due.date, time: due.hasTime))"
        }

        guard await Console.confirm("Creo promemoria «\(title)» (\(dueText)) nella lista «\(list.title)»") else {
            return "L'utente ha annullato la creazione del promemoria."
        }
        do {
            try store.ek.save(reminder, commit: true)
        } catch {
            return "Errore nel salvataggio: \(error.localizedDescription)"
        }
        let id = IDRegistry.shared.register(reminder: reminder.calendarItemIdentifier)
        Hooks.didModify()
        return "Promemoria creato [\(id)]: \(title), \(dueText), lista \(list.title)."
    }
}

struct CompleteReminderTool: Tool {
    let name = "complete_reminder"
    let description = "Segna un promemoria come completato. Serve l'ID (es. R2) da get_reminders."
    let parameters = makeSchema("CompleteReminderArgs", [
        .required("id", .string, "ID del promemoria, es. R2"),
    ])

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        let key = arguments.string("id") ?? ""
        Console.toolCall(name, key)
        guard let identifier = IDRegistry.shared.reminder(key) else {
            return "Errore: ID \(key) sconosciuto. Cerca prima con get_reminders."
        }
        let ek = Store.shared.ek
        guard let reminder = ek.calendarItem(withIdentifier: identifier) as? EKReminder else {
            return "Errore: promemoria non più presente."
        }
        let title = reminder.title ?? Language.t("(senza titolo)", "(untitled)")
        guard await Console.confirm("Segno come completato «\(title)»") else {
            return "L'utente ha annullato."
        }
        reminder.isCompleted = true
        do {
            try ek.save(reminder, commit: true)
        } catch {
            return "Errore nel salvataggio: \(error.localizedDescription)"
        }
        Hooks.didModify()
        return "Promemoria «\(title)» completato."
    }
}
