import Foundation
import FoundationModels

/// Quando lavora un agente.
public struct AgentSchedule: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case manuale, continuo, orario, giornaliero, settimanale
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .manuale: Language.t("Quando lo avvii", "When you start it")
            case .continuo: Language.t("Di continuo", "Continuously")
            case .orario: Language.t("Ogni ora", "Every hour")
            case .giornaliero: Language.t("Ogni giorno", "Every day")
            case .settimanale: Language.t("Ogni settimana", "Every week")
            }
        }
    }

    public var kind: Kind
    public var hour = 8
    public var minute = 0
    /// 1 = domenica … 7 = sabato (come `Calendar`).
    public var weekday = 2
    /// Minuti fra un'esecuzione e l'altra per «Di continuo» (nil = 30).
    public var intervalMinutes: Int?

    public var interval: Int { max(5, intervalMinutes ?? 30) }

    public init(kind: Kind, hour: Int = 8, minute: Int = 0, weekday: Int = 2) {
        self.kind = kind; self.hour = hour; self.minute = minute; self.weekday = weekday
    }

    /// Prossima esecuzione dopo `date` (nil se manuale).
    public func next(after date: Date) -> Date? {
        let calendar = Calendar.current
        switch kind {
        case .manuale: return nil
        case .continuo: return date.addingTimeInterval(Double(interval) * 60)
        case .orario: return date.addingTimeInterval(60 * 60)
        case .giornaliero:
            return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime)
        case .settimanale:
            return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, weekday: weekday), matchingPolicy: .nextTime)
        }
    }

    public var label: String {
        if Language.isEnglish { return englishLabel }
        let time = String(format: "%02d:%02d", hour, minute)
        switch kind {
        case .continuo: return interval % 60 == 0 ? (interval == 60 ? "Ogni ora" : "Ogni \(interval / 60) ore") : "Ogni \(interval) minuti"
        case .giornaliero: return "Ogni giorno alle \(time)"
        case .settimanale:
            let name = Dates.locale.calendar.weekdaySymbols[max(0, min(6, weekday - 1))]
            return "Ogni \(name) alle \(time)"
        default: return kind.label
        }
    }

    /// «Every day at 6:00 PM», «Every Monday at 9:30 AM», «Every 2 hours»: l'orario nel formato della lingua.
    private var englishLabel: String {
        let day = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date(timeIntervalSinceReferenceDate: 0))
        let time = day.map { $0.formatted(.dateTime.hour().minute().locale(Dates.locale)) } ?? String(format: "%02d:%02d", hour, minute)
        switch kind {
        case .continuo:
            if interval % 60 != 0 { return "Every \(interval) minutes" }
            return interval == 60 ? "Every hour" : "Every \(interval / 60) hours"
        case .giornaliero: return "Every day at \(time)"
        case .settimanale:
            let name = Dates.locale.calendar.weekdaySymbols[max(0, min(6, weekday - 1))]
            return "Every \(name) at \(time)"
        default: return kind.label
        }
    }
}

/// Voce del registro: tutto ciò che l'agente ha fatto e intende fare.
public struct AgentEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case avvio, piano, passo, approvazione, risultato, errore, nota, sogno }
    public var id = UUID()
    public var date = Date.now
    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }
}

/// Una programmazione: quando lavorare e su cosa (vuoto = obiettivo principale).
public struct AgentRoutine: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var schedule: AgentSchedule
    public var task: String = ""
    public var enabled = true
    public var nextRun: Date?
    public var lastRun: Date?

    public init(schedule: AgentSchedule, task: String = "") { self.schedule = schedule; self.task = task }
}

/// Un'esecuzione dell'agente: quando, perché, come è finita e cosa ha prodotto (lo storico delle programmazioni).
public struct AgentRun: Codable, Sendable, Equatable, Identifiable {
    public enum Trigger: String, Codable, Sendable {
        case manuale, programmata, recupero
        public var label: String {
            switch self {
            case .manuale: Language.t("Avviata da te", "Started by you")
            case .programmata: Language.t("Programmata", "Scheduled")
            case .recupero: Language.t("Recuperata (l'app era chiusa)", "Caught up (the app was closed)")
            }
        }
    }
    public enum Outcome: String, Codable, Sendable {
        case inCorso, completata, daApprovare, errore, interrotta
        public var label: String {
            switch self {
            case .inCorso: Language.t("In corso", "In progress")
            case .completata: Language.t("Completata", "Completed")
            case .daApprovare: Language.t("Da approvare", "Awaiting approval")
            case .errore: Language.t("Non riuscita", "Failed")
            case .interrotta: Language.t("Interrotta", "Interrupted")
            }
        }
    }
    public var id = UUID()
    public var start = Date.now
    public var end: Date?
    public var trigger: Trigger
    public var routineID: UUID?
    /// Identità stabile della scadenza. Presente solo per le esecuzioni programmate.
    public var occurrenceID: String?
    /// Programmazione al momento dell'esecuzione («Ogni giorno alle 18:00»), o nil per l'obiettivo principale.
    public var routineLabel: String?
    public var task = ""
    public var outcome: Outcome = .inCorso
    public var steps = 0
    public var approvals = 0
    public var errors = 0
    public var summary = ""

    public init(trigger: Trigger, routine: AgentRoutine? = nil, occurrenceID: String? = nil) {
        self.trigger = trigger
        routineID = routine?.id
        self.occurrenceID = occurrenceID
        routineLabel = routine?.schedule.label
        task = routine?.task ?? ""
    }

    public var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }
}

/// Cartella collegata a un agente: in sola lettura o anche in scrittura.
public struct AgentFolder: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var path: String
    public var writable: Bool

    public init(path: String, writable: Bool) { self.path = path; self.writable = writable }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.lastPathComponent }
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Un sogno: la riflessione notturna con cui l'agente si migliora.
public struct AgentDream: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var date = Date.now
    public var reflection: String
    public var lessons: [String]
    public var previousInstructions: String
    public var newInstructions: String

    public init(reflection: String, lessons: [String], previousInstructions: String, newInstructions: String) {
        self.reflection = reflection; self.lessons = lessons; self.previousInstructions = previousInstructions; self.newInstructions = newInstructions
    }
}

/// Un agente: un obiettivo su cui lavora da solo, con programmazioni, cartelle, anima, sogni, permessi, memoria e registro.
public struct AgentSpec: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    /// Ruolo dell'agente (es. «Rassegna stampa»).
    public var name: String
    /// Nome di persona (es. «Giulia»): l'agente si presenta come «Giulia - Rassegna stampa».
    public var personName = ""
    /// Genmoji o ritratto precedente, conservato nella cartella del Genius.
    public var avatarPath: String?
    /// Spazio in cui lavora (personale, lavoro): ne usa calendari, posta e connettori.
    public var space = "lavoro"
    public var goal: String
    public var instructions = ""
    public var symbol = "sparkles"
    public var color = "indigo"
    public var routines: [AgentRoutine] = []
    public var folders: [AgentFolder] = []
    public var projectName: String?
    public var allowWeb = true
    public var allowApps: Set<SourceKind> = [.calendar, .reminders, .mail, .notes, .files]
    public var allowConnectors = false
    public var active = true
    public var created = Date.now
    public var lastRun: Date?
    public var runs = 0
    public var lastSummary: String?
    public var memory: [String] = []
    public var log: [AgentEvent] = []
    /// Storico delle esecuzioni (le più recenti in fondo, al massimo 200).
    public var history: [AgentRun] = []
    /// Sogno notturno: rilegge la giornata, impara e migliora le istruzioni e l'anima.
    public var dreamsEnabled = true
    public var dreamHour = 3
    public var lastDream: Date?
    public var dreams: [AgentDream] = []
    /// Heartbeat: nelle programmazioni «di continuo» prima controlla se c'è davvero qualcosa da fare.
    public var heartbeat = false
    /// Approva da solo eventi, promemoria, note e file (mai email né messaggi).
    public var autoApprove = false

    public init(name: String, goal: String) { self.name = name; self.goal = goal }

    /// Compatibilità con gli agenti salvati prima di programmazioni, cartelle e sogni.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        personName = try c.decodeIfPresent(String.self, forKey: .personName) ?? ""
        avatarPath = try c.decodeIfPresent(String.self, forKey: .avatarPath)
        space = try c.decodeIfPresent(String.self, forKey: .space) ?? "lavoro"
        goal = try c.decode(String.self, forKey: .goal)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "sparkles"
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "indigo"
        routines = try c.decodeIfPresent([AgentRoutine].self, forKey: .routines) ?? []
        if routines.isEmpty, let legacy = try c.decodeIfPresent(AgentSchedule.self, forKey: .schedule), legacy.kind != .manuale {
            var routine = AgentRoutine(schedule: legacy)
            routine.nextRun = try c.decodeIfPresent(Date.self, forKey: .nextRun)
            routines = [routine]
        }
        folders = try c.decodeIfPresent([AgentFolder].self, forKey: .folders) ?? []
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        allowWeb = try c.decodeIfPresent(Bool.self, forKey: .allowWeb) ?? true
        allowApps = try c.decodeIfPresent(Set<SourceKind>.self, forKey: .allowApps) ?? [.calendar, .reminders, .mail, .notes, .files]
        allowConnectors = try c.decodeIfPresent(Bool.self, forKey: .allowConnectors) ?? false
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? .now
        lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
        runs = try c.decodeIfPresent(Int.self, forKey: .runs) ?? 0
        lastSummary = try c.decodeIfPresent(String.self, forKey: .lastSummary)
        memory = try c.decodeIfPresent([String].self, forKey: .memory) ?? []
        log = try c.decodeIfPresent([AgentEvent].self, forKey: .log) ?? []
        history = try c.decodeIfPresent([AgentRun].self, forKey: .history) ?? AgentSpec.history(fromLog: log)
        dreamsEnabled = try c.decodeIfPresent(Bool.self, forKey: .dreamsEnabled) ?? true
        dreamHour = try c.decodeIfPresent(Int.self, forKey: .dreamHour) ?? 3
        lastDream = try c.decodeIfPresent(Date.self, forKey: .lastDream)
        dreams = try c.decodeIfPresent([AgentDream].self, forKey: .dreams) ?? []
        heartbeat = try c.decodeIfPresent(Bool.self, forKey: .heartbeat) ?? false
        autoApprove = try c.decodeIfPresent(Bool.self, forKey: .autoApprove) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(goal, forKey: .goal)
        try c.encode(personName, forKey: .personName); try c.encodeIfPresent(avatarPath, forKey: .avatarPath); try c.encode(space, forKey: .space)
        try c.encode(instructions, forKey: .instructions); try c.encode(symbol, forKey: .symbol); try c.encode(color, forKey: .color)
        try c.encode(routines, forKey: .routines); try c.encode(folders, forKey: .folders); try c.encodeIfPresent(projectName, forKey: .projectName)
        try c.encode(allowWeb, forKey: .allowWeb); try c.encode(allowApps, forKey: .allowApps); try c.encode(allowConnectors, forKey: .allowConnectors)
        try c.encode(active, forKey: .active); try c.encode(created, forKey: .created); try c.encodeIfPresent(lastRun, forKey: .lastRun)
        try c.encode(runs, forKey: .runs); try c.encodeIfPresent(lastSummary, forKey: .lastSummary); try c.encode(memory, forKey: .memory)
        try c.encode(log, forKey: .log); try c.encode(history, forKey: .history); try c.encode(dreamsEnabled, forKey: .dreamsEnabled); try c.encode(dreamHour, forKey: .dreamHour)
        try c.encodeIfPresent(lastDream, forKey: .lastDream); try c.encode(dreams, forKey: .dreams)
        try c.encode(heartbeat, forKey: .heartbeat); try c.encode(autoApprove, forKey: .autoApprove)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, personName, avatarPath, space, goal, instructions, symbol, color, routines, folders, projectName, allowWeb, allowApps, allowConnectors, active, created
        case lastRun, runs, lastSummary, memory, log, history, dreamsEnabled, dreamHour, lastDream, dreams, heartbeat, autoApprove
        case schedule, nextRun   // solo per leggere i vecchi agenti
    }

    /// Nome umanizzato «Nome - Ruolo».
    public var displayName: String { personName.isEmpty ? name : "\(personName) - \(name)" }

    public static let personNames = ["Giulia", "Marco", "Sofia", "Luca", "Elena", "Davide", "Chiara", "Matteo", "Anna", "Tommaso",
                                     "Sara", "Pietro", "Alice", "Lorenzo", "Martina", "Federico", "Aurora", "Gabriele", "Beatrice", "Riccardo"]

    public static let englishPersonNames = ["Emma", "Oliver", "Sophie", "Jack", "Grace", "Leo", "Chloe", "Noah", "Ella", "Henry",
                                            "Lucy", "Samuel", "Alice", "Theo", "Maya", "Daniel", "Ruby", "Adam", "Clara", "Owen"]

    /// I nomi nella lingua in cui si lavora.
    public static var localizedPersonNames: [String] { Language.isEnglish ? englishPersonNames : personNames }

    /// Un nome di persona non ancora usato dagli altri agenti.
    public static func suggestedPersonName(for role: String, avoiding used: [String]) -> String {
        let names = localizedPersonNames
        let free = names.filter { !used.contains($0) }
        let pool = free.isEmpty ? names : free
        let seed = role.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return pool[seed % pool.count]
    }

    public mutating func record(_ kind: AgentEvent.Kind, _ text: String) {
        log.append(AgentEvent(kind: kind, text: text))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    /// Apre una voce nello storico e ne restituisce l'id.
    @discardableResult
    public mutating func beginRun(_ trigger: AgentRun.Trigger, routine: AgentRoutine?, occurrenceID: String? = nil) -> UUID {
        let run = AgentRun(trigger: trigger, routine: routine, occurrenceID: occurrenceID)
        history.append(run)
        if history.count > 200 { history.removeFirst(history.count - 200) }
        return run.id
    }

    public mutating func updateRun(_ id: UUID, _ change: (inout AgentRun) -> Void) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        change(&history[index])
    }

    /// Storico ricostruito dal registro per gli agenti salvati prima che esistesse (un'esecuzione per ogni «avvio»).
    public static func history(fromLog log: [AgentEvent]) -> [AgentRun] {
        var runs: [AgentRun] = []
        for event in log {
            switch event.kind {
            case .avvio:
                if let last = runs.indices.last, runs[last].outcome == .inCorso { runs[last].outcome = .interrotta }
                var run = AgentRun(trigger: .manuale)
                run.start = event.date
                if let range = event.text.range(of: " · ") {
                    let detail = String(event.text[range.upperBound...])
                    // «Ogni giorno alle 18:00: compito» — i due punti dell'orario non hanno lo spazio dopo.
                    if let colon = detail.range(of: ": ") {
                        run.routineLabel = String(detail[..<colon.lowerBound])
                        run.task = String(detail[colon.upperBound...])
                    } else {
                        run.routineLabel = detail
                    }
                    run.trigger = .programmata
                }
                runs.append(run)
            case .passo:
                if let last = runs.indices.last { runs[last].steps += 1 }
            case .approvazione:
                if let last = runs.indices.last { runs[last].approvals += 1 }
            case .errore:
                guard let last = runs.indices.last, runs[last].outcome == .inCorso else { continue }
                runs[last].errors += 1
                if !event.text.contains(": ") {   // errore dell'intera esecuzione, non di un passo
                    runs[last].outcome = .errore; runs[last].end = event.date; runs[last].summary = event.text
                }
            case .risultato:
                guard let last = runs.indices.last, runs[last].outcome == .inCorso else { continue }
                runs[last].outcome = runs[last].approvals > 0 ? .daApprovare : .completata
                runs[last].end = event.date
                runs[last].summary = event.text
            case .nota where event.text.hasPrefix("Esecuzione interrotta"):
                guard let last = runs.indices.last, runs[last].outcome == .inCorso else { continue }
                runs[last].outcome = .interrotta; runs[last].end = event.date
            case .nota where event.text.hasPrefix("Recupero l'esecuzione"):
                continue
            default: continue
            }
        }
        if let last = runs.indices.last, runs[last].outcome == .inCorso { runs[last].outcome = .interrotta }
        return runs
    }

    /// Prossima esecuzione fra tutte le programmazioni attive.
    public var nextRun: Date? { active ? routines.filter(\.enabled).compactMap(\.nextRun).min() : nil }
    public var isScheduled: Bool { active && routines.contains { $0.enabled && $0.schedule.kind != .manuale } }

    public var scheduleLabel: String {
        let enabled = routines.filter { $0.enabled && $0.schedule.kind != .manuale }
        switch enabled.count {
        case 0: return AgentSchedule.Kind.manuale.label
        case 1: return enabled[0].schedule.label
        default: return Language.t("\(enabled.count) programmazioni", "\(enabled.count) schedules")
        }
    }

    /// Ricalcola le prossime esecuzioni (dopo modifiche o a fine lavoro).
    public mutating func reschedule(after date: Date = .now) {
        for index in routines.indices {
            routines[index].nextRun = active && routines[index].enabled ? routines[index].schedule.next(after: date) : nil
        }
    }

    public static let symbols = ["sparkles", "newspaper.fill", "envelope.fill", "calendar", "target", "binoculars.fill", "chart.line.uptrend.xyaxis",
                                 "briefcase.fill", "cart.fill", "heart.fill", "airplane", "book.fill", "house.fill", "dumbbell.fill", "fork.knife", "megaphone.fill"]
    public static let colors = ["indigo", "blue", "teal", "green", "orange", "red", "pink", "purple", "gray"]

    /// «sparkles» è la scelta automatica: il simbolo viene ricavato dal lavoro del Genius.
    public var roleSymbol: String {
        symbol == "sparkles" ? Self.suggestedSymbol(for: name + " " + goal) : symbol
    }

    public var hasGenmoji: Bool {
        avatarPath.map {
            let url = URL(fileURLWithPath: $0)
            return url.lastPathComponent.hasPrefix("genmoji-") && url.pathExtension == "genmoji"
        } ?? false
    }

    public static func suggestedSymbol(for description: String) -> String {
        let text = description.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let roles: [(String, [String])] = [
            ("newspaper.fill", ["rassegna", "notizi", "news", "stampa", "giornal", "editorial"]),
            ("envelope.fill", ["email", "e-mail", "posta", "inbox", "mail", "newsletter"]),
            ("calendar", ["calend", "agenda", "appuntament", "meeting", "riunion", "schedule"]),
            ("binoculars.fill", ["monitor", "osserv", "novita", "ricerc", "research", "trend"]),
            ("briefcase.fill", ["segret", "assistant", "daily brief", "client", "agenzia", "agency", "business", "azienda", "project", "progett"]),
            ("chart.line.uptrend.xyaxis", ["analis", "analytics", "metric", "report", "vendit", "sales", "kpi", "dati"]),
            ("megaphone.fill", ["social", "marketing", "campagn", "contenut", "pubblic", "advert", "post ", "ads"]),
            ("cart.fill", ["shop", "acquist", "commerce", "prodotto", "carrello"]),
            ("heart.fill", ["salute", "health", "benesser", "wellness"]),
            ("airplane", ["viagg", "travel", "volo", "trip"]),
            ("book.fill", ["studio", "study", "libro", "book", "lezion", "course", "corso"]),
            ("house.fill", ["casa", "home", "immobil", "house"]),
            ("dumbbell.fill", ["fitness", "allen", "workout", "sport"]),
            ("fork.knife", ["cibo", "food", "ricett", "restaurant", "cucin"]),
            ("target", ["obiettiv", "goal", "priorita", "task", "pian", "plan"]),
        ]
        return roles.first { _, cues in cues.contains { text.contains($0) } }?.0 ?? "target"
    }

    /// Anima di partenza (soul.md): identità, missione, valori, stile, limiti e cosa ha imparato.
    public var defaultSoul: String {
        if Language.isEnglish {
            return """
            # Soul of \(displayName)

            ## Who I am
            I'm \(personName.isEmpty ? name : personName), \(personName.isEmpty ? "a Genius" : "the «\(name)» Genius") of Siri AI+ working for \(Assistant.userFirstName ?? "the person who uses this Mac"). I take the initiative but ask for confirmation before important actions.

            ## Mission
            \(goal)

            ## Values
            - Accuracy: I only use real data and cite the sources.
            - Usefulness: I bring concrete results, not just information.
            - Respect: no actions toward other people without consent.

            ## Style
            - Clear, direct English, with bullet points when they help.
            - Important things first, then the details.

            ## What to avoid
            - Repeating information already given in previous runs.
            - Making up data, dates or commitments.

            ## What I learned
            """
        }
        return """
        # Anima di \(displayName)

        ## Chi sono
        Sono \(personName.isEmpty ? name : personName), \(personName.isEmpty ? "un Genius" : "il Genius «\(name)»") di Siri AI+ che lavora per \(Assistant.userLabel). Agisco con iniziativa ma chiedo conferma prima delle azioni importanti.

        ## Missione
        \(goal)

        ## Valori
        - Precisione: uso solo dati reali e cito le fonti.
        - Utilità: porto risultati concreti, non solo informazioni.
        - Rispetto: niente azioni verso altre persone senza il consenso di \(Assistant.userLabel).

        ## Stile
        - Italiano chiaro e diretto, con punti elenco quando aiutano.
        - Prima le cose importanti, poi i dettagli.

        ## Cosa evitare
        - Ripetere informazioni già date nelle esecuzioni precedenti.
        - Inventare dati, date o impegni.

        ## Cosa ho imparato
        """
    }
}

extension Assistant {
    private static var agentSchema: GenerationSchema {
        Language.isEnglish ? englishAgentSchema : italianAgentSchema
    }

    private static let englishAgentSchema = makeSchema("Agente", [
        .required("nome", .string, "Short role of the agent, 1-3 words, e.g. «AI digest»"),
        .required("persona", .choice(AgentSpec.englishPersonNames), "Person name for the agent"),
        .required("obiettivo", .string, "What the agent must do every time it works, in one or two sentences, addressed to it («Search… and summarize…»)"),
        .required("frequenza", .choice(AgentSchedule.Kind.allCases.map(\.rawValue)),
                  "When it works: manuale (only when asked), continuo (keeps watching), orario (every hour), giornaliero (every day) or settimanale (every week)"),
        .optional("ora", .string, "Run time HH:mm, if given"),
        .optional("giorno", .choice(englishWeekdays), "Day of the week, if weekly"),
        .required("icona", .choice(AgentSpec.symbols), "Most fitting symbol"),
        .required("colore", .choice(AgentSpec.colors), "Tile color"),
        .required("web", .bool, "true if it must search the web"),
        .required("connettori", .bool, "true if it must use connected services such as Agency OS"),
    ])

    /// Da domenica a sabato, come `Calendar.weekday` (1 = domenica).
    private static let englishWeekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    private static let italianAgentSchema = makeSchema("Agente", [
        .required("nome", .string, "Ruolo breve dell'agente, 1-3 parole, es. «Rassegna AI»"),
        .required("persona", .choice(AgentSpec.personNames), "Nome di persona italiano per l'agente"),
        .required("obiettivo", .string, "Cosa deve fare l'agente ogni volta che lavora, in una o due frasi, in seconda persona («Cerca… e riassumi…»)"),
        .required("frequenza", .choice(AgentSchedule.Kind.allCases.map(\.rawValue)), "Quando lavora: manuale, continuo, orario, giornaliero o settimanale"),
        .optional("ora", .string, "Ora di esecuzione HH:mm, se indicata"),
        .optional("giorno", .choice(["lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato", "domenica"]), "Giorno della settimana, se settimanale"),
        .required("icona", .choice(AgentSpec.symbols), "Simbolo più adatto"),
        .required("colore", .choice(AgentSpec.colors), "Colore della tessera"),
        .required("web", .bool, "true se deve cercare sul web"),
        .required("connettori", .bool, "true se deve usare servizi collegati come Agency OS"),
    ])

    /// Crea un agente da una descrizione in linguaggio naturale ("ogni mattina alle 8 fammi la rassegna stampa sull'AI").
    public func draftAgent(from description: String) async throws -> AgentSpec {
        let english = Language.isEnglish
        var request = (english ? "Description: " : "Descrizione: ") + description
        if !work.mcpTools.isEmpty {
            request += (english ? "\nConnected services: " : "\nServizi collegati: ") + Set(work.mcpTools.map(\.serverName)).sorted().joined(separator: ", ")
        }
        let content = try await writer(Language.t("Trasformi la richiesta dell'utente nella configurazione di un agente personale che lavora da solo su un obiettivo.",
                                                  "You turn the user's request into the configuration of a personal agent that works on its own toward a goal."))
            .respond(to: request, schema: Self.agentSchema).content
        var agent = AgentSpec(name: content.string("nome") ?? Language.t("Nuovo Genius", "New Genius"), goal: content.string("obiettivo") ?? description)
        agent.personName = content.string("persona") ?? ""
        agent.symbol = content.string("icona") ?? "sparkles"
        agent.color = content.string("colore") ?? "indigo"
        agent.allowWeb = content.bool("web") ?? true
        agent.allowConnectors = content.bool("connettori") ?? false
        var schedule = AgentSchedule(kind: AgentSchedule.Kind(rawValue: content.string("frequenza") ?? "") ?? .manuale)
        let time = (content.string("ora") ?? "").split(separator: ":").compactMap { Int($0) }
        if time.count == 2 { schedule.hour = time[0]; schedule.minute = time[1] }
        let days = ["domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"]
        if let day = content.string("giorno"), let index = days.firstIndex(of: day) ?? Self.englishWeekdays.firstIndex(of: day) { schedule.weekday = index + 1 }
        let parsed = Self.schedule(from: description) ?? schedule
        agent.routines = parsed.kind == .manuale ? [] : [AgentRoutine(schedule: parsed)]
        let lower = description.lowercased()
        if let project = work.projectNames.first(where: { lower.contains($0.lowercased()) }) { agent.projectName = project }
        return agent
    }

    /// Frequenza e orario scritti nella frase ("ogni mattina alle 8", "ogni lunedì alle 9:30", "ogni ora").
    public static func schedule(from text: String) -> AgentSchedule? {
        let lower = text.lowercased()
        var hour: Int?
        var minute = 0
        if let match = Web.matches(#"\balle\s+(?:ore\s+)?(\d{1,2})(?:[:.](\d{2}))?"#, in: lower).first {
            hour = Int(match[0]); minute = Int(match[1]) ?? 0
        } else if lower.contains("mattin") { hour = 8 } else if lower.contains("pomeriggio") { hour = 15 } else if lower.contains("sera") { hour = 19 }
        if let value = hour, value < 12, lower.contains("sera") || lower.contains("pomeriggio") { hour = value + 12 }
        let days = ["domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"]
        if let index = days.firstIndex(where: { lower.contains("ogni \($0)") || lower.contains("il \($0)") || lower.contains("tutti i \($0)") }) {
            return AgentSchedule(kind: .settimanale, hour: hour ?? 9, minute: minute, weekday: index + 1)
        }
        if lower.contains("ogni settimana") || lower.contains("settimanal") { return AgentSchedule(kind: .settimanale, hour: hour ?? 9, minute: minute, weekday: 2) }
        if ["ogni giorno", "ogni mattina", "ogni sera", "ogni pomeriggio", "tutti i giorni", "quotidian", "giornalier", "ogni notte"].contains(where: lower.contains) {
            return AgentSchedule(kind: .giornaliero, hour: hour ?? 8, minute: minute)
        }
        if lower.contains("ogni ora") { return AgentSchedule(kind: .orario) }
        if ["di continuo", "continuamente", "tieni d'occhio", "monitora", "sorveglia"].contains(where: lower.contains) { return AgentSchedule(kind: .continuo) }
        return Language.isEnglish ? englishSchedule(from: lower) : nil
    }

    /// «every morning at 8», «every Monday at 9:30», «at 7pm every day», «hourly», «keep an eye on…».
    private static func englishSchedule(from lower: String) -> AgentSchedule? {
        var hour: Int?
        var minute = 0
        if let match = Web.matches(#"\bat\s+(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?"#, in: lower).first {
            hour = Int(match[0]); minute = Int(match[1]) ?? 0
            if let value = hour, match[2].hasPrefix("p"), value < 12 { hour = value + 12 }
            if let value = hour, match[2].hasPrefix("a"), value == 12 { hour = 0 }
        } else if lower.contains("at noon") { hour = 12 } else if lower.contains("morning") { hour = 8 }
        else if lower.contains("afternoon") { hour = 15 } else if lower.contains("evening") || lower.contains("night") { hour = 19 }
        if let value = hour, value < 12, lower.contains("evening") || lower.contains("afternoon") || lower.contains("night"),
           !lower.contains("am"), !lower.contains("a.m.") { hour = value + 12 }
        if let index = englishWeekdays.firstIndex(where: { lower.contains("every \($0)") || lower.contains("on \($0)") }) {
            return AgentSchedule(kind: .settimanale, hour: hour ?? 9, minute: minute, weekday: index + 1)
        }
        if lower.contains("every week") || lower.contains("weekly") { return AgentSchedule(kind: .settimanale, hour: hour ?? 9, minute: minute, weekday: 2) }
        if ["every day", "every morning", "every evening", "every afternoon", "every night", "daily", "each day", "each morning"].contains(where: lower.contains) {
            return AgentSchedule(kind: .giornaliero, hour: hour ?? 8, minute: minute)
        }
        if lower.contains("every hour") || lower.contains("hourly") { return AgentSchedule(kind: .orario) }
        if ["continuously", "keep an eye on", "monitor", "keep watching", "watch for"].contains(where: lower.contains) { return AgentSchedule(kind: .continuo) }
        return nil
    }

    /// Richiesta per il piano di un'esecuzione: compito (della programmazione o l'obiettivo) più ciò che l'agente sa e ha già fatto.
    public static func agentRunPrompt(_ agent: AgentSpec, task: String? = nil, soul: String? = nil) -> String {
        if Language.isEnglish { return englishAgentRunPrompt(agent, task: task, soul: soul) }
        var text = "Compito dell'agente «\(agent.name)»: \(task.flatMap { $0.isEmpty ? nil : $0 } ?? agent.goal)"
        if let task, !task.isEmpty { text += "\nObiettivo generale: \(agent.goal)" }
        if let soul, !soul.isEmpty { text += "\nAnima dell'agente (soul.md, estratto):\n\(soul.prefix(900))" }
        if !agent.instructions.isEmpty { text += "\nIstruzioni: \(agent.instructions)" }
        if !agent.memory.isEmpty { text += "\nDa ricordare: " + agent.memory.suffix(6).joined(separator: "; ") }
        if !agent.folders.isEmpty {
            text += "\nCartelle collegate: " + agent.folders.map { "\($0.name) (\($0.writable ? "lettura e scrittura" : "solo lettura"))" }.joined(separator: ", ")
        }
        if let summary = agent.lastSummary { text += "\nEsito dell'ultima esecuzione (\(agent.lastRun.map { Dates.format($0) } ?? "")): \(summary.prefix(500))" }
        text += "\nAdesso è \(Dates.format(.now)). Lavora su ciò che è nuovo o ancora da fare rispetto all'ultima volta."
        return text
    }

    private static func englishAgentRunPrompt(_ agent: AgentSpec, task: String?, soul: String?) -> String {
        var text = "Task of the «\(agent.name)» agent: \(task.flatMap { $0.isEmpty ? nil : $0 } ?? agent.goal)"
        if let task, !task.isEmpty { text += "\nOverall goal: \(agent.goal)" }
        if let soul, !soul.isEmpty { text += "\nThe agent's soul (soul.md, excerpt):\n\(soul.prefix(900))" }
        if !agent.instructions.isEmpty { text += "\nInstructions: \(agent.instructions)" }
        if !agent.memory.isEmpty { text += "\nTo remember: " + agent.memory.suffix(6).joined(separator: "; ") }
        if !agent.folders.isEmpty {
            text += "\nLinked folders: " + agent.folders.map { "\($0.name) (\($0.writable ? "read and write" : "read only"))" }.joined(separator: ", ")
        }
        if let summary = agent.lastSummary { text += "\nOutcome of the last run (\(agent.lastRun.map { Dates.format($0) } ?? "")): \(summary.prefix(500))" }
        text += "\nIt is now \(Dates.format(.now)). Work on what is new or still to be done since last time."
        return text
    }

    private static var dreamSchema: GenerationSchema { Language.isEnglish ? englishDreamSchema : italianDreamSchema }

    private static let englishDreamSchema = makeSchema("Sogno", [
        .required("riflessione", .string, "What went well and what went badly in the recent work, in 2-4 honest sentences"),
        .required("lezioni", .array(.string, min: 1, max: 4), "Concrete lessons to work better next time, one sentence each"),
        .required("istruzioni", .string, "Improved, short operating instructions (at most 6 lines) that take the lessons and the user's directions into account"),
    ])

    private static let italianDreamSchema = makeSchema("Sogno", [
        .required("riflessione", .string, "Cosa è andato bene e cosa male nel lavoro recente, in 2-4 frasi sincere"),
        .required("lezioni", .array(.string, min: 1, max: 4), "Lezioni concrete per lavorare meglio la prossima volta, una frase ciascuna"),
        .required("istruzioni", .string, "Istruzioni operative migliorate e brevi (massimo 6 righe) che tengono conto delle lezioni e delle indicazioni di \(Assistant.userLabel)"),
    ])

    /// Il sogno notturno: rilegge registro, esiti, approvazioni e indicazioni, ne trae lezioni e migliora le istruzioni.
    public func dream(for agent: AgentSpec, soul: String, approvals: (accepted: Int, rejected: Int)) async throws -> AgentDream {
        let events = agent.log.suffix(40).map { "[\($0.kind.rawValue)] \($0.text.prefix(160))" }.joined(separator: "\n")
        let request = Language.isEnglish ? """
        Agent «\(agent.name)». Goal: \(agent.goal)
        Current instructions: \(agent.instructions.isEmpty ? "none" : agent.instructions)
        Soul (soul.md, excerpt):\n\(soul.prefix(1200))
        Directions from the user to remember: \(agent.memory.suffix(8).joined(separator: "; "))
        Actions proposed and approved by the user: \(approvals.accepted); cancelled: \(approvals.rejected)
        Last result: \(agent.lastSummary?.prefix(500) ?? "none")
        Recent log:\n\(events)
        """ : """
        Agente «\(agent.name)». Obiettivo: \(agent.goal)
        Istruzioni attuali: \(agent.instructions.isEmpty ? "nessuna" : agent.instructions)
        Anima (soul.md, estratto):\n\(soul.prefix(1200))
        Indicazioni di \(Assistant.userLabel) da ricordare: \(agent.memory.suffix(8).joined(separator: "; "))
        Azioni proposte e approvate da \(Assistant.userLabel): \(approvals.accepted); annullate: \(approvals.rejected)
        Ultimo risultato: \(agent.lastSummary?.prefix(500) ?? "nessuno")
        Registro recente:\n\(events)
        """
        let content = try await writer(Language.t("Sei l'agente stesso che, di notte, sogna: ripensi al tuo lavoro per migliorarti. Sii concreto e onesto.",
                                                  "You are the agent itself, dreaming at night: you think back on your work to improve. Be concrete and honest."))
            .respond(to: request, schema: Self.dreamSchema).content
        return AgentDream(reflection: content.string("riflessione") ?? "", lessons: content.strings("lezioni"),
                          previousInstructions: agent.instructions, newInstructions: content.string("istruzioni") ?? agent.instructions)
    }

    /// Aggiunge le lezioni del sogno alla sezione «Cosa ho imparato» di soul.md (tiene le 15 più recenti).
    public static func soul(_ soul: String, adding lessons: [String], on date: Date = .now) -> String {
        // L'anima scritta in inglese ha la sezione «What I learned»: si usa quella che c'è, altrimenti quella della lingua corrente.
        let englishSoul = soul.range(of: #"(?m)^## What I learned[ \t]*$"#, options: .regularExpression) != nil
            || (soul.range(of: #"(?m)^## Cosa ho imparato[ \t]*$"#, options: .regularExpression) == nil && Language.isEnglish)
        let heading = englishSoul ? "## What I learned" : "## Cosa ho imparato"
        let day = date.localDay
        var text = soul
        // La sezione vera è un titolo a inizio riga (non una citazione dentro un blocco di codice).
        func headingRange(_ text: String) -> Range<String.Index>? {
            text.range(of: "(?m)^\(heading)[ \\t]*$", options: .regularExpression)
        }
        if headingRange(text) == nil { text += (text.hasSuffix("\n") ? "" : "\n") + "\n\(heading)\n" }
        guard let range = headingRange(text) else { return text }
        let after = text[range.upperBound...]
        let end = after.range(of: "\n## ")?.lowerBound ?? text.endIndex
        var items = text[range.upperBound..<end].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("- ") }
        items += lessons.map { "- [\(day)] \($0)" }
        text.replaceSubrange(range.upperBound..<end, with: "\n" + items.suffix(15).joined(separator: "\n") + "\n")
        return text
    }
}

extension Assistant {
    private static var heartbeatSchema: GenerationSchema { Language.isEnglish ? englishHeartbeatSchema : italianHeartbeatSchema }

    private static let italianHeartbeatSchema = makeSchema("Controllo", [
        .required("agire", .bool, "true solo se nei dati c'è qualcosa di nuovo che richiede davvero il lavoro dell'agente adesso"),
        .required("motivo", .string, "In una frase, perché agire o no"),
    ])

    private static let englishHeartbeatSchema = makeSchema("Controllo", [
        .required("agire", .bool, "true only if the data contains something new that really needs the agent's work now"),
        .required("motivo", .string, "In one sentence, why act or not"),
    ])

    /// Heartbeat: guarda la situazione (agenda, promemoria, posta non letta) e decide se vale la pena avviare l'agente.
    public func shouldAct(_ agent: AgentSpec, snapshot: String) async -> (act: Bool, reason: String) {
        let english = Language.isEnglish
        let session = LanguageModelSession(model: Agent.model, instructions: english
            ? "Decide whether an automatic agent should work now. Be cautious: act only if there is something new and relevant to its goal."
            : "Decidi se un agente automatico deve lavorare adesso. Sii prudente: agisci solo se c'è qualcosa di nuovo e pertinente al suo obiettivo.")
        let lastRun = agent.lastRun.map { Dates.format($0) } ?? Language.t("mai", "never")
        let request = english
            ? "Agent: \(agent.displayName)\nGoal: \(agent.goal)\nLast run: \(lastRun)\n\nSituation now:\n\(snapshot.prefix(2500))"
            : "Agente: \(agent.displayName)\nObiettivo: \(agent.goal)\nUltima esecuzione: \(lastRun)\n\nSituazione adesso:\n\(snapshot.prefix(2500))"
        guard let content = try? await session.respond(to: request, schema: Self.heartbeatSchema, options: GenerationOptions(samplingMode: .greedy)).content
        else { return (false, Language.t("controllo non riuscito", "check failed")) }
        return (content.bool("agire") ?? false, content.string("motivo") ?? "")
    }
}
