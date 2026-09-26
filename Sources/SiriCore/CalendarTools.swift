import EventKit
import Foundation
import FoundationModels

struct ListCalendarsTool: Tool {
    let name = "list_calendars"
    let description = "Elenca i calendari e le liste di promemoria disponibili."
    let parameters = makeSchema("ListCalendarsArgs", [])

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        Console.toolCall(name, "")
        let ek = Store.shared.ek
        let cals = ek.calendars(for: .event).map { $0.title + ($0.allowsContentModifications ? "" : " (sola lettura)") }
        let lists = ek.calendars(for: .reminder).map(\.title)
        return """
        Calendari: \(cals.isEmpty ? "nessuno" : cals.joined(separator: ", "))
        Liste promemoria: \(lists.isEmpty ? "nessuna" : lists.joined(separator: ", "))
        """
    }
}

struct GetEventsTool: Tool {
    let name = "get_events"
    let description = "Cerca gli eventi del calendario in un intervallo di date."
    let parameters = makeSchema("GetEventsArgs", [
        .required("from", .string, "Inizio, formato yyyy-MM-dd o yyyy-MM-dd HH:mm"),
        .optional("to", .string, "Fine, stesso formato. Se assente: fine del giorno di inizio"),
        .optional("query", .string, "Testo da cercare nel titolo"),
    ])

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        let query = arguments.string("query")
        Console.toolCall(name, [arguments.string("from"), arguments.string("to")].compactMap { $0 }.joined(separator: " → ") + (query.map { " · «\($0)»" } ?? ""))
        guard let from = Dates.parse(arguments.string("from")) else {
            return "Errore: data 'from' non valida. Usa yyyy-MM-dd."
        }
        let cal = Calendar.current
        let start = from.hasTime ? from.date : cal.startOfDay(for: from.date)
        var end: Date
        if let to = Dates.parse(arguments.string("to")) {
            end = to.hasTime ? to.date : cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to.date))!
        } else {
            end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: from.date))!
        }
        if end <= start { end = cal.date(byAdding: .day, value: 1, to: start)! }

        let ek = Store.shared.ek
        let predicate = ek.predicateForEvents(withStart: start, end: end, calendars: nil)
        var events = ek.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        if let query {
            events = events.filter { ($0.title ?? "").localizedCaseInsensitiveContains(query) }
        }
        guard !events.isEmpty else { return "Nessun evento trovato." }

        let lines = events.prefix(25).map { event -> String in
            let id = IDRegistry.shared.register(event: event.eventIdentifier ?? event.calendarItemIdentifier, start: event.startDate)
            let when = event.isAllDay
                ? "\(Dates.format(event.startDate, time: false)) tutto il giorno"
                : "\(Dates.format(event.startDate))–\(Dates.format(event.endDate).suffix(5))"
            var details = [when, "calendario \(event.calendar.title)"]
            if let loc = event.location, !loc.isEmpty { details.append("luogo \(loc)") }
            return "[\(id)] «\(event.title ?? Language.t("(senza titolo)", "(untitled)"))» (\(details.joined(separator: ", ")))"
        }
        let extra = events.count > 25 ? "\n…e altri \(events.count - 25) eventi." : ""
        return lines.joined(separator: "\n") + extra
    }
}

struct CreateEventTool: Tool {
    let name = "create_event"
    let description = "Crea un nuovo evento nel calendario."
    let parameters = makeSchema("CreateEventArgs", [
        .required("title", .string, "Titolo dell'evento"),
        .required("start", .string, "Inizio, yyyy-MM-dd HH:mm (solo yyyy-MM-dd se tutto il giorno)"),
        .optional("end", .string, "Fine, yyyy-MM-dd HH:mm. Se assente dura 1 ora"),
        .optional("all_day", .bool, "true se dura tutto il giorno"),
        .optional("calendar", .string, "Nome del calendario"),
        .optional("location", .string, "Luogo"),
        .optional("notes", .string, "Note"),
    ])

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        Console.toolCall(name, "«\(arguments.string("title") ?? "?")» · \(arguments.string("start") ?? "?")")
        guard let title = arguments.string("title") else { return "Errore: titolo mancante." }
        guard let start = Dates.parse(arguments.string("start")) else {
            return "Errore: data di inizio non valida. Usa yyyy-MM-dd HH:mm."
        }
        let store = Store.shared
        guard let calendar = store.eventCalendar(named: arguments.string("calendar")) else {
            return "Errore: calendario non trovato. Usa list_calendars."
        }

        let allDay = arguments.bool("all_day") ?? !start.hasTime
        let event = EKEvent(eventStore: store.ek)
        event.title = title
        event.calendar = calendar
        event.isAllDay = allDay
        event.startDate = allDay ? Calendar.current.startOfDay(for: start.date) : start.date
        if let end = Dates.parse(arguments.string("end")), end.date > event.startDate {
            event.endDate = end.date
        } else {
            event.endDate = event.startDate.addingTimeInterval(allDay ? 86_399 : 3_600)
        }
        event.location = arguments.string("location")
        event.notes = arguments.string("notes")

        let when = allDay ? Dates.format(event.startDate, time: false) + " (tutto il giorno)"
                          : "\(Dates.format(event.startDate)) → \(Dates.format(event.endDate))"
        guard await Console.confirm("Creo evento «\(title)» \(when) in «\(calendar.title)»") else {
            return "L'utente ha annullato la creazione dell'evento."
        }
        do {
            try store.ek.save(event, span: .thisEvent, commit: true)
        } catch {
            return "Errore nel salvataggio: \(error.localizedDescription)"
        }
        let id = IDRegistry.shared.register(event: event.eventIdentifier ?? event.calendarItemIdentifier, start: event.startDate)
        Hooks.didModify()
        return "Evento creato [\(id)]: \(title), \(when), calendario \(calendar.title)."
    }
}

struct DeleteEventTool: Tool {
    let name = "delete_event"
    let description = "Elimina un evento. Serve l'ID (es. E3) ottenuto da get_events."
    let parameters = makeSchema("DeleteEventArgs", [
        .required("id", .string, "ID dell'evento, es. E3"),
    ])

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        let key = arguments.string("id") ?? ""
        Console.toolCall(name, key)
        guard let ref = IDRegistry.shared.event(key) else {
            return "Errore: ID \(key) sconosciuto. Cerca prima l'evento con get_events."
        }
        let ek = Store.shared.ek
        let predicate = ek.predicateForEvents(withStart: ref.start.addingTimeInterval(-1), end: ref.start.addingTimeInterval(1), calendars: nil)
        guard let event = ek.events(matching: predicate).first(where: {
            ($0.eventIdentifier ?? $0.calendarItemIdentifier) == ref.identifier
        }) ?? ek.event(withIdentifier: ref.identifier) else {
            return "Errore: evento non più presente."
        }
        let title = event.title ?? Language.t("(senza titolo)", "(untitled)")
        guard await Console.confirm("Elimino evento «\(title)» del \(Dates.format(event.startDate))") else {
            return "L'utente ha annullato l'eliminazione."
        }
        do {
            try ek.remove(event, span: .thisEvent, commit: true)
        } catch {
            return "Errore nell'eliminazione: \(error.localizedDescription)"
        }
        Hooks.didModify()
        return "Evento «\(title)» eliminato."
    }
}
