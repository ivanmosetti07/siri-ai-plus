import Foundation

/// Filtri dello spazio in uso (Personale, Lavoro, Programmazioni): quali calendari, liste e account di posta vede Siri AI+.
/// Vale per la richiesta in corso (`task`) o, fuori da una richiesta, per lo spazio aperto nell'app (`global`).
public struct SpaceScope: Sendable, Equatable {
    public var name = ""
    /// Calendari da usare (nil = tutti).
    public var calendars: Set<String>?
    public var reminderLists: Set<String>?
    public var defaultCalendar: String?
    public var defaultReminderList: String?
    /// Account di Mail da leggere (nil = posta in arrivo unificata).
    public var mailAccount: String?

    public init() {}

    @TaskLocal public static var task: SpaceScope?
    nonisolated(unsafe) public static var global = SpaceScope()
    public static var current: SpaceScope { task ?? global }
}
