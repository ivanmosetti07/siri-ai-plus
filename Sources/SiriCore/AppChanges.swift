import Foundation

/// Comandi che cambiano qualcosa che esiste già nelle app (eventi, promemoria, note, email), letti dalla frase.
/// Tutto qui è deterministico e senza accesso ai dati: la ricerca degli elementi veri è in `Assistant+Changes`.
enum CommandText {
    /// La richiesta senza cortesie iniziali e punteggiatura finale.
    static func clean(_ prompt: String) -> String {
        var text = prompt.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        for _ in 0..<3 {
            text = text.replacingOccurrences(of: #"(?i)^(?:per favore|per piacere|puoi|potresti|riesci a|mi|ti prego di|ora|adesso|ok|ehi|siri)[,\s]+"#,
                                             with: "", options: .regularExpression)
        }
        return text
    }

    /// Primo gruppo di testo tra virgolette («…», "…", “…”) con il suo intervallo.
    static func quoted(_ text: String) -> (text: String, range: NSRange)? {
        guard let match = DateExpressions.ranges(#"«([^»]+)»|"([^"]+)"|“([^”]+)”"#, in: text).first else { return nil }
        let inner = match.dropFirst().first { $0.location != NSNotFound } ?? match[0]
        return (DateExpressions.substring(text, inner).trimmingCharacters(in: .whitespaces), match[0])
    }

    /// Toglie virgolette e punteggiatura ai bordi.
    static func unquote(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "«»\"“”'`.,;:")))
    }

    static func groups(_ pattern: String, in text: String) -> [String]? {
        guard let match = DateExpressions.ranges(pattern, in: text).first else { return nil }
        return match.map { DateExpressions.substring(text, $0) }
    }

    static let articles = #"^(?:(?:il|lo|la|i|gli|le|un|uno|una|del|dello|della|dei|degli|delle)\s+|(?:l'|un'|dell'))"#
}

// MARK: - Eventi

/// Cosa cambiare in un evento e come riconoscerlo: "sposta la riunione con Marco di domani alle 16".
public struct EventChange: Sendable, Equatable {
    /// Parole per trovare l'evento ("marco", "riunione").
    public var words: [String] = []
    public var targetDay: Date?
    public var targetTime: Int?
    public var newDay: Date?
    public var newTime: Int?
    public var newEndTime: Int?
    public var shift: TimeInterval = 0
    public var dayShift = 0
    public var endShift: TimeInterval = 0
    public var duration: TimeInterval?
    public var newTitle: String?
    public var newLocation: String?

    public init() {}

    public var changesTime: Bool {
        newDay != nil || newTime != nil || newEndTime != nil || shift != 0 || dayShift != 0 || endShift != 0 || duration != nil
    }
    public var isEmpty: Bool { !changesTime && newTitle == nil && newLocation == nil }
    /// Nessun indizio per trovare l'evento: né parole specifiche né giorno o ora.
    public var hasNoTarget: Bool { Keywords.specific(words).isEmpty && targetDay == nil && targetTime == nil }

    static let moveVerb = #"^(?:sposta|spostare|sposti|spostala|spostalo|spostiamo|anticipa|anticipala|anticipalo|anticipare|posticipa|posticipala|posticipalo|posticipare|rimanda|rimandala|rimandalo|rimandare|rinvia|rinviala|rinvialo|rinviare|ritarda|ritardala|porta|portala|portalo|metti|mettila|mettilo|fissa|fissala)\b"#
    static let earlier = #"^(?:anticip)"#
    static let later = #"^(?:posticip|rimand|rinvi|ritard)"#

    public static func parse(_ prompt: String, now: Date = .now) -> EventChange {
        var change = EventChange()
        var text = CommandText.clean(prompt)
        // Nuovo titolo: tra virgolette dopo un verbo di rinomina, o "rinomina X in Y", "cambia il titolo di X in Y", "chiamala Y".
        let renaming = DateExpressions.normalized(text).range(of: #"\b(rinomin\w*|chiamal[ao]|titolo|nome)\b"#, options: .regularExpression) != nil
        if renaming, let quote = CommandText.quoted(text) {
            change.newTitle = quote.text
            text = (text as NSString).replacingCharacters(in: quote.range, with: " ")
            text = text.replacingOccurrences(of: #"(?i)\s+(?:in|come|con|a|:)\s*$"#, with: "", options: .regularExpression)
        } else if let g = CommandText.groups(#"(?i)^(rinomin\w*\s+.+?)\s+(?:in|come)\s+(.+)$"#, in: text) {
            change.newTitle = CommandText.unquote(g[2])
            text = g[1]
        } else if let g = CommandText.groups(#"(?i)^(.*?)\b(?:cambia|modifica|metti|imposta|aggiorna)\s+(?:il\s+)?(?:titolo|nome)\s+(?:(?:dell'|dell’|della|del|dello|di|a|al|alla|all'|all’)\s*(.*?)\s+)?(?:in|con|a|:)\s+(.+)$"#, in: text) {
            change.newTitle = CommandText.unquote(g[3])
            text = g[1] + " " + g[2]
        } else if let g = CommandText.groups(#"(?i)^(.*?)\s*(?:,\s*|\s+e\s+)?chiamal[ao]\s+(.+)$"#, in: text) {
            change.newTitle = CommandText.unquote(g[2])
            text = g[1]
        }
        // Nuovo luogo: "cambia il luogo della cena in Da Mario", "sposta la riunione in sala B".
        if let g = CommandText.groups(#"(?i)^(.*?)\b(?:cambia|modifica|metti|imposta|aggiorna)\s+(?:il\s+)?(?:luogo|posto|indirizzo)\s+(?:(?:dell'|dell’|della|del|dello|di)\s*(.*?)\s+)?(?:in|a|con|:)\s+(.+)$"#, in: text) {
            change.newLocation = CommandText.unquote(g[3])
            text = g[1] + " " + g[2]
        } else if let g = CommandText.groups(#"(?i)^(.*?)\s+(?:in|nella)\s+(sala\s+[\w\-]+)(.*)$"#, in: text) {
            let room = g[2]
            change.newLocation = room.prefix(1).uppercased() + room.dropFirst()
            text = g[1] + " " + g[3]
        }

        let lower = DateExpressions.normalized(text)
        let isMove = lower.range(of: moveVerb, options: .regularExpression) != nil
        let verbDirection = lower.range(of: earlier, options: .regularExpression) != nil ? -1 : 1
        var used: [NSRange] = []

        // Durata: "che duri due ore", "per un'ora e mezza".
        let amounts = DateExpressions.numberWords.keys.joined(separator: "|")
        if let match = DateExpressions.ranges(#"\b(?:che\s+)?(?:dur[ia]\w*|per)\s+(un'ora e mezza|un'ora|una ora|mezz'ora|(\d+|"# + amounts + #")\s*(ore|ora|minuti))\b"#, in: lower).first {
            let value = DateExpressions.substring(lower, match[1])
            switch value {
            case "un'ora e mezza": change.duration = 5400
            case "un'ora", "una ora": change.duration = 3600
            case "mezz'ora": change.duration = 1800
            default:
                let number = Double(DateExpressions.substring(lower, match[2])) ?? Double(DateExpressions.numberWords[DateExpressions.substring(lower, match[2])] ?? 0)
                change.duration = number * (DateExpressions.substring(lower, match[3]).hasPrefix("minut") ? 60 : 3600)
            }
            if change.duration == 0 { change.duration = nil } else { used.append(match[0]) }
        }

        // Spostamenti relativi: "anticipa di un'ora", "rimanda alla settimana prossima", "allunga di mezz'ora".
        let lengthen = lower.range(of: #"^(?:allung|prolung)"#, options: .regularExpression) != nil
        let shorten = lower.hasPrefix("accorci")
        for shift in DateExpressions.shifts(in: lower) {
            let direction = shift.direction != 0 ? shift.direction : (shorten ? -1 : verbDirection)
            if lengthen || shorten {
                change.endShift += Double(direction) * (shift.seconds + Double(shift.days) * 86_400)
            } else if isMove {
                change.shift += Double(direction) * shift.seconds
                change.dayShift += direction * shift.days
            } else {
                continue
            }
            used.append(shift.range)
        }

        // Orari: "dalle 15 alle 17" è la nuova fascia, "fino alle 18" la nuova fine.
        var times = DateExpressions.times(in: lower).filter { time in !used.contains { NSIntersectionRange($0, time.range).length > 0 } }
        func phrase(_ time: DateExpressions.Time) -> String { DateExpressions.substring(lower, time.range) }
        if let index = times.indices.dropLast().first(where: { phrase(times[$0]).hasPrefix("dall") && phrase(times[$0 + 1]).hasPrefix("all") }),
           isMove || lower.contains("orario") {
            change.newTime = times[index].minutes
            change.newEndTime = times[index + 1].minutes
            used += [times[index].range, times[index + 1].range]
            times.removeSubrange(index...(index + 1))
        }
        if let end = times.firstIndex(where: { phrase($0).hasPrefix("fino") }) {
            change.newEndTime = times[end].minutes
            used.append(times[end].range)
            times.remove(at: end)
        }
        if isMove, change.newTime == nil {
            if times.count >= 2 {
                change.targetTime = times.first?.minutes
                change.newTime = times.last?.minutes
            } else if let time = times.first {
                if time.role == .target { change.targetTime = time.minutes } else { change.newTime = time.minutes }
            }
        } else {
            change.targetTime = change.targetTime ?? times.first?.minutes
        }
        used += times.map(\.range)

        // Giorni: "di domani" indica quale evento, "a venerdì" (o "venerdì" da solo, spostando) dove va.
        let days = DateExpressions.days(in: lower, now: now)
        if isMove {
            let destinations = days.filter { $0.role == .destination }
            let targets = days.filter { $0.role == .target }
            let bare = days.filter { $0.role == .bare }
            change.newDay = destinations.last?.date ?? (destinations.isEmpty ? bare.last?.date : nil)
            change.targetDay = targets.first?.date ?? (destinations.isEmpty ? nil : bare.first?.date)
        } else {
            change.targetDay = days.first?.date
        }
        used += days.map(\.range)

        change.words = Keywords.words(DateExpressions.removing(used, from: lower))
        return change
    }

    /// Nuovi orari dell'evento dopo il cambiamento (la durata resta, se non è indicata).
    public func apply(start: Date, end: Date, isAllDay: Bool) -> (start: Date, end: Date, isAllDay: Bool) {
        let calendar = Calendar.current
        var allDay = isAllDay
        var length = max(end.timeIntervalSince(start), 900)
        var newStart = start
        if dayShift != 0 { newStart = calendar.date(byAdding: .day, value: dayShift, to: newStart) ?? newStart }
        if shift != 0 { newStart = newStart.addingTimeInterval(shift) }
        if let newDay { newStart = DateExpressions.date(newDay, at: DateExpressions.minutes(of: newStart)) }
        if let newTime {
            // Un evento di tutto il giorno con un orario diventa un evento di un'ora.
            if allDay { allDay = false; length = 3600 }
            newStart = DateExpressions.date(newStart, at: newTime)
        }
        var newEnd = newStart.addingTimeInterval(length)
        if let duration { newEnd = newStart.addingTimeInterval(duration) }
        if let newEndTime {
            allDay = false
            newEnd = DateExpressions.date(newStart, at: newEndTime)
            if newEnd <= newStart { newEnd = newStart.addingTimeInterval(duration ?? 3600) }
        }
        if endShift != 0 { newEnd = newEnd.addingTimeInterval(endShift) }
        if newEnd <= newStart { newEnd = newStart.addingTimeInterval(allDay ? 86_399 : 900) }
        return (newStart, newEnd, allDay)
    }
}

/// Trova l'evento descritto fra quelli del periodo.
public enum EventMatcher {
    /// Gli eventi più probabili, dal più vicino. Un evento che si ripete conta una volta sola (la prossima).
    public static func best(_ events: [EventItem], change: EventChange, now: Date = .now) -> [EventItem] {
        var candidates = events
        if let day = change.targetDay {
            candidates = candidates.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
        }
        if let time = change.targetTime {
            candidates = candidates.filter { !$0.isAllDay && DateExpressions.minutes(of: $0.start) == time }
        }
        let specific = Keywords.specific(change.words)
        let scored = candidates.map { ($0, Keywords.score($0.title, against: change.words)) }
        let top = scored.map(\.1).max() ?? 0
        if !specific.isEmpty {
            // Serve almeno una parola specifica nel titolo (o nel luogo).
            let matching = scored.filter { item, score in
                score >= 3 || (item.location.map { Keywords.score($0, against: specific) >= 3 } ?? false)
            }
            guard !matching.isEmpty else { return [] }
            let best = matching.map(\.1).max() ?? 0
            candidates = matching.filter { $0.1 == best }.map(\.0)
        } else if top > 0 {
            candidates = scored.filter { $0.1 == top }.map(\.0)
        }
        // Stesso evento ripetuto: la prossima occorrenza (o l'ultima passata se non ce ne sono).
        let titles = Set(candidates.map { Keywords.stem($0.title) })
        if titles.count == 1, candidates.count > 1 {
            let upcoming = candidates.filter { $0.end > now }.sorted { $0.start < $1.start }
            return [upcoming.first ?? candidates.sorted { $0.start > $1.start }[0]]
        }
        return candidates.sorted { $0.start < $1.start }
    }
}

// MARK: - Promemoria

/// Cosa cambiare in un promemoria: scadenza, testo, lista, priorità.
public struct ReminderChange: Sendable, Equatable {
    public var words: [String] = []
    /// Promemoria in scadenza quel giorno ("il promemoria di domani").
    public var targetDay: Date?
    public var newDay: Date?
    public var newTime: Int?
    public var dayShift = 0
    public var shift: TimeInterval = 0
    public var removeDue = false
    public var newTitle: String?
    public var highPriority: Bool?
    public var list: String?

    public init() {}

    public var isEmpty: Bool {
        newDay == nil && newTime == nil && dayShift == 0 && shift == 0 && !removeDue && newTitle == nil && highPriority == nil && list == nil
    }

    public static func parse(_ prompt: String, now: Date = .now) -> ReminderChange {
        var change = ReminderChange()
        var text = CommandText.clean(prompt)
        if let quote = CommandText.quoted(text), DateExpressions.normalized(text).range(of: #"\b(rinomin\w*|cambia|modifica|testo|titolo|nome|chiamal[ao])\b"#, options: .regularExpression) != nil {
            change.newTitle = quote.text
            text = (text as NSString).replacingCharacters(in: quote.range, with: " ")
            text = text.replacingOccurrences(of: #"(?i)\s+(?:in|come|con|a|:)\s*$"#, with: "", options: .regularExpression)
        } else if let g = CommandText.groups(#"(?i)^((?:rinomin\w*|cambia|modifica)\s+(?:il\s+)?(?:testo\s+del\s+|titolo\s+del\s+|nome\s+del\s+)?promemoria\s+.+?)\s+(?:in|come)\s+(.+)$"#, in: text) {
            change.newTitle = CommandText.unquote(g[2])
            text = g[1]
        }
        if let g = CommandText.groups(#"(?i)^(.*?)\s+(?:nella|in|alla|sulla)\s+lista\s+(.+)$"#, in: text) {
            change.list = CommandText.unquote(g[2])
            text = g[1]
        }
        let lower = DateExpressions.normalized(text)
        var used: [NSRange] = []
        if let match = DateExpressions.ranges(#"\b(?:togli|toglie|rimuovi|elimina|cancella|senza)\s+(?:la\s+|le\s+)?(?:scadenz[ae]|data|date)\b|\bnessuna scadenza\b"#, in: lower).first {
            change.removeDue = true
            used.append(match[0])
        }
        if let match = DateExpressions.ranges(#"\b(?:togli|rimuovi|senza)\s+(?:la\s+)?(?:priorit[aà]|bandierina|contrassegno)\b|\bpriorit[aà]\s+(?:normale|bassa|nessuna)\b|\bnon\s+(?:è\s+)?(?:più\s+)?(?:urgente|importante)\b"#, in: lower).first {
            change.highPriority = false
            used.append(match[0])
        } else if let match = DateExpressions.ranges(#"\b(?:importante|urgente|priorit[aà] alta|alta priorit[aà]|con priorit[aà]|contrassegn\w*|bandierina)\b"#, in: lower).first {
            change.highPriority = true
            used.append(match[0])
        }
        let later = lower.range(of: EventChange.earlier, options: .regularExpression) == nil
        for shift in DateExpressions.shifts(in: lower) {
            let direction = shift.direction != 0 ? shift.direction : (later ? 1 : -1)
            change.dayShift += direction * shift.days
            change.shift += Double(direction) * shift.seconds
            used.append(shift.range)
        }
        let times = DateExpressions.times(in: lower)
        change.newTime = times.last { $0.role != .target }?.minutes
        used += times.map(\.range)
        let days = DateExpressions.days(in: lower, now: now)
        change.newDay = days.last { $0.role != .target }?.date
        change.targetDay = days.first { $0.role == .target }?.date
        used += days.map(\.range)
        change.words = Keywords.words(DateExpressions.removing(used, from: lower))
            .filter { !["importante", "urgente", "priorità", "priorita", "alta", "bassa", "scadenze"].contains($0) }
        return change
    }

    /// Nuova scadenza.
    public func apply(due: Date?, hasTime: Bool, now: Date = .now) -> (due: Date?, hasTime: Bool) {
        if removeDue && newDay == nil && newTime == nil { return (nil, false) }
        let calendar = Calendar.current
        var date = due ?? calendar.startOfDay(for: now)
        var timed = hasTime
        if dayShift != 0 { date = calendar.date(byAdding: .day, value: dayShift, to: date) ?? date }
        if shift != 0 { date = date.addingTimeInterval(shift); timed = true }
        if let newDay { date = timed ? DateExpressions.date(newDay, at: DateExpressions.minutes(of: date)) : calendar.startOfDay(for: newDay) }
        if let newTime { date = DateExpressions.date(date, at: newTime); timed = true }
        return (date, timed)
    }
}

public enum ReminderMatcher {
    public static func best(_ reminders: [ReminderItem], words: [String], day: Date? = nil) -> [ReminderItem] {
        var candidates = reminders
        if let day { candidates = candidates.filter { $0.due.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false } }
        let specific = Keywords.specific(words)
        guard !specific.isEmpty else { return day == nil ? [] : candidates }
        let scored = candidates.map { ($0, Keywords.score($0.title, against: specific)) }.filter { $0.1 >= 3 }
        let best = scored.map(\.1).max() ?? 0
        return scored.filter { $0.1 == best }.map(\.0)
    }
}

// MARK: - Note

/// "Aggiungi il latte alla nota della spesa": quale nota e cosa aggiungere.
public struct NoteAddition: Sendable, Equatable {
    public var note: String
    public var lines: [String]

    static let verbs = #"(?:aggiungi|aggiungere|aggiungici|metti|mettici|inserisci|scrivi|scrivici|annota|appunta|segna)"#
    static let noteRef = #"(?:alla|nella|sulla|in|dentro la|alle|nelle|sulle)\s+(?:mia\s+|tua\s+|mie\s+)?(?:nota|note)\b"#
    static let nameLink = #"(?:della|del|dello|dei|degli|delle|dell'|di|sulla|sul|sui|sulle|per|per la|per il|chiamata|intitolata|che si chiama|dal titolo)?"#

    public static func parse(_ prompt: String) -> NoteAddition? {
        let text = CommandText.clean(prompt).replacingOccurrences(of: "’", with: "'")
        // "Aggiungi alla nota spesa: latte, uova" / "scrivi nella nota lavoro che domani c'è sciopero".
        if let g = CommandText.groups("(?i)^" + verbs + #"\s+"# + noteRef + #"\s*"# + nameLink + #"\s*[«"“]?(.+?)[»"”]?\s*(?::|,|\s+che\s+|\s+il testo\s+|\s+la frase\s+)\s*(.+)$"#, in: text) {
            return make(note: g[1], content: g[2])
        }
        // "Aggiungi il latte alla nota della spesa".
        if let g = CommandText.groups("(?i)^" + verbs + #"\s+(.+?)\s+"# + noteRef + #"\s*"# + nameLink + #"\s*[«"“]?(.+?)[»"”]?$"#, in: text) {
            return make(note: g[2], content: g[1])
        }
        // "Aggiungi alla nota spesa il latte": nome di una parola.
        if let g = CommandText.groups("(?i)^" + verbs + #"\s+"# + noteRef + #"\s*"# + nameLink + #"\s*(\S+)\s+(.+)$"#, in: text) {
            return make(note: g[1], content: g[2])
        }
        return nil
    }

    static func make(note: String, content: String) -> NoteAddition? {
        let name = CommandText.unquote(note)
        let body = CommandText.unquote(content).replacingOccurrences(of: #"(?i)^che\s+"#, with: "", options: .regularExpression)
        guard !name.isEmpty, !body.isEmpty, !["una", "un", "nuova", "nuovo"].contains(name.lowercased()) else { return nil }
        return NoteAddition(note: name, lines: items(body))
    }

    /// "il latte, le uova e il pane" → ["latte", "uova", "pane"]; una frase resta intera.
    static func items(_ text: String) -> [String] {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .flatMap { $0.components(separatedBy: " e ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count >= 1, parts.allSatisfy({ $0.split(separator: " ").count <= 4 }) else { return [text] }
        return parts.map { $0.replacingOccurrences(of: CommandText.articles, with: "", options: [.regularExpression, .caseInsensitive]) }
    }
}

// MARK: - Email

/// "Rispondi a Mario che va bene per giovedì", "inoltra a Giulia l'ultima email di Mario".
public struct MailRequest: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case reply, forward }
    public var kind: Kind
    /// Mittente dell'email da trovare.
    public var person: String?
    /// Argomento o oggetto dell'email da trovare.
    public var subject: String?
    /// A chi inoltrare.
    public var recipient: String?
    /// Cosa rispondere, con le parole dell'utente.
    public var message: String?
    public var replyAll = false

    static let mail = #"(?:e-?mail|mail|messaggio di posta|posta)"#
    static let answer = #"(?:\s+(?:dicendo(?:gli|le)?|scrivendo(?:gli|le)?|per dir(?:gli|le)|rispondendo(?:gli|le)?|che)\b\s*|\s*[:,]\s*)"#

    public static func parse(_ prompt: String) -> MailRequest? {
        let text = CommandText.clean(prompt).replacingOccurrences(of: "’", with: "'")
        let lower = text.lowercased()
        if lower.range(of: #"^(?:rispondi|rispondigli|rispondile|replica|rispondere)\b"#, options: .regularExpression) != nil {
            var request = MailRequest(kind: .reply)
            request.replyAll = lower.range(of: #"^\w+\s+a\s+tutti\b"#, options: .regularExpression) != nil
            let body = text.replacingOccurrences(of: #"(?i)^\w+\s+(?:a\s+tutti\s+)?"#, with: "", options: .regularExpression)
            // "all'email di Mario che…", "alla mail sulla fattura: …", "a Mario che…", "all'ultima email: …".
            if let g = CommandText.groups("(?i)^(?:all'|alla|al|a)\\s*(?:ultima\\s+)?" + mail + #"\s+(di|da|del|della|dello|su|sulla|sul|riguardo|che parla d\w*)\s+(.+?)"# + answer + "(.*)$", in: body)
                ?? CommandText.groups("(?i)^(?:all'|alla|al|a)\\s*(?:ultima\\s+)?" + mail + #"\s+(di|da|del|della|dello|su|sulla|sul|riguardo)\s+(.+)()$"#, in: body) {
                if ["di", "da", "del", "della", "dello"].contains(g[1].lowercased()) { request.person = CommandText.unquote(g[2]) } else { request.subject = CommandText.unquote(g[2]) }
                request.message = g[3].isEmpty ? nil : CommandText.unquote(g[3])
            } else if let g = CommandText.groups("(?i)^(?:all'|alla|al|a)\\s*(?:ultima\\s+)?" + mail + #"\s*[:,]?\s*(.*)$"#, in: body) {
                request.message = g[1].isEmpty ? nil : CommandText.unquote(g[1])
            } else if let g = CommandText.groups(#"(?i)^(?:a|ad)\s+(.+?)"# + answer + "(.+)$", in: body) {
                request.person = CommandText.unquote(g[1])
                request.message = CommandText.unquote(g[2])
            } else if let g = CommandText.groups(#"(?i)^(?:a|ad)\s+(\S+)\s*(.*)$"#, in: body) {
                request.person = CommandText.unquote(g[1])
                request.message = g[2].isEmpty ? nil : CommandText.unquote(g[2])
            } else if !body.isEmpty, lower.range(of: #"^rispond(?:igli|ile)\b"#, options: .regularExpression) != nil {
                // "Rispondigli che va bene": la persona è quella dell'email appena letta.
                request.message = CommandText.unquote(body.replacingOccurrences(of: #"(?i)^(?:che|dicendo(?:gli|le)? che)\s+"#, with: "", options: .regularExpression))
            } else {
                return nil
            }
            request.person = request.person.map { $0.replacingOccurrences(of: #"(?i)\s+(?:via|per|con)\s+(?:e-?mail|mail|posta)$"#, with: "", options: .regularExpression) }
            request.message = request.message.map { $0.replacingOccurrences(of: #"(?i)^che\s+"#, with: "", options: .regularExpression) }.flatMap { $0.isEmpty ? nil : $0 }
            return request
        }
        if lower.range(of: #"^(?:inoltra|inoltrare|inoltrala|inoltralo|gira|girala|giralo|manda|invia)\b"#, options: .regularExpression) != nil {
            let verbAndArticle = #"(?i)^\w+\s+"#
            let item = #"(?:l'|la|le|il|quella|questa)\s*(?:ultima\s+|ultime\s+)?"# + mail
            // "inoltra a Giulia l'ultima email di Mario"
            if let g = CommandText.groups(verbAndArticle + #"(?:a|ad)\s+(.+?)\s+"# + item + #"(?:\s+(di|da|del|della|dello|su|sulla|sul|riguardo|con)\s+(.+))?$"#, in: text) {
                return forward(recipient: g[1], link: g[2], source: g[3])
            }
            // "inoltra l'ultima email di Mario a Giulia"
            if let g = CommandText.groups(verbAndArticle + item + #"(?:\s+(di|da|del|della|dello|su|sulla|sul|riguardo)\s+(.+?))?\s+(?:a|ad)\s+(.+)$"#, in: text) {
                return forward(recipient: g[3], link: g[1], source: g[2])
            }
            // "inoltrala a Giulia" (l'email appena letta).
            if let g = CommandText.groups(#"(?i)^(?:inoltrala|inoltralo|girala|giralo)\s+(?:a|ad)\s+(.+)$"#, in: text) {
                return forward(recipient: g[1], link: "", source: "")
            }
        }
        return nil
    }

    static func forward(recipient: String, link: String, source: String) -> MailRequest? {
        var request = MailRequest(kind: .forward)
        request.recipient = CommandText.unquote(recipient)
        let value = CommandText.unquote(source)
        if !value.isEmpty {
            if ["di", "da", "del", "della", "dello"].contains(link.lowercased()) { request.person = value } else { request.subject = value }
        }
        return request.recipient?.isEmpty == false ? request : nil
    }

    /// Il testo non contiene un comando per la posta ma per chat o messaggi ("rispondi a Marco su WhatsApp").
    static func meansMessages(_ lower: String) -> Bool {
        ["whatsapp", "imessage", "sms", "messaggio", "messaggi", "telegram"].contains(where: lower.contains)
            && !["email", "e-mail", " mail", " posta"].contains(where: lower.contains)
    }
}

// MARK: - Scelta fra più elementi trovati

public enum ChoiceMatcher {
    /// "il primo", "la seconda", "l'ultimo" riferiti a un elenco appena mostrato.
    public static func ordinal(_ text: String, count: Int) -> Int? {
        let lower = DateExpressions.normalized(text)
        guard count > 0 else { return nil }
        if lower.range(of: #"\b(?:l'|quell'|lo |la |il )\s*ultim[oa]\b"#, options: .regularExpression) != nil { return count - 1 }
        let ordinals = [("prim", 0), ("second", 1), ("terz", 2), ("quart", 3), ("quint", 4), ("sest", 5)]
        for (stem, index) in ordinals where lower.range(of: #"\b(?:il|la|lo|quell[oa])\s+"# + stem + #"[oa]\b"#, options: .regularExpression) != nil {
            return index < count ? index : nil
        }
        return nil
    }

    /// L'opzione indicata dalla risposta ("la seconda", "quella delle 10", "venerdì", "quella con Marco"), o nil se non è una scelta.
    public static func pick(_ answer: String, options: [(title: String, date: Date?)], now: Date = .now) -> Int? {
        let lower = DateExpressions.normalized(CommandText.clean(answer))
        guard !options.isEmpty, lower.split(separator: " ").count <= 8 else { return nil }
        // Un comando nuovo non è una risposta alla domanda.
        if lower.range(of: #"^(?:sposta|cancella|elimina|crea|scrivi|aggiungi|rinomina|cambia|modifica|manda|invia|rispondi|inoltra|cerca|apri|mostra|dimmi|cosa|come|perch)"#, options: .regularExpression) != nil { return nil }
        if lower.range(of: #"\bultim[oa]\b"#, options: .regularExpression) != nil { return options.count - 1 }
        let ordinals = [("prim", 0), ("second", 1), ("terz", 2), ("quart", 3), ("quint", 4), ("sest", 5)]
        for (stem, index) in ordinals where lower.range(of: #"^(?:(?:il|la|lo|quell[oa])\s+)?"# + stem + #"[oa]\b"#, options: .regularExpression) != nil {
            return index < options.count ? index : nil
        }
        if let g = CommandText.groups(#"^(?:la |il |numero |n\.? ?|opzione )?(\d{1,2})$"#, in: lower), let number = Int(g[1]), (1...options.count).contains(number) {
            return number - 1
        }
        var candidates = Array(options.indices)
        var narrowed = false
        if let time = DateExpressions.times(in: lower).first {
            candidates = candidates.filter { options[$0].date.map { DateExpressions.minutes(of: $0) == time.minutes } ?? false }
            narrowed = true
        }
        if let day = DateExpressions.days(in: lower, now: now).first {
            candidates = candidates.filter { options[$0].date.map { Calendar.current.isDate($0, inSameDayAs: day.date) } ?? false }
            narrowed = true
        }
        let words = Keywords.words(lower).filter { !["quella", "quello", "quelle", "quelli"].contains($0) }
        if !words.isEmpty {
            let scored = candidates.map { ($0, Keywords.score(options[$0].title, against: words)) }
            let best = scored.map(\.1).max() ?? 0
            if best > 0 {
                candidates = scored.filter { $0.1 == best }.map(\.0)
                narrowed = true
            }
        }
        return narrowed && candidates.count == 1 ? candidates[0] : nil
    }
}
