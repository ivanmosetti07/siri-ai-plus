import Foundation

/// Comandi che cambiano qualcosa che esiste già nelle app (eventi, promemoria, note, email), letti dalla frase.
/// Tutto qui è deterministico e senza accesso ai dati: la ricerca degli elementi veri è in `Assistant+Changes`.
/// Con una richiesta in inglese valgono anche le frasi inglesi («move tomorrow's meeting with Mark to 4 pm»); l'italiano non cambia.
enum CommandText {
    /// La richiesta senza cortesie iniziali e punteggiatura finale.
    static func clean(_ prompt: String) -> String {
        var text = prompt.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        for _ in 0..<3 {
            text = text.replacingOccurrences(of: #"(?i)^(?:per favore|per piacere|puoi|potresti|riesci a|mi|ti prego di|ora|adesso|ok|ehi|siri)[,\s]+"#,
                                             with: "", options: .regularExpression)
        }
        // In inglese: «please», «can you», «I need to»… all'inizio, «please» in fondo («thanks» può essere la risposta da mandare).
        if Language.isEnglish {
            for _ in 0..<3 {
                text = text.replacingOccurrences(of: englishCourtesy, with: "", options: .regularExpression)
            }
            text = text.replacingOccurrences(of: #"(?i)[,\s]+please$"#, with: "", options: .regularExpression)
        }
        return text
    }

    static let englishCourtesy = #"(?i)^(?:please|pls|kindly|can you|could you|would you|will you|can u|hey siri|hey|hi|okay|ok|so|now|siri|just|i need you to|i want you to|i['’]d like you to|i would like you to|i need to|i want to|i['’]d like to|i would like to|go ahead and|let['’]s|let us)[,\s]+"#

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

    // MARK: Inglese

    /// Articoli e possessivi inglesi all'inizio di una voce («the milk», «some eggs», «my invoice»).
    static let englishArticles = #"^(?:the|a|an|some|my|our|your)\s+"#

    static func withoutEnglishArticle(_ text: String) -> String {
        text.replacingOccurrences(of: englishArticles, with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// Parole per trovare un elemento («la riunione con Marco» → marco). In inglese senza il verbo del comando, articoli,
    /// preposizioni, date e ordinali («move tomorrow's meeting with Mark» → meeting, mark).
    static func keywords(_ text: String) -> [String] {
        guard Language.isEnglish else { return Keywords.words(text) }
        let body = text.replacingOccurrences(of: englishLeadingVerb, with: " ", options: .regularExpression)
        return Keywords.words(body).filter { !englishStopwords.contains($0) }
    }

    /// Le parole specifiche della ricerca: in inglese anche «appointment» o «session» sono generiche, come «riunione».
    static func specific(_ words: [String]) -> [String] {
        let specific = Keywords.specific(words)
        return Language.isEnglish ? specific.filter { !englishGeneric.contains($0) } : specific
    }

    /// Punteggio di un titolo rispetto alle parole cercate; in inglese il plurale vale come il singolare («bills» e «Pay the bill»).
    static func score(_ title: String, against words: [String]) -> Int {
        guard Language.isEnglish else { return Keywords.score(title, against: words) }
        let stems = Set(Keywords.words(title).map(englishStem))
        return words.reduce(0) { total, word in
            guard stems.contains(englishStem(word)) else { return total }
            return total + (Keywords.generic.contains(word) || englishGeneric.contains(word) ? 1 : 3)
        }
    }

    static func englishStem(_ word: String) -> String {
        var text = word.lowercased()
        if text.count > 4, text.hasSuffix("ies") {
            text = String(text.dropLast(3)) + "y"
        } else if text.count > 4, text.range(of: #"(?:ss|x|ch|sh)es$"#, options: .regularExpression) != nil {
            text.removeLast(2)
        } else if text.count > 3, text.hasSuffix("s"), !["ss", "us", "is"].contains(where: text.hasSuffix) {
            text.removeLast()
        }
        return Keywords.stem(text)
    }

    /// Il verbo del comando all'inizio («mark the gym reminder…»): va tolto qui e non fra le parole vuote, perché Mark è anche un nome.
    static let englishLeadingVerb = #"(?i)^\s*(?:move|moving|reschedule|postpone|push|delay|bring|shift|put|set|make|pull|extend|lengthen|prolong|shorten|cut|rename|retitle|change|edit|modify|update|cancel|delete|remove|erase|drop|clear|mark|flag|complete|check|tick|cross|finish|add|write|reply|forward|send|take|get)\b"#

    /// Parole inglesi senza significato per la ricerca: articoli, preposizioni, verbi dei comandi, nomi delle app, date e ordinali.
    static let englishStopwords: Set<String> = [
        "the", "an", "of", "to", "in", "on", "at", "by", "for", "from", "with", "into", "onto", "about", "and", "or", "that", "this",
        "these", "those", "it", "its", "my", "your", "our", "his", "her", "him", "them", "their", "me", "we", "you", "is", "are", "be",
        "can", "could", "would", "please", "ll", "re", "ve", "don", "one", "ones", "which", "all", "same", "up", "off", "as", "so",
        "just", "now", "then", "also", "there", "here", "out", "over", "again", "instead",
        "move", "moving", "reschedule", "postpone", "push", "delay", "bring", "shift", "put", "set", "make", "pull", "extend",
        "lengthen", "prolong", "shorten", "rename", "retitle", "change", "edit", "modify", "update", "cancel", "delete", "remove",
        "erase", "clear", "complete", "finish", "add", "write", "reply", "forward", "send",
        "event", "events", "calendar", "reminder", "reminders", "due", "date", "dates", "deadline", "time", "title", "name",
        "location", "place", "venue", "list", "note", "notes", "email", "emails", "mail", "inbox",
        "earlier", "later", "sooner", "forward", "back", "before", "after", "ahead", "next", "day", "days", "week", "weeks", "morning",
        "afternoon", "evening", "night", "tonight", "today", "tomorrow", "yesterday", "monday", "tuesday", "wednesday", "thursday",
        "friday", "saturday", "sunday", "hour", "hours", "minute", "minutes", "min", "mins", "half", "quarter", "am", "pm", "until",
        "till", "noon", "midnight", "clock", "longer", "shorter", "long",
        "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "fifteen", "twenty", "thirty", "forty", "fifty",
        "first", "second", "third", "fourth", "fifth", "sixth", "last", "st", "nd", "rd", "th",
        "important", "urgent", "priority", "high", "low", "normal", "done", "completed", "finished", "not", "no",
    ]

    /// Nomi inglesi generici di eventi: aiutano se ci sono nel titolo, ma non escludono gli altri (come «riunione»).
    static let englishGeneric: Set<String> = ["meeting", "meetings", "call", "calls", "appointment", "appointments", "video", "phone",
                                              "session", "sessions", "catch", "thing", "things", "commitment"]

    /// Nomi di eventi che seguono una data o un orario usati come aggettivo («the 10 am meeting», «the Friday call»).
    static let englishEventNoun = #"(?:meetings?|events?|appointments?|calls?|dinners?|lunch(?:es)?|breakfasts?|class(?:es)?|lessons?|sessions?|reminders?|stand-?ups?|interviews?|webinars?|reviews?|syncs?|video\s?calls?|catch-?ups?)\b"#

    static let englishPrepositions: Set<String> = ["to", "until", "till", "by", "for", "at", "of", "from", "on", "due"]

    /// Preposizione inglese di una data o di un orario: all'inizio dell'espressione («to 4 pm») o subito prima («to Friday»).
    static func englishPreposition(_ range: NSRange, in lower: String) -> String {
        let ns = lower as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return "" }
        let first = ns.substring(with: range).split(separator: " ").first.map(String.init) ?? ""
        if englishPrepositions.contains(first) { return first }
        var previous = ns.substring(to: range.location).split(separator: " ").map(String.init)
        if previous.last == "the" { previous.removeLast() }
        return previous.last.flatMap { englishPrepositions.contains($0) ? $0 : nil } ?? ""
    }

    /// Ruolo di una data o di un orario in una frase inglese: «tomorrow's meeting», «the 10 am call», «of Friday» indicano
    /// quale elemento; «to Friday», «until 6», «at 4 pm» dove va; «on Friday» da solo lo decide il resto della frase.
    static func englishRole(_ range: NSRange, in lower: String) -> DateExpressions.Role {
        let ns = lower as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return .bare }
        let after = ns.substring(from: NSMaxRange(range))
        if ns.substring(with: range).hasSuffix("'s") || after.hasPrefix("'s") { return .target }
        if after.range(of: #"^\s+"# + englishEventNoun, options: .regularExpression) != nil { return .target }
        // «the meeting at 10 to 4 pm», «the dinner on Friday to Monday»: la destinazione viene dopo.
        let destinationFollows = after.range(of: #"^\s*(?:to|until|till)\b"#, options: .regularExpression) != nil
        switch englishPreposition(range, in: lower) {
        case "of", "from", "due": return .target
        case "at": return destinationFollows ? .target : .destination
        case "to", "until", "till", "by", "for": return .destination
        default: return destinationFollows ? .target : .bare
        }
    }

    /// «until 6», «ending at 6»: l'orario è la nuova fine.
    static func englishEnds(_ range: NSRange, in lower: String) -> Bool {
        if ["until", "till"].contains(englishPreposition(range, in: lower)) { return true }
        let before = (lower as NSString).substring(to: range.location)
        return before.range(of: #"\b(?:ends?|ending|finish(?:es|ing)?)\s+(?:at\s+)?$"#, options: .regularExpression) != nil
    }
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
    public var hasNoTarget: Bool { CommandText.specific(words).isEmpty && targetDay == nil && targetTime == nil }

    static let moveVerb = #"^(?:sposta|spostare|sposti|spostala|spostalo|spostiamo|anticipa|anticipala|anticipalo|anticipare|posticipa|posticipala|posticipalo|posticipare|rimanda|rimandala|rimandalo|rimandare|rinvia|rinviala|rinvialo|rinviare|ritarda|ritardala|porta|portala|portalo|metti|mettila|mettilo|fissa|fissala)\b"#
    static let earlier = #"^(?:anticip)"#
    static let later = #"^(?:posticip|rimand|rinvi|ritard)"#
    /// In inglese: «move», «reschedule», «postpone», «push back», «bring forward», «make it 4 pm», «change the time of … to …».
    static let englishMoveVerb = #"^(?:move|moving|reschedule|postpone|push|delay|bring|shift|put|pull|advance|set|make)\b|^(?:change|update|edit|modify)\s+(?:the\s+)?(?:time|start(?:\s+time)?|date|day)\b"#
    static let englishEarlier = #"^(?:bring|pull|advance)\b|^move\s+up\b|\b(?:earlier|sooner|forward|ahead)\b|\bup\s+by\b"#
    static let englishLonger = #"^(?:extend|lengthen|prolong)\b|\blonger\b"#
    static let englishShorter = #"^(?:shorten|cut)\b|\bshorter\b"#

    public static func parse(_ prompt: String, now: Date = .now) -> EventChange {
        var change = EventChange()
        var text = CommandText.clean(prompt)
        let english = Language.isEnglish
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
        if english { englishTitleAndPlace(&change, text: &text) }

        let lower = DateExpressions.normalized(text)
        let isMove = lower.range(of: moveVerb, options: .regularExpression) != nil
            || (english && lower.range(of: englishMoveVerb, options: .regularExpression) != nil)
        let verbDirection = (lower.range(of: earlier, options: .regularExpression) != nil
            || (english && lower.range(of: englishEarlier, options: .regularExpression) != nil)) ? -1 : 1
        var used: [NSRange] = []
        // «Allunga», «accorcia» (in inglese «extend», «shorten», «make it longer»): cambia la fine.
        let lengthen = lower.range(of: #"^(?:allung|prolung)"#, options: .regularExpression) != nil
            || (english && lower.range(of: englishLonger, options: .regularExpression) != nil)
        let shorten = lower.hasPrefix("accorci") || (english && lower.range(of: englishShorter, options: .regularExpression) != nil)

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
        // In inglese: «for two hours», «that lasts 90 minutes», «an hour and a half long» (con «extend» cambia la fine,
        // con «delay», «postpone», «push» è uno spostamento: «delay the standup for 15 minutes»).
        if english, change.duration == nil, let found = englishDuration(in: lower) {
            if lengthen || shorten {
                change.endShift += (shorten ? -1 : 1) * found.seconds
            } else if DateExpressions.substring(lower, found.range).hasPrefix("for "),
                      lower.range(of: #"^(?:postpone|delay|push|put\s+off|bring)\b"#, options: .regularExpression) != nil {
                change.shift += Double(verbDirection) * found.seconds
            } else {
                change.duration = found.seconds
            }
            used.append(found.range)
        }

        // Spostamenti relativi: "anticipa di un'ora", "rimanda alla settimana prossima", "allunga di mezz'ora".
        for shift in DateExpressions.shifts(in: lower) {
            // In inglese una durata già letta («for two hours») non è anche uno spostamento.
            if english, used.contains(where: { NSIntersectionRange($0, shift.range).length > 0 }) { continue }
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
        // In inglese: «from 3 to 5 pm» è la nuova fascia.
        if english, change.newTime == nil,
           let index = times.indices.dropLast().first(where: {
               CommandText.englishPreposition(times[$0].range, in: lower) == "from"
                   && ["to", "till", "until"].contains(CommandText.englishPreposition(times[$0 + 1].range, in: lower))
           }),
           isMove || lower.contains("time") {
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
        // «until 6», «ending at 6».
        if english, change.newEndTime == nil, let end = times.firstIndex(where: { CommandText.englishEnds($0.range, in: lower) }) {
            change.newEndTime = times[end].minutes
            used.append(times[end].range)
            times.remove(at: end)
        }
        if isMove, change.newTime == nil {
            if times.count >= 2 {
                change.targetTime = times.first?.minutes
                change.newTime = times.last?.minutes
            } else if let time = times.first {
                // In inglese il ruolo lo dice la frase: «the 10 am meeting» è quale evento, «to 4 pm» dove va.
                let role = english ? CommandText.englishRole(time.range, in: lower) : time.role
                if role == .target { change.targetTime = time.minutes } else { change.newTime = time.minutes }
            }
        } else {
            change.targetTime = change.targetTime ?? times.first?.minutes
        }
        used += times.map(\.range)

        // Giorni: "di domani" indica quale evento, "a venerdì" (o "venerdì" da solo, spostando) dove va.
        // In inglese «tomorrow's meeting» indica quale evento, «to Friday» dove va.
        let days = DateExpressions.days(in: lower, now: now)
        if isMove {
            func role(_ day: DateExpressions.Day) -> DateExpressions.Role { english ? CommandText.englishRole(day.range, in: lower) : day.role }
            let destinations = days.filter { role($0) == .destination }
            let targets = days.filter { role($0) == .target }
            let bare = days.filter { role($0) == .bare }
            change.newDay = destinations.last?.date ?? (destinations.isEmpty ? bare.last?.date : nil)
            change.targetDay = targets.first?.date ?? (destinations.isEmpty ? nil : bare.first?.date)
        } else {
            change.targetDay = days.first?.date
        }
        used += days.map(\.range)

        change.words = CommandText.keywords(DateExpressions.removing(used, from: lower))
        return change
    }

    /// In inglese: nuovo titolo («rename … to "…"», «change the title of … to …», «call it …») e nuovo luogo
    /// («change the location of … to …», «move the budget meeting to room B»).
    static func englishTitleAndPlace(_ change: inout EventChange, text: inout String) {
        if change.newTitle == nil {
            let renaming = DateExpressions.normalized(text).range(of: #"\b(?:renam\w*|retitl\w*|title|name|call\s+it)\b"#, options: .regularExpression) != nil
            if renaming, let quote = CommandText.quoted(text) {
                change.newTitle = quote.text
                text = (text as NSString).replacingCharacters(in: quote.range, with: " ")
                text = text.replacingOccurrences(of: #"(?i)\s+(?:to|as|into|:)\s*$"#, with: "", options: .regularExpression)
            } else if let g = CommandText.groups(#"(?i)^((?:rename|retitle)\s+.+?)\s+(?:to|as|into)\s+(.+)$"#, in: text) {
                change.newTitle = CommandText.unquote(g[2])
                text = g[1]
            } else if let g = CommandText.groups(#"(?i)^(.*?)\b(?:change|edit|modify|set|update)\s+(?:the\s+)?(?:title|name)\s+(?:(?:of|for)\s+(?:the\s+)?(.*?)\s+)?(?:to|as|:)\s+(.+)$"#, in: text) {
                change.newTitle = CommandText.unquote(g[3])
                text = g[1] + " " + g[2]
            } else if let g = CommandText.groups(#"(?i)^(.*?)\s*(?:,\s*|\s+and\s+)?(?:call|name)\s+it\s+(.+)$"#, in: text) {
                change.newTitle = CommandText.unquote(g[2])
                text = g[1]
            }
        }
        guard change.newLocation == nil else { return }
        if let g = CommandText.groups(#"(?i)^(.*?)\b(?:change|edit|modify|set|update)\s+(?:the\s+)?(?:location|place|venue|address|room)\s+(?:(?:of|for)\s+(?:the\s+)?(.*?)\s+)?(?:to|as|:)\s+(.+)$"#, in: text) {
            change.newLocation = CommandText.unquote(g[3])
            text = g[1] + " " + g[2]
        } else if let g = CommandText.groups(#"(?i)^(.*?)\s+(?:to|in|into)\s+(?:the\s+)?((?:conference\s+|meeting\s+)?room\s+[\w\-]+)(.*)$"#, in: text) {
            let room = g[2]
            change.newLocation = room.prefix(1).uppercased() + room.dropFirst()
            text = g[1] + " " + g[3]
        }
    }

    /// Durata scritta in inglese: «for two hours», «that lasts 90 minutes», «an hour and a half long».
    static func englishDuration(in lower: String) -> (seconds: TimeInterval, range: NSRange)? {
        let numbers = englishNumbers.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let amount = #"(an hour and a half|one and a half hours?|half an hour|a half hour|an hour|one hour|(?:\d+|"# + numbers + #")\s*(?:hours?|hrs?|h|minutes?|mins?))"#
        let patterns = [#"\b(?:(?:that|so\s+(?:that\s+)?it|to)\s+)?(?:lasts?|runs?)\s+(?:for\s+)?"# + amount + #"\b"#,
                        #"\bfor\s+"# + amount + #"\b"#,
                        #"\b"# + amount + #"\s+long\b"#]
        for pattern in patterns {
            for match in DateExpressions.ranges(pattern, in: lower) {
                if let seconds = englishSeconds(DateExpressions.substring(lower, match[1])) { return (seconds, match[0]) }
            }
        }
        return nil
    }

    static func englishSeconds(_ amount: String) -> TimeInterval? {
        switch amount {
        case "an hour and a half", "one and a half hour", "one and a half hours": return 5400
        case "half an hour", "a half hour": return 1800
        case "an hour", "one hour": return 3600
        default:
            guard let g = CommandText.groups(#"^(\d+|[a-z\-]+)\s*([a-z]+)$"#, in: amount),
                  let value = Double(g[1]) ?? englishNumbers[g[1]].map(Double.init), value > 0 else { return nil }
            return value * (g[2].hasPrefix("h") ? 3600 : 60)
        }
    }

    static let englishNumbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
                                 "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "forty-five": 45, "fifty": 50,
                                 "sixty": 60, "ninety": 90]

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
        let specific = CommandText.specific(change.words)
        let scored = candidates.map { ($0, CommandText.score($0.title, against: change.words)) }
        let top = scored.map(\.1).max() ?? 0
        if !specific.isEmpty {
            // Serve almeno una parola specifica nel titolo (o nel luogo).
            let matching = scored.filter { item, score in
                score >= 3 || (item.location.map { CommandText.score($0, against: specific) >= 3 } ?? false)
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

    /// In inglese: «remove the due date», «no deadline».
    static let englishNoDue = #"\b(?:remove|delete|clear|drop|take\s+off|get\s+rid\s+of|unset)\s+(?:the\s+|its\s+|any\s+)?(?:due\s+dates?|deadlines?|dates?)\b|\b(?:no\s+|without\s+(?:a\s+|the\s+|any\s+)?)(?:due\s+date|deadline|date)\b"#
    /// «Remove the flag», «not important», «low priority».
    static let englishPriorityOff = #"\b(?:remove|clear|drop|take\s+off|unset)\s+(?:the\s+|its\s+)?(?:priority|flag)\b|\bunflag\w*\b|\b(?:normal|low|no)\s+priority\b|\bpriority\s+(?:normal|low|none)\b|\bnot\s+(?:important|urgent)\b|\bunimportant\b"#
    /// «Mark as important», «flag it», «high priority».
    static let englishPriorityOn = #"\b(?:important|urgent|high[\s-]priority|top\s+priority|with\s+priority|priority|flag(?:ged)?)\b"#

    public static func parse(_ prompt: String, now: Date = .now) -> ReminderChange {
        var change = ReminderChange()
        var text = CommandText.clean(prompt)
        let english = Language.isEnglish
        if let quote = CommandText.quoted(text), DateExpressions.normalized(text).range(of: #"\b(rinomin\w*|cambia|modifica|testo|titolo|nome|chiamal[ao])\b"#, options: .regularExpression) != nil {
            change.newTitle = quote.text
            text = (text as NSString).replacingCharacters(in: quote.range, with: " ")
            text = text.replacingOccurrences(of: #"(?i)\s+(?:in|come|con|a|:)\s*$"#, with: "", options: .regularExpression)
        } else if let g = CommandText.groups(#"(?i)^((?:rinomin\w*|cambia|modifica)\s+(?:il\s+)?(?:testo\s+del\s+|titolo\s+del\s+|nome\s+del\s+)?promemoria\s+.+?)\s+(?:in|come)\s+(.+)$"#, in: text) {
            change.newTitle = CommandText.unquote(g[2])
            text = g[1]
        }
        // In inglese: «rename the bills reminder to "…"», «change the title of the gym reminder to …».
        if english, change.newTitle == nil {
            if let quote = CommandText.quoted(text),
               DateExpressions.normalized(text).range(of: #"\b(?:renam\w*|retitl\w*|change|edit|modify|text|title|name|call\s+it)\b"#, options: .regularExpression) != nil {
                change.newTitle = quote.text
                text = (text as NSString).replacingCharacters(in: quote.range, with: " ")
                text = text.replacingOccurrences(of: #"(?i)\s+(?:to|as|into|:)\s*$"#, with: "", options: .regularExpression)
            } else if let g = CommandText.groups(#"(?i)^((?:rename|retitle)\s+.+?)\s+(?:to|as)\s+(.+)$"#, in: text)
                        ?? CommandText.groups(#"(?i)^((?:change|edit|modify)\s+(?:the\s+)?(?:text|title|name)\s+of\s+.+?)\s+to\s+(.+)$"#, in: text) {
                change.newTitle = CommandText.unquote(g[2])
                text = g[1]
            }
        }
        if let g = CommandText.groups(#"(?i)^(.*?)\s+(?:nella|in|alla|sulla)\s+lista\s+(.+)$"#, in: text) {
            change.list = CommandText.unquote(g[2])
            text = g[1]
        }
        // «to the Home list», «into list Work».
        if english, change.list == nil,
           let g = CommandText.groups(#"(?i)^(.*?)\s+(?:to|in|into|onto|on)\s+(?:the\s+|my\s+)?(?:list\s+(.+)|(.+?)\s+list)$"#, in: text) {
            let name = CommandText.unquote(g[2].isEmpty ? g[3] : g[2])
            if !name.isEmpty, !["the", "my", "a", "this", "that"].contains(name.lowercased()) {
                change.list = name
                text = g[1]
            }
        }
        let lower = DateExpressions.normalized(text)
        var used: [NSRange] = []
        if let match = DateExpressions.ranges(#"\b(?:togli|toglie|rimuovi|elimina|cancella|senza)\s+(?:la\s+|le\s+)?(?:scadenz[ae]|data|date)\b|\bnessuna scadenza\b"#, in: lower).first {
            change.removeDue = true
            used.append(match[0])
        }
        if english, !change.removeDue, let match = DateExpressions.ranges(englishNoDue, in: lower).first {
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
        if english, change.highPriority == nil {
            if let match = DateExpressions.ranges(englishPriorityOff, in: lower).first {
                change.highPriority = false
                used.append(match[0])
            } else if let match = DateExpressions.ranges(englishPriorityOn, in: lower).first {
                change.highPriority = true
                used.append(match[0])
            }
        }
        let later = lower.range(of: EventChange.earlier, options: .regularExpression) == nil
            && !(english && lower.range(of: EventChange.englishEarlier, options: .regularExpression) != nil)
        for shift in DateExpressions.shifts(in: lower) {
            let direction = shift.direction != 0 ? shift.direction : (later ? 1 : -1)
            change.dayShift += direction * shift.days
            change.shift += Double(direction) * shift.seconds
            used.append(shift.range)
        }
        // In inglese il ruolo lo dice la frase: «the reminder due tomorrow» è quale promemoria, «to Friday» la nuova scadenza.
        func role(_ range: NSRange, _ original: DateExpressions.Role) -> DateExpressions.Role {
            english ? CommandText.englishRole(range, in: lower) : original
        }
        let times = DateExpressions.times(in: lower)
        change.newTime = times.last { role($0.range, $0.role) != .target }?.minutes
        used += times.map(\.range)
        let days = DateExpressions.days(in: lower, now: now)
        change.newDay = days.last { role($0.range, $0.role) != .target }?.date
        change.targetDay = days.first { role($0.range, $0.role) == .target }?.date
        used += days.map(\.range)
        change.words = CommandText.keywords(DateExpressions.removing(used, from: lower))
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
        let specific = CommandText.specific(words)
        guard !specific.isEmpty else { return day == nil ? [] : candidates }
        let scored = candidates.map { ($0, CommandText.score($0.title, against: specific)) }.filter { $0.1 >= 3 }
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

    /// In inglese: «add milk to the shopping note», «write in the work note that…», «add to the note called Shopping: …».
    static let englishVerbs = #"(?:add|append|put|insert|write|type|jot(?:\s+down)?|note(?:\s+down)?)"#
    static let englishPlace = #"(?:to|in|into|on|onto|inside)\s+(?:the\s+|my\s+|our\s+)?"#
    static let englishNamed = #"(?:called\s+|named\s+|titled\s+|about\s+)?"#
    static let englishSeparator = #"\s*(?::|,|\s+that\s+|\s+saying\s+|\s+the\s+(?:text|line|words?)\s+)\s*"#

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
        return Language.isEnglish ? parseEnglish(text) : nil
    }

    static func parseEnglish(_ text: String) -> NoteAddition? {
        let start = "(?i)^" + englishVerbs + #"\s+"#
        // «Add to the shopping note: eggs, bread and coffee», «write in the work note that there's a strike tomorrow».
        if let g = CommandText.groups(start + englishPlace + #"(.+?)\s+notes?"# + englishSeparator + "(.+)$", in: text),
           let addition = make(note: g[1], content: g[2]) { return addition }
        // «Write in the note called Work: call Mario».
        if let g = CommandText.groups(start + englishPlace + #"notes?\s+"# + englishNamed + #"[«"“]?(.+?)[»"”]?"# + englishSeparator + "(.+)$", in: text),
           let addition = make(note: g[1], content: g[2]) { return addition }
        // «Add milk to the shopping note» (il luogo è l'ultimo «to/in» prima di «note»).
        if let g = CommandText.groups(start + #"(.+)\s+"# + englishPlace + #"(.+?)\s+notes?$"#, in: text),
           let addition = make(note: g[2], content: g[1]) { return addition }
        // «Add milk to the note called Shopping», «add milk to the note "Shopping"».
        if let g = CommandText.groups(start + #"(.+)\s+"# + englishPlace + #"notes?\s+"# + englishNamed + #"[«"“]?(.+?)[»"”]?$"#, in: text),
           let addition = make(note: g[2], content: g[1]) { return addition }
        // «Add to the note Shopping milk»: nome di una parola.
        if let g = CommandText.groups(start + englishPlace + #"notes?\s+(\S+)\s+(.+)$"#, in: text),
           let addition = make(note: g[1], content: g[2]) { return addition }
        // «Add to my shopping note milk, eggs & bread».
        if let g = CommandText.groups(start + englishPlace + #"(.+?)\s+notes?\s+(.+)$"#, in: text),
           let addition = make(note: g[1], content: g[2]) { return addition }
        return nil
    }

    static func make(note: String, content: String) -> NoteAddition? {
        let name = CommandText.unquote(note)
        var body = CommandText.unquote(content).replacingOccurrences(of: #"(?i)^che\s+"#, with: "", options: .regularExpression)
        guard !name.isEmpty, !body.isEmpty, !["una", "un", "nuova", "nuovo"].contains(name.lowercased()) else { return nil }
        if Language.isEnglish {
            // «my note», «this note», «a new note»: non è il nome di una nota.
            guard !["a", "an", "new", "the", "my", "this", "that", "your", "our", "some", "another", "open", "current", "selected", "same", "it"]
                .contains(name.lowercased()) else { return nil }
            body = body.replacingOccurrences(of: #"(?i)^that\s+"#, with: "", options: .regularExpression)
            guard !body.isEmpty else { return nil }
        }
        return NoteAddition(note: name, lines: items(body))
    }

    /// "il latte, le uova e il pane" → ["latte", "uova", "pane"]; una frase resta intera. In inglese «milk, eggs and bread».
    static func items(_ text: String) -> [String] {
        if Language.isEnglish { return englishItems(text) }
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .flatMap { $0.components(separatedBy: " e ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count >= 1, parts.allSatisfy({ $0.split(separator: " ").count <= 4 }) else { return [text] }
        return parts.map { $0.replacingOccurrences(of: CommandText.articles, with: "", options: [.regularExpression, .caseInsensitive]) }
    }

    /// «the milk, some eggs and bread» → ["milk", "eggs", "bread"]; una frase resta intera.
    static func englishItems(_ text: String) -> [String] {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .flatMap { $0.components(separatedBy: " and ").flatMap { $0.components(separatedBy: " & ") } }
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"(?i)^(?:and|&)\s+"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
        guard parts.count >= 1, parts.allSatisfy({ $0.split(separator: " ").count <= 4 }) else { return [text] }
        return parts.map(CommandText.withoutEnglishArticle)
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
        return Language.isEnglish ? parseEnglish(text) : nil
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

    // MARK: Inglese

    static let englishMail = #"(?:e-?mails?|mails?)"#
    /// Ciò che segue è il testo della risposta: «saying…», «telling him…», «that…», «: …».
    static let englishAnswer = #"(?:\s+(?:saying|telling\s+(?:him|her|them)|to\s+say|to\s+tell\s+(?:him|her|them)|and\s+say|and\s+tell\s+(?:him|her|them)|replying)\b\s*(?:that\s+)?|\s+that\s+|\s*[:,]\s*)"#
    static let englishItem = #"(?:the\s+|this\s+|that\s+|my\s+)?(?:(?:last|latest|most\s+recent|previous|recent)\s+)?"# + englishMail
    static let englishLink = #"(from|by|of|about|on|regarding|concerning|re)"#

    /// «Reply to Mario that Thursday works for me», «reply to the email about the invoice saying…», «forward Mario's last email to Julia».
    static func parseEnglish(_ text: String) -> MailRequest? {
        let lower = text.lowercased()
        if lower.range(of: #"^(?:reply|respond|answer|write\s+back)\b"#, options: .regularExpression) != nil {
            var request = MailRequest(kind: .reply)
            request.replyAll = lower.range(of: #"^(?:reply|respond|answer|write\s+back)(?:\s+to)?\s+(?:all|everyone|everybody)\b"#, options: .regularExpression) != nil
            let body = text.replacingOccurrences(of: #"(?i)^(?:reply|respond|answer|write\s+back)(?:\s+(?:to\s+)?(?:all|everyone|everybody)\b)?\s*"#, with: "", options: .regularExpression)
            // «to the email from Mario saying…», «to the email about the invoice: …».
            if let g = CommandText.groups("(?i)^(?:to\\s+)?" + englishItem + #"\s+"# + englishLink + #"\s+(.+?)"# + englishAnswer + "(.*)$", in: body)
                ?? CommandText.groups("(?i)^(?:to\\s+)?" + englishItem + #"\s+"# + englishLink + #"\s+(.+)()$"#, in: body) {
                let value = CommandText.withoutEnglishArticle(CommandText.unquote(g[2]))
                if ["from", "by", "of"].contains(g[1].lowercased()) { request.person = value } else { request.subject = value }
                request.message = g[3].isEmpty ? nil : CommandText.unquote(g[3])
            } else if let g = CommandText.groups(#"(?i)^(?:to\s+)?(.+?)['’]s\s+(?:(?:last|latest|most\s+recent|previous)\s+)?"# + englishMail + "(?:" + englishAnswer + "(.*))?$", in: body) {
                // «to Mario's email saying…».
                request.person = CommandText.unquote(g[1])
                request.message = g[2].isEmpty ? nil : CommandText.unquote(g[2])
            } else if let g = CommandText.groups("(?i)^(?:to\\s+)?" + englishItem + "(?:" + englishAnswer + #"|\s*$)(.*)$"#, in: body) {
                // «to the email: …», «to the last email saying…».
                request.message = g[1].isEmpty ? nil : CommandText.unquote(g[1])
            } else if let g = CommandText.groups(#"(?i)^(?:to\s+)?(?:the|this|that|my)\s+(?:(?:last|latest|most\s+recent|previous)\s+)?([\w'’-]+(?:\s+[\w'’-]+)?)\s+"# + englishMail + "(?:" + englishAnswer + "(.*))?$", in: body) {
                // «to the invoice email saying…», «to the Amazon email: …».
                request.describe(g[1])
                request.message = g[2].isEmpty ? nil : CommandText.unquote(g[2])
            } else if let g = CommandText.groups(#"(?i)^(?:to\s+)?(?:him|her|them)\b(?:"# + englishAnswer + #"|\s*)(.*)$"#, in: body) {
                // «Reply to him that it's fine»: la persona è quella dell'email appena letta.
                request.message = g[1].isEmpty ? nil : CommandText.unquote(g[1])
            } else if let g = CommandText.groups(#"(?i)^to\s+(.+?)"# + englishAnswer + "(.+)$", in: body) {
                request.person = CommandText.unquote(g[1])
                request.message = CommandText.unquote(g[2])
            } else if let g = CommandText.groups(#"(?i)^to\s+(\S+)\s*(.*)$"#, in: body) {
                request.person = CommandText.unquote(g[1])
                request.message = g[2].isEmpty ? nil : CommandText.unquote(g[2])
            } else if lower.hasPrefix("answer"), let g = CommandText.groups(#"(?i)^(.+?)"# + englishAnswer + "(.+)$", in: body) {
                // «Answer Mario that…».
                request.person = CommandText.unquote(g[1])
                request.message = CommandText.unquote(g[2])
            } else if request.replyAll {
                // «Reply all saying thanks», «reply to everyone»: all'email appena letta.
                let text = body.replacingOccurrences(of: #"(?i)^(?:(?:saying|replying)\s+)?(?:that\s+)?[:,]?\s*"#, with: "", options: .regularExpression)
                request.message = text.isEmpty ? nil : CommandText.unquote(text)
            } else {
                return nil
            }
            request.person = request.person.map { $0.replacingOccurrences(of: #"(?i)\s+(?:by|via|over|through|on)\s+(?:e-?mail|mail)$"#, with: "", options: .regularExpression) }
            request.splitTopic()
            request.message = request.message.map { $0.replacingOccurrences(of: #"(?i)^that\s+"#, with: "", options: .regularExpression) }.flatMap { $0.isEmpty ? nil : $0 }
            return request
        }
        if lower.range(of: #"^(?:forward|fwd|send|pass\s+on|pass)\b"#, options: .regularExpression) != nil {
            let verb = #"(?i)^(?:forward|fwd|send|pass\s+on|pass)\s+"#
            let item = #"(?:the|this|that|my)\s+(?:(?:last|latest|most\s+recent|previous)\s+)?"# + englishMail
            let link = #"(from|by|of|about|on|regarding|concerning|with)"#
            // «Forward to Julia the last email from Mario», «forward Julia the email about the invoice».
            if let g = CommandText.groups(verb + #"(?:to\s+)?(.+?)\s+"# + item + #"(?:\s+"# + link + #"\s+(.+))?$"#, in: text) {
                return englishForward(recipient: g[1], link: g[2], source: g[3])
            }
            // «Forward the last email from Mario to Julia».
            if let g = CommandText.groups(verb + item + #"(?:\s+"# + link + #"\s+(.+?))?\s+to\s+(.+)$"#, in: text) {
                return englishForward(recipient: g[3], link: g[1], source: g[2])
            }
            // «Forward Mario's last email to Julia».
            if let g = CommandText.groups(verb + #"(.+?)['’]s\s+(?:(?:last|latest|most\s+recent|previous)\s+)?"# + englishMail + #"(?:\s+(about|on|regarding)\s+(.+?))?\s+to\s+(.+)$"#, in: text),
               var request = englishForward(recipient: g[4], link: g[2], source: g[3]) {
                request.person = CommandText.unquote(g[1])
                return request
            }
            // «Forward it to Julia» (l'email appena letta).
            if let g = CommandText.groups(#"(?i)^(?:forward|fwd)\s+(?:it|this|that|this\s+one|that\s+one)\s+(?:on\s+)?to\s+(.+)$"#, in: text) {
                return englishForward(recipient: g[1], link: "", source: "")
            }
            // «Forward the invoice email to Julia», «forward the Amazon email to Julia».
            if let g = CommandText.groups(verb + #"(?:the|this|that|my)\s+(?:(?:last|latest|most\s+recent|previous)\s+)?([\w'’-]+(?:\s+[\w'’-]+)?)\s+"# + englishMail + #"\s+to\s+(.+)$"#, in: text),
               var request = englishForward(recipient: g[2], link: "", source: "") {
                request.describe(g[1])
                return request
            }
        }
        return nil
    }

    /// «the invoice email» parla dell'oggetto, «the Amazon email» di chi l'ha mandata (il nome ha la maiuscola).
    mutating func describe(_ descriptor: String) {
        let value = CommandText.unquote(descriptor)
        guard !value.isEmpty else { return }
        if value.first?.isUppercase == true { person = value } else { subject = value }
    }

    /// «from Mario about the invoice»: la persona e l'argomento separati.
    mutating func splitTopic() {
        guard let value = person, let g = CommandText.groups(#"(?i)^(.+?)\s+(?:about|regarding|concerning|re)\s+(.+)$"#, in: value) else { return }
        person = g[1]
        if subject == nil { subject = CommandText.withoutEnglishArticle(g[2]) }
    }

    static func englishForward(recipient: String, link: String, source: String) -> MailRequest? {
        var request = MailRequest(kind: .forward)
        request.recipient = CommandText.unquote(recipient.replacingOccurrences(of: #"(?i)\s+(?:by|via|over)\s+(?:e-?mail|mail)$"#, with: "", options: .regularExpression))
        let value = CommandText.withoutEnglishArticle(CommandText.unquote(source))
        if !value.isEmpty {
            if ["from", "by", "of"].contains(link.lowercased()) { request.person = value } else { request.subject = value }
        }
        request.splitTopic()
        return request.recipient?.isEmpty == false ? request : nil
    }

    /// Il testo non contiene un comando per la posta ma per chat o messaggi ("rispondi a Marco su WhatsApp").
    static func meansMessages(_ lower: String) -> Bool {
        let italian = ["whatsapp", "imessage", "sms", "messaggio", "messaggi", "telegram"].contains(where: lower.contains)
            && !["email", "e-mail", " mail", " posta"].contains(where: lower.contains)
        guard !italian, Language.isEnglish else { return italian }
        // «Reply to Mark on iMessage…», «…by text».
        return ["whatsapp", "imessage", "sms", "telegram", "message", " text ", " texts "].contains(where: lower.contains)
            && !["email", "e-mail", " mail", " inbox"].contains(where: lower.contains)
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
        return Language.isEnglish ? englishOrdinal(lower, count: count) : nil
    }

    static let englishOrdinals = ["first": 0, "1st": 0, "second": 1, "2nd": 1, "third": 2, "3rd": 2, "fourth": 3, "4th": 3,
                                  "fifth": 4, "5th": 4, "sixth": 5, "6th": 5]

    /// «the first one», «the 2nd», «the last one», «number 2»; non «the last email from Mario» (quella si cerca).
    static func englishOrdinal(_ lower: String, count: Int) -> Int? {
        let searched = #"(?!\s+(?:e-?mails?|mails?|messages?|events?|meetings?|reminders?|notes?)\s+(?:from|by|of|about|regarding|with)\b)"#
        let notTime = #"(?!\s+(?:week|month|year|time|night|weekend|day|thing|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b)"#
        if lower.range(of: #"\bthe\s+(?:very\s+)?last(?:\s+one)?\b"# + searched + notTime, options: .regularExpression) != nil { return count - 1 }
        if let g = CommandText.groups(#"\bthe\s+(first|second|third|fourth|fifth|sixth|1st|2nd|3rd|4th|5th|6th)\b"# + searched + notTime, in: lower),
           let index = englishOrdinals[g[1]] {
            return index < count ? index : nil
        }
        if let g = CommandText.groups(#"(?:\bnumber\s+|\bno\.\s*|#\s*)(\d{1,2})\b"#, in: lower), let number = Int(g[1]) {
            return (1...count).contains(number) ? number - 1 : nil
        }
        return nil
    }

    /// Una risposta inglese che è un comando o una domanda nuova, non una scelta.
    static let englishCommand = #"^(?:move|reschedule|postpone|push|delay|cancel|delete|remove|create|make|write|add|rename|change|edit|modify|send|reply|respond|forward|search|find|look|open|show|tell|remind|schedule|set|what|how|why|who|where|when|can|could|is|are|do|does)\b"#

    /// L'opzione indicata dalla risposta ("la seconda", "quella delle 10", "venerdì", "quella con Marco"), o nil se non è una scelta.
    public static func pick(_ answer: String, options: [(title: String, date: Date?)], now: Date = .now) -> Int? {
        let lower = DateExpressions.normalized(CommandText.clean(answer))
        guard !options.isEmpty, lower.split(separator: " ").count <= 8 else { return nil }
        // Un comando nuovo non è una risposta alla domanda.
        if lower.range(of: #"^(?:sposta|cancella|elimina|crea|scrivi|aggiungi|rinomina|cambia|modifica|manda|invia|rispondi|inoltra|cerca|apri|mostra|dimmi|cosa|come|perch)"#, options: .regularExpression) != nil { return nil }
        // In inglese: «the second one», «number 2», «the last one».
        if Language.isEnglish {
            if lower.range(of: englishCommand, options: .regularExpression) != nil { return nil }
            if lower.range(of: #"\blast\b(?!\s+(?:week|month|year|time|night|weekend|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b)"#,
                           options: .regularExpression) != nil { return options.count - 1 }
            if let g = CommandText.groups(#"^(?:(?:the|that)\s+)?(first|second|third|fourth|fifth|sixth|1st|2nd|3rd|4th|5th|6th)\b"#, in: lower),
               let index = englishOrdinals[g[1]] {
                return index < options.count ? index : nil
            }
            if let g = CommandText.groups(#"^(?:the\s+|number\s+|no\.?\s*|#\s*|option\s+|choice\s+|item\s+)?(\d{1,2})(?:st|nd|rd|th)?(?:\s+one)?$"#, in: lower),
               let number = Int(g[1]) {
                return (1...options.count).contains(number) ? number - 1 : nil
            }
        }
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
        let words = CommandText.keywords(lower).filter { !["quella", "quello", "quelle", "quelli"].contains($0) }
        if !words.isEmpty {
            let scored = candidates.map { ($0, CommandText.score(options[$0].title, against: words)) }
            let best = scored.map(\.1).max() ?? 0
            if best > 0 {
                candidates = scored.filter { $0.1 == best }.map(\.0)
                narrowed = true
            }
        }
        return narrowed && candidates.count == 1 ? candidates[0] : nil
    }
}
