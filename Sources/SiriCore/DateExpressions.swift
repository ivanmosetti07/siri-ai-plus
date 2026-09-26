import Foundation

/// Date e orari scritti in italiano ("domani alle 16", "venerdì prossimo", "il 5 ottobre", "alle 9 e mezza", "di un'ora"):
/// li converte l'app, il modello piccolo sbaglia spesso i conti con le date.
extension Date {
    /// «2026-09-24» nel fuso orario di chi usa l'app. `formatted(.iso8601…)` usa l'ora UTC:
    /// tra mezzanotte e le 2 in Italia darebbe ancora la data di ieri.
    public var localDay: String {
        formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }
}

public enum DateExpressions {
    /// Ruolo suggerito dalla preposizione: "la riunione **di** domani" indica quale evento, "sposta **a** domani" dove va.
    public enum Role: Sendable, Equatable { case target, destination, bare }

    public struct Day: Sendable, Equatable {
        public var date: Date
        public var range: NSRange
        public var role: Role
    }

    public struct Time: Sendable, Equatable {
        /// Minuti dall'inizio del giorno.
        public var minutes: Int
        public var range: NSRange
        public var role: Role
    }

    /// Spostamento relativo: "di un'ora", "di 30 minuti", "di due giorni", "la settimana prossima".
    public struct Shift: Sendable, Equatable {
        public var seconds: TimeInterval
        public var days: Int
        public var range: NSRange
        /// +1 più tardi, -1 prima, 0 non detto (lo decide il verbo).
        public var direction: Int
    }

    static let weekdays = ["domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"]
    static let numberWords = ["un": 1, "uno": 1, "una": 1, "due": 2, "tre": 3, "quattro": 4, "cinque": 5, "sei": 6, "sette": 7, "otto": 8,
                              "nove": 9, "dieci": 10, "undici": 11, "dodici": 12, "quindici": 15, "venti": 20, "trenta": 30,
                              "quaranta": 40, "quarantacinque": 45, "cinquanta": 50, "novanta": 90]

    /// Minuscolo con gli apostrofi tipografici normalizzati: le posizioni restano quelle del testo.
    public static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "`", with: "'")
    }

    // MARK: - Giorni

    public static func days(in text: String, now: Date = .now) -> [Day] {
        let lower = normalized(text)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func add(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: today)! }
        var found: [Day] = []
        func append(_ date: Date, _ range: NSRange) {
            guard !found.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
            found.append(Day(date: date, range: range, role: role(before: range, in: lower)))
        }

        for (pattern, offset) in [(#"\bdopodomani\b"#, 2), (#"\bdomani\b"#, 1), (#"\bieri\b"#, -1),
                                  (#"\b(?:oggi|stamattina|stamani|stasera|stanotte|stamane)\b"#, 0)] {
            for match in ranges(pattern, in: lower) { append(add(offset), match[0]) }
        }
        // "venerdì", "venerdì prossimo", "il prossimo venerdì", "questo venerdì", "venerdì 25".
        let names = #"(luned[iì]|marted[iì]|mercoled[iì]|gioved[iì]|venerd[iì]|sabato|domenica)"#
        for match in ranges(#"\b(?:(questo|questa|il prossimo|la prossima|prossimo|prossima)\s+)?"# + names + #"(?:\s+(prossim[oa]))?(?:\s+(\d{1,2})\b)?"#, in: lower) {
            let raw = substring(lower, match[2])
            guard let weekday = weekdays.firstIndex(where: { $0 == raw || $0.replacingOccurrences(of: "ì", with: "i") == raw }) else { continue }
            let todayWeekday = calendar.component(.weekday, from: today) - 1
            var ahead = (weekday - todayWeekday + 7) % 7
            let before = substring(lower, match[1])
            // Oggi è venerdì: "venerdì prossimo" è fra una settimana, "questo venerdì" e "venerdì" sono oggi.
            if ahead == 0, match[3].location != NSNotFound || before.contains("prossim") { ahead = 7 }
            var date = add(ahead)
            var end = NSMaxRange(match[3].location != NSNotFound ? match[3] : match[2])
            // "venerdì 25": il numero vale solo se il 25 cade davvero di venerdì (entro sei mesi).
            if match[4].location != NSNotFound, let day = Int(substring(lower, match[4])), (1...31).contains(day),
               let explicit = (0..<190).lazy.compactMap({ calendar.date(byAdding: .day, value: $0, to: today) })
                .first(where: { calendar.component(.day, from: $0) == day && calendar.component(.weekday, from: $0) - 1 == weekday }) {
                date = explicit
                end = NSMaxRange(match[4])
            }
            append(date, NSRange(location: match[0].location, length: end - match[0].location))
        }
        // "il 5 ottobre", "1° novembre 2027".
        let months = Calculations.months.joined(separator: "|")
        for match in ranges(#"\b(\d{1,2}|primo)(?:°|º)?\s+("# + months + #")(?:\s+(\d{4}))?\b"#, in: lower) {
            let day = substring(lower, match[1]) == "primo" ? 1 : Int(substring(lower, match[1])) ?? 0
            guard let month = Calculations.months.firstIndex(of: substring(lower, match[2])).map({ $0 + 1 }), (1...31).contains(day) else { continue }
            let year = match[3].location == NSNotFound ? nil : Int(substring(lower, match[3]))
            if let date = resolve(day: day, month: month, year: year, today: today) { append(date, match[0]) }
        }
        // "5/10", "5/10/2026".
        for match in ranges(#"\b(\d{1,2})/(\d{1,2})(?:/(\d{4}|\d{2}))?\b"#, in: lower) {
            guard let day = Int(substring(lower, match[1])), let month = Int(substring(lower, match[2])), (1...12).contains(month), (1...31).contains(day) else { continue }
            var year = match[3].location == NSNotFound ? nil : Int(substring(lower, match[3]))
            if let y = year, y < 100 { year = 2000 + y }
            if let date = resolve(day: day, month: month, year: year, today: today) { append(date, match[0]) }
        }
        // "tra 3 giorni", "fra una settimana".
        let amounts = numberWords.keys.joined(separator: "|")
        for match in ranges(#"\b(?:tra|fra)\s+(\d+|"# + amounts + #")\s+(giorn[oi]|settiman[ae])\b"#, in: lower) {
            guard let amount = Int(substring(lower, match[1])) ?? numberWords[substring(lower, match[1])] else { continue }
            append(add(substring(lower, match[2]).hasPrefix("settiman") ? amount * 7 : amount), match[0])
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// Fra l'anno scorso, questo e il prossimo, la data più vicina a oggi (a parità, quella futura).
    static func resolve(day: Int, month: Int, year: Int?, today: Date) -> Date? {
        let calendar = Calendar.current
        func make(_ year: Int) -> Date? {
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
            return date.flatMap { calendar.component(.day, from: $0) == day ? $0 : nil }
        }
        if let year { return make(year) }
        let current = calendar.component(.year, from: today)
        func distance(_ date: Date) -> Double { abs(date.timeIntervalSince(today)) - (date >= today ? 0.5 : 0) }
        return [current, current + 1, current - 1].compactMap(make).min { distance($0) < distance($1) }
    }

    // MARK: - Orari

    public static func times(in text: String) -> [Time] {
        let lower = normalized(text)
        var found: [Time] = []
        // Cena e "stasera": "alle 8" sono le 20.
        let evening = ["stasera", "cena", "aperitivo", "di sera", "la sera"].contains(where: lower.contains)
        func append(_ minutes: Int, _ range: NSRange, prep: String) {
            guard !found.contains(where: { NSIntersectionRange($0.range, range).length > 0 }), (0..<24 * 60).contains(minutes) else { return }
            found.append(Time(minutes: minutes, range: range, role: role(of: prep)))
        }
        for match in ranges(#"\b(a|alle|per)?\s*(mezzogiorno|mezzanotte)\b"#, in: lower) {
            append(substring(lower, match[2]) == "mezzogiorno" ? 12 * 60 : 0, match[0], prep: substring(lower, match[1]))
        }
        for match in ranges(#"\b(all'|dall'|dell'|per l'|verso l')una(?:\s+e\s+(mezza|mezzo|un quarto))?(?:\s+(?:di|del|della)\s+(notte))?\b"#, in: lower) {
            let extra = match[2].location == NSNotFound ? 0 : substring(lower, match[2]).hasPrefix("mezz") ? 30 : 15
            let night = match[3].location != NSNotFound
            append((night ? 1 : 13) * 60 + extra, match[0], prep: substring(lower, match[1]))
        }
        let quarters = #"(mezza|mezzo|un quarto|quarto|tre quarti|\d{1,2}|dieci|venti|cinque|quindici|trenta|quaranta|quarantacinque|cinquanta)"#
        let pattern = #"(?:\b(alle|all'|ore|per le|verso le|dalle|delle|dall'|dell'|le|h|entro le|fino alle|prima delle|dopo le)\s*)?\b(\d{1,2})(?:[:.](\d{2}))?"#
            + #"(?:\s+e\s+"# + quarters + #")?(?:\s+meno\s+"# + quarters + #")?(?:\s+(?:del|di|della)\s+(mattina|mattino|pomeriggio|sera|notte))?\b"#
        for match in ranges(pattern, in: lower) {
            let prep = match[1].location == NSNotFound ? "" : substring(lower, match[1])
            // Un numero da solo ("slide 3") non è un orario: servono la preposizione o i minuti.
            guard !prep.isEmpty || match[3].location != NSNotFound, var hour = Int(substring(lower, match[2])), hour <= 24 else { continue }
            // "le 3 slide", "ore 2" di durata: "ore" vale solo prima del numero.
            if prep == "le", match[3].location == NSNotFound, match[4].location == NSNotFound, match[6].location == NSNotFound { continue }
            var minute = match[3].location == NSNotFound ? 0 : Int(substring(lower, match[3])) ?? 0
            if match[4].location != NSNotFound { minute += quarterMinutes(substring(lower, match[4])) }
            if match[5].location != NSNotFound { minute -= quarterMinutes(substring(lower, match[5])) }
            if minute < 0 { hour -= 1; minute += 60 }
            let part = match[6].location == NSNotFound ? "" : substring(lower, match[6])
            if match[3].location == NSNotFound || hour <= 12 {
                switch part {
                case "pomeriggio", "sera": if hour < 12 { hour += 12 }
                case "notte": if hour >= 9 && hour < 12 { hour += 12 } else if hour == 12 { hour = 0 }
                case "mattina", "mattino": break
                default:
                    // Senza indicazioni: dall'una alle sette è pomeriggio, e con la cena anche le otto e le nove.
                    if match[3].location == NSNotFound || hour < 8 {
                        if (1...7).contains(hour) || (evening && (8...11).contains(hour)) { hour += 12 }
                    }
                }
            }
            if hour == 24 { hour = 0 }
            guard (0...59).contains(minute) else { continue }
            append(hour * 60 + minute, match[0], prep: prep)
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    static func quarterMinutes(_ word: String) -> Int {
        switch word {
        case "mezza", "mezzo": 30
        case "un quarto", "quarto": 15
        case "tre quarti": 45
        default: Int(word) ?? numberWords[word] ?? 0
        }
    }

    // MARK: - Spostamenti relativi

    public static func shifts(in text: String) -> [Shift] {
        let lower = normalized(text)
        var found: [Shift] = []
        let amounts = numberWords.keys.joined(separator: "|")
        let amount = #"(un'ora|una ora|mezz'ora|mezzora|un quarto d'ora|(?:\d+|"# + amounts + #")\s*(?:ore|ora|minuti|minuto|min|h|giorni|giorno|settimane|settimana))"#
        let pattern = #"\b(?:(di|per)\s+)?"# + amount + #"(?:\s+(prima|dopo|più tardi|piu tardi|più presto|in anticipo|in ritardo|avanti|indietro))?"#
        for match in ranges(pattern, in: lower) {
            let hasPreposition = match[1].location != NSNotFound
            let hasDirection = match[3].location != NSNotFound
            // "per due ore" è una durata, non uno spostamento; "un'ora" da solo non dice niente.
            guard hasPreposition || hasDirection, substring(lower, match[1]) != "per" || hasDirection else { continue }
            let text = substring(lower, match[2])
            var seconds: TimeInterval = 0
            var days = 0
            switch text {
            case "un'ora", "una ora": seconds = 3600
            case "mezz'ora", "mezzora": seconds = 1800
            case "un quarto d'ora": seconds = 900
            default:
                guard let number = Calculations.matches(#"^(\d+|[a-z]+)\s*([a-z]+)$"#, in: text).first,
                      let value = Int(number[1]) ?? numberWords[number[1]] else { continue }
                switch number[2] {
                case "ore", "ora", "h": seconds = TimeInterval(value) * 3600
                case "minuti", "minuto", "min": seconds = TimeInterval(value) * 60
                case "giorni", "giorno": days = value
                default: days = value * 7
                }
            }
            let word = hasDirection ? substring(lower, match[3]) : ""
            let direction = ["prima", "più presto", "in anticipo", "indietro"].contains(word) ? -1 : word.isEmpty ? 0 : 1
            found.append(Shift(seconds: seconds, days: days, range: match[0], direction: direction))
        }
        for match in ranges(#"\b(?:alla\s+|la\s+)?(?:settimana prossima|prossima settimana)\b"#, in: lower) {
            found.append(Shift(seconds: 0, days: 7, range: match[0], direction: 1))
        }
        for match in ranges(#"\bil giorno (dopo|prima)\b"#, in: lower) {
            found.append(Shift(seconds: 0, days: 1, range: match[0], direction: substring(lower, match[1]) == "dopo" ? 1 : -1))
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    // MARK: - Aiuti

    /// Preposizione subito prima dell'espressione ("di", "a", "per"…), saltando l'articolo ("per il 5 ottobre").
    static func role(before range: NSRange, in lower: String) -> Role {
        let before = (lower as NSString).substring(to: range.location)
        var words = before.split(whereSeparator: { $0 == " " }).map(String.init)
        if let last = words.last, ["il", "l'", "lo", "la"].contains(last) { words.removeLast() }
        guard let last = words.last else { return .bare }
        return role(of: last)
    }

    static func role(of preposition: String) -> Role {
        switch preposition.trimmingCharacters(in: .whitespaces) {
        case "di", "del", "dell'", "della", "dello", "delle", "dei", "da", "dal", "dalla", "dall'", "dalle", "prevista", "previsto", "fissata", "fissato":
            .target
        case "a", "ad", "al", "all'", "alla", "alle", "per", "per le", "entro", "entro le", "verso", "verso le", "ore", "h", "fino a", "fino alle", "prima delle", "dopo le":
            .destination
        default: .bare
        }
    }

    static func ranges(_ pattern: String, in text: String) -> [[NSRange]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0) }
        }
    }

    static func substring(_ text: String, _ range: NSRange) -> String {
        range.location == NSNotFound ? "" : (text as NSString).substring(with: range)
    }

    /// Il testo senza gli intervalli indicati (sostituiti da uno spazio).
    static func removing(_ ranges: [NSRange], from text: String) -> String {
        let ns = NSMutableString(string: text)
        for range in ranges.filter({ $0.location != NSNotFound }).sorted(by: { $0.location > $1.location }) where NSMaxRange(range) <= ns.length {
            ns.replaceCharacters(in: range, with: " ")
        }
        return (ns as String).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// "16:30", "9:05".
    public static func clock(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }

    /// Stessa data con un nuovo orario.
    static func date(_ day: Date, at minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }

    static func minutes(of date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

// MARK: - Parole per riconoscere un elemento ("la riunione con Marco" → marco)

public enum Keywords {
    /// Parole senza significato per la ricerca: articoli, preposizioni, verbi dei comandi, nomi delle app.
    static let stopwords = Set<String>([
        "il", "lo", "la", "i", "gli", "le", "l", "un", "uno", "una", "di", "del", "dello", "della", "dei", "degli", "delle", "d",
        "a", "ad", "al", "allo", "alla", "ai", "agli", "alle", "all", "da", "dal", "dallo", "dalla", "dai", "dagli", "dalle", "dall",
        "in", "nel", "nello", "nella", "nei", "negli", "nelle", "nell", "su", "sul", "sullo", "sulla", "sui", "sugli", "sulle", "sull",
        "per", "con", "tra", "fra", "e", "ed", "o", "che", "chi", "mio", "mia", "miei", "mie", "tuo", "tua", "suo", "sua", "questo",
        "questa", "quello", "quella", "quel", "ci", "mi", "ti", "si", "ne", "è", "sono", "ho", "ha", "hai", "abbiamo", "c", "dell", "dov",
        "sposta", "spostare", "spostala", "spostalo", "spostami", "anticipa", "anticipala", "anticipalo", "posticipa", "posticipala",
        "posticipalo", "rimanda", "rimandala", "rimandalo", "rinvia", "rinviala", "rinvialo", "ritarda", "rinomina", "rinominala",
        "rinominalo", "cambia", "cambiala", "cambialo", "modifica", "modificala", "modificalo", "elimina", "eliminala", "eliminalo",
        "cancella", "cancellala", "cancellalo", "rimuovi", "togli", "metti", "mettila", "mettilo", "imposta", "porta", "fai", "fissa",
        "aggiorna", "segna", "chiamala", "chiamalo", "allunga", "accorcia", "prolunga", "puoi", "potresti", "favore", "prego",
        "promemoria", "evento", "eventi", "calendario", "scadenza", "data", "ora", "orario", "titolo", "nome", "luogo", "lista",
        "prossimo", "prossima", "questo", "stesso", "stessa", "giorno", "mattina", "pomeriggio", "sera", "prima", "dopo", "tardi",
        "presto", "avanti", "indietro", "anticipo", "ritardo", "ore", "minuti", "entro", "verso", "fino", "come", "tutto", "tutti",
        "rispondi", "inoltra", "nota", "note", "email", "mail", "posta", "aggiungi", "scrivi", "inserisci",
        "primo", "secondo", "seconda", "terzo", "terza", "quarto", "quarta", "quinto", "quinta", "ultimo", "ultima", "quello", "quella",
    ])

    /// Nomi generici di eventi: aiutano se ci sono nel titolo, ma non escludono gli altri.
    static let generic: Set<String> = ["riunione", "riunioni", "call", "meeting", "incontro", "appuntamento", "videochiamata",
                                       "chiamata", "telefonata", "impegno", "cosa"]

    /// Radice semplice: senza accenti e senza le vocali finali ("bollette" e "bolletta" → "bollett").
    public static func stem(_ word: String) -> String {
        var text = word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Dates.locale)
        guard text.count > 3 else { return text }
        while text.count > 3, let last = text.last, "aeiou".contains(last) { text.removeLast() }
        return text
    }

    /// Parole significative (in minuscolo), nell'ordine del testo.
    public static func words(_ text: String) -> [String] {
        DateExpressions.normalized(text)
            .replacingOccurrences(of: "'", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopwords.contains($0) && Int($0) == nil }
    }

    /// Punteggio di un titolo rispetto alle parole cercate: 3 per parola specifica trovata, 1 per quelle generiche.
    public static func score(_ title: String, against words: [String]) -> Int {
        let stems = Set(Self.words(title).map(stem))
        return words.reduce(0) { total, word in
            stems.contains(stem(word)) ? total + (generic.contains(word) ? 1 : 3) : total
        }
    }

    /// Le parole specifiche (non generiche) della ricerca.
    public static func specific(_ words: [String]) -> [String] { words.filter { !generic.contains($0) } }
}
