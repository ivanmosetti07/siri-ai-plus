import EventKit
import Foundation
import FoundationModels

// MARK: - Configurazione globale (impostata una sola volta all'avvio)

public enum Config {
    nonisolated(unsafe) public static var autoApprove = false
    nonisolated(unsafe) public static var verbose = false
}

// MARK: - Hook: permettono a CLI e app grafica di gestire conferme e log a modo loro

public enum Hooks {
    /// Chiede all'utente di approvare un'azione che modifica i dati.
    nonisolated(unsafe) public static var confirm: @Sendable (String) async -> Bool = { summary in
        print("\n\u{1B}[33m⚠️  \(summary)\u{1B}[0m")
        print(Language.t("   Confermi? [s/N] ", "   Confirm? [y/N] "), terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return ["s", "si", "sì", "y", "yes"].contains(answer)
    }

    /// Notifica una chiamata a uno strumento (nome tecnico, descrizione leggibile).
    nonisolated(unsafe) public static var toolCall: @Sendable (String, String) -> Void = { name, detail in
        guard Config.verbose else { return }
        FileHandle.standardError.write(Data("\n\u{1B}[2m🔧 \(name) \(detail)\u{1B}[0m\n".utf8))
    }

    /// Chiamato dopo che calendario o promemoria sono stati modificati.
    nonisolated(unsafe) public static var didModify: @Sendable () -> Void = {}
}

// MARK: - Accesso condiviso a EventKit

public final class Store: @unchecked Sendable {
    public static let shared = Store()
    public let ek = EKEventStore()

    public func requestAccess() async -> (calendar: Bool, reminders: Bool) {
        let cal = (try? await ek.requestFullAccessToEvents()) ?? false
        let rem = (try? await ek.requestFullAccessToReminders()) ?? false
        return (cal, rem)
    }

    func eventCalendar(named name: String?) -> EKCalendar? {
        guard let name, !name.isEmpty else { return ek.defaultCalendarForNewEvents }
        return ek.calendars(for: .event).first {
            $0.allowsContentModifications && $0.title.localizedCaseInsensitiveContains(name)
        }
    }

    func reminderList(named name: String?) -> EKCalendar? {
        guard let name, !name.isEmpty else { return ek.defaultCalendarForNewReminders() }
        return ek.calendars(for: .reminder).first { $0.title.localizedCaseInsensitiveContains(name) }
    }
}

// MARK: - ID brevi (E1, R2…) per non far copiare UUID lunghi al modello on-device

public final class IDRegistry: @unchecked Sendable {
    struct EventRef { let identifier: String; let start: Date }

    public static let shared = IDRegistry()
    public init() {}
    private let lock = NSLock()
    private var events: [String: EventRef] = [:]
    private var reminders: [String: String] = [:]
    private var eventCounter = 0
    private var reminderCounter = 0

    func register(event identifier: String, start: Date) -> String {
        lock.withLock {
            if let existing = events.first(where: { $0.value.identifier == identifier && $0.value.start == start }) {
                return existing.key
            }
            if events.count > 400 { events = [:] }
            eventCounter += 1
            let key = "E\(eventCounter)"
            events[key] = EventRef(identifier: identifier, start: start)
            return key
        }
    }

    func register(reminder identifier: String) -> String {
        lock.withLock {
            if let existing = reminders.first(where: { $0.value == identifier }) { return existing.key }
            if reminders.count > 400 { reminders = [:] }
            reminderCounter += 1
            let key = "R\(reminderCounter)"
            reminders[key] = identifier
            return key
        }
    }

    func event(_ key: String) -> EventRef? { lock.withLock { events[key.uppercased()] } }
    func reminder(_ key: String) -> String? { lock.withLock { reminders[key.uppercased()] } }

    public func reset() {
        lock.withLock {
            events = [:]; reminders = [:]; eventCounter = 0; reminderCounter = 0
        }
    }
}

// MARK: - Schema dinamici (sostituiscono @Generable, non disponibile senza Xcode)

indirect enum FieldType {
    case string, int, bool, double
    case choice([String])
    case array(FieldType, min: Int? = nil, max: Int? = nil)
    case object(String, [Field])
}

struct Field {
    let name: String
    let description: String
    let type: FieldType
    var optional = false

    static func required(_ name: String, _ type: FieldType, _ description: String) -> Field {
        Field(name: name, description: description, type: type)
    }

    static func optional(_ name: String, _ type: FieldType, _ description: String) -> Field {
        Field(name: name, description: description, type: type, optional: true)
    }
}

private func dynamicSchema(_ type: FieldType, name: String) -> DynamicGenerationSchema {
    switch type {
    case .string: DynamicGenerationSchema(type: String.self)
    case .int: DynamicGenerationSchema(type: Int.self)
    case .bool: DynamicGenerationSchema(type: Bool.self)
    case .double: DynamicGenerationSchema(type: Double.self)
    case .choice(let options): DynamicGenerationSchema(name: name, anyOf: options)
    case .array(let element, let min, let max):
        DynamicGenerationSchema(arrayOf: dynamicSchema(element, name: name + "Item"), minimumElements: min, maximumElements: max)
    case .object(let objectName, let fields):
        DynamicGenerationSchema(name: objectName, properties: fields.map { field in
            .init(name: field.name, description: field.description,
                  schema: dynamicSchema(field.type, name: "\(objectName)_\(field.name)"), isOptional: field.optional)
        })
    }
}

func makeSchema(_ name: String, _ fields: [Field]) -> GenerationSchema {
    do {
        return try GenerationSchema(root: dynamicSchema(.object(name, fields), name: name), dependencies: [])
    } catch {
        fatalError("Schema non valido per \(name): \(error)")
    }
}

extension GeneratedContent {
    func string(_ key: String) -> String? {
        guard let value = try? value(String?.self, forProperty: key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func int(_ key: String) -> Int? { (try? value(Int?.self, forProperty: key)) ?? nil }
    func bool(_ key: String) -> Bool? { (try? value(Bool?.self, forProperty: key)) ?? nil }
    func double(_ key: String) -> Double? { (try? value(Double?.self, forProperty: key)) ?? nil }
    func strings(_ key: String) -> [String] {
        ((try? value([String].self, forProperty: key)) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    func objects(_ key: String) -> [GeneratedContent] { (try? value([GeneratedContent].self, forProperty: key)) ?? [] }
    func doubles(_ key: String) -> [Double] { (try? value([Double].self, forProperty: key)) ?? [] }
}

// MARK: - Date

public enum Dates {
    /// Formati di date e numeri nella lingua della richiesta in corso (fuori da una richiesta, quella del Mac).
    public static var locale: Locale { Language.current.locale }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f
    }

    private static let withTime = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"].map(formatter)
    private static let dayOnly = formatter("yyyy-MM-dd")

    /// Restituisce la data e se contiene un orario.
    public static func parse(_ text: String?) -> (date: Date, hasTime: Bool)? {
        guard let text else { return nil }
        let cleaned = text.replacingOccurrences(of: "Z", with: "")
        for f in withTime { if let d = f.date(from: cleaned) { return (d, true) } }
        if let d = dayOnly.date(from: String(cleaned.prefix(10))) { return (d, false) }
        return nil
    }

    /// Data per le persone: «oggi alle 18:00», «domani alle 9:30», «mar 22 set alle 18:00»;
    /// in inglese «today at 6:00 PM», «tomorrow at 9:30 AM», «Tue, Sep 22 at 6:00 PM».
    public static func friendly(_ date: Date, time: Bool = true) -> String {
        let cal = Calendar.current
        let locale = Self.locale
        let clock = date.formatted(.dateTime.hour().minute().locale(locale))
        let day: String
        if cal.isDateInToday(date) { day = Language.t("oggi", "today") }
        else if cal.isDateInTomorrow(date) { day = Language.t("domani", "tomorrow") }
        else if cal.isDateInYesterday(date) { day = Language.t("ieri", "yesterday") }
        else {
            let sameYear = cal.component(.year, from: date) == cal.component(.year, from: .now)
            day = sameYear ? date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale))
                           : date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
        }
        return time ? "\(day) \(Language.t("alle", "at")) \(clock)" : day
    }

    public static func format(_ date: Date, time: Bool = true) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = time ? "EEE yyyy-MM-dd HH:mm" : "EEE yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Mini-calendario dei prossimi giorni: aiuta il modello piccolo a risolvere "domani", "venerdì"…
    /// In inglese «- Saturday 2026-09-26 (today)».
    public static func upcomingDays(_ count: Int = 8) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "EEEE yyyy-MM-dd"
        let (todayLabel, tomorrowLabel) = (Language.t(" (oggi)", " (today)"), Language.t(" (domani)", " (tomorrow)"))
        return (0..<count).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: offset, to: today) else { return nil }
            let label = offset == 0 ? todayLabel : offset == 1 ? tomorrowLabel : ""
            return "- \(f.string(from: d))\(label)"
        }.joined(separator: "\n")
    }
}

// MARK: - Log e conferme

enum Console {
    static func toolCall(_ name: String, _ detail: String) {
        Hooks.toolCall(name, detail)
    }

    /// Chiede conferma all'utente prima di un'azione che modifica i dati.
    static func confirm(_ summary: String) async -> Bool {
        if Config.autoApprove { return true }
        return await Hooks.confirm(summary)
    }
}
