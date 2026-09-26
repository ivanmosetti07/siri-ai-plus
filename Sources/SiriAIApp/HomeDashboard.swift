import SiriCore
import SwiftUI

/// Le pillole in alto, come nell'app Salute: ognuna porta in primo piano un aspetto della giornata.
enum HomeFocus: String, CaseIterable, Identifiable {
    case oggi, daFare, agenti, meteo
    var id: String { rawValue }

    var title: String {
        switch self {
        case .meteo: String(localized: "Meteo")
        case .oggi: String(localized: "Oggi")
        case .daFare: String(localized: "Da fare")
        case .agenti: String(localized: "Genius")
        }
    }

    var tint: Color {
        switch self {
        case .meteo: .cyan
        case .oggi: .red
        case .daFare: .orange
        case .agenti: .purple
        }
    }
}

/// Impegni e promemoria di oggi, letti da Calendario e Promemoria.
struct DayData: Equatable {
    var events: [EventItem] = []
    var tomorrowCount = 0
    var reminders: [ReminderItem] = []
    var completedToday = 0

    var timed: [EventItem] { events.filter { !$0.isAllDay } }
    var allDay: [EventItem] { events.filter(\.isAllDay) }

    func isOverdue(_ reminder: ReminderItem, now: Date) -> Bool {
        guard let due = reminder.due else { return false }
        return reminder.dueHasTime ? due < now : due < Calendar.current.startOfDay(for: now)
    }

    func overdue(now: Date) -> [ReminderItem] { reminders.filter { isOverdue($0, now: now) } }

    func dueToday(now: Date) -> [ReminderItem] {
        reminders.filter { reminder in
            guard let due = reminder.due else { return false }
            return Calendar.current.isDate(due, inSameDayAs: now) && !isOverdue(reminder, now: now)
        }
    }

    var undated: Int { reminders.filter { $0.due == nil }.count }

    /// Promemoria in scadenza per ciascuno dei prossimi sette giorni.
    func week(now: Date) -> [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            return (day, reminders.filter { $0.due.map { calendar.isDate($0, inSameDayAs: day) } ?? false }.count)
        }
    }

    /// Minuti occupati oggi dagli impegni con orario (senza contare due volte le sovrapposizioni).
    var busyMinutes: Int {
        var covered = Set<Int>()
        let start = Calendar.current.startOfDay(for: .now)
        for event in timed {
            let from = Int(max(0, event.start.timeIntervalSince(start)) / 60)
            let to = Int(min(1440, event.end.timeIntervalSince(start) / 60))
            if to > from { covered.formUnion(from..<to) }
        }
        return covered.count
    }

    /// Da quando sei libero: adesso, o alla fine della catena di impegni in corso.
    func freeFrom(now: Date) -> Date? {
        var free = now
        var moved = true
        while moved {
            moved = false
            for event in timed where event.start <= free && event.end > free {
                free = event.end
                moved = true
            }
        }
        return Calendar.current.isDate(free, inSameDayAs: now) ? free : nil
    }
}

extension DayData {
    /// Giornata di esempio per le foto di prova (`--home-demo`).
    static func demo(now: Date) -> DayData {
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int = 0) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)! }
        func event(_ title: String, _ start: Date, _ end: Date, _ color: (Double, Double, Double), place: String? = nil, allDay: Bool = false) -> EventItem {
            EventItem(id: title, identifier: title, title: title, start: start, end: end, isAllDay: allDay, calendar: String(localized: "Lavoro"),
                      color: RGB(red: color.0, green: color.1, blue: color.2), location: place)
        }
        func reminder(_ title: String, _ due: Date?, time: Bool = false, high: Bool = false) -> ReminderItem {
            ReminderItem(id: title, title: title, list: String(localized: "Lavoro"), due: due, dueHasTime: time, highPriority: high, color: RGB(red: 1, green: 0.58, blue: 0))
        }
        var data = DayData()
        data.events = [
            event(String(localized: "Compleanno di Giulia"), calendar.startOfDay(for: now), calendar.startOfDay(for: now).addingTimeInterval(86_400), (0.35, 0.78, 0.98), allDay: true),
            event(String(localized: "Stand-up del team"), at(9, 30), at(10), (0.2, 0.6, 1)),
            event(String(localized: "Pranzo con Marco"), at(13), at(14, 15), (1, 0.62, 0.2), place: String(localized: "Trastevere")),
            event(String(localized: "Revisione campagna"), at(15), at(16, 30), (0.69, 0.4, 0.98), place: String(localized: "Sala Tevere")),
            event(String(localized: "Call con il cliente"), at(21, 30), at(22, 15), (1, 0.27, 0.36), place: String(localized: "Meet")),
        ]
        data.tomorrowCount = 3
        data.reminders = [
            reminder(String(localized: "Inviare il preventivo a Studio Rossi"), calendar.date(byAdding: .day, value: -1, to: now), high: true),
            reminder(String(localized: "Pagare la bolletta della luce"), at(18), time: true),
            reminder(String(localized: "Rispondere a Chiara"), at(23, 30), time: true),
            reminder(String(localized: "Preparare la presentazione"), calendar.date(byAdding: .day, value: 1, to: now)),
            reminder(String(localized: "Rinnovare il dominio"), calendar.date(byAdding: .day, value: 3, to: now)),
            reminder(String(localized: "Comprare il regalo per Giulia"), calendar.date(byAdding: .day, value: 3, to: now)),
            reminder(String(localized: "Leggere il report trimestrale"), nil),
        ]
        data.completedToday = 2
        return data
    }
}

/// La Home: cielo animato con il meteo vero, pillole in vetro, un pannello in evidenza come in Salute e le schede della giornata.
struct HomeDashboard: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Al centro c'è sempre la giornata: all'apertura la Home parte da «Oggi».
    @State private var focusRaw = HomeFocus.oggi.rawValue
    @State private var day = DayData()
    @State private var opened = false
    @State private var scroll = SkyScroll()
    @State private var introToken = 0
    @State private var now = Date.now
    @State private var completing = Set<String>()
    @State private var position = ScrollPosition(edge: .top)
    @Namespace private var glassSpace

    /// Diagnostica: `--opening 0.4` ferma l'apertura a metà; `--home-focus oggi` sceglie la pillola.
    private static let openingOverride = CommandLine.arguments.firstIndex(of: "--opening")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Double(CommandLine.arguments[$0 + 1]) : nil }
    private static let focusOverride = CommandLine.arguments.firstIndex(of: "--home-focus")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? HomeFocus(rawValue: CommandLine.arguments[$0 + 1]) : nil }
    @MainActor private static var hasOpened = false

    private static let demo = CommandLine.arguments.contains("--home-demo")

    /// Calendario e Promemoria collegati (nelle prove con i dati di esempio lo sono sempre).
    private func enabled(_ source: SourceKind) -> Bool { Self.demo || state.isEnabled(source) }

    private var focus: HomeFocus { Self.focusOverride ?? HomeFocus(rawValue: focusRaw) ?? .oggi }
    private var openingProgress: Double { Self.openingOverride ?? (opened ? 1 : 0) }

    var body: some View {
        ScrollView {
            content
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            scroll.offset = offset
        }
        .environment(\.colorScheme, .dark)
        .modifier(OpeningEffect(progress: openingProgress))
        .background {
            WeatherBackdrop(sky: state.weather.sky, scroll: scroll, introToken: introToken)
                .ignoresSafeArea()
        }
        .task(id: state.storeRevision) { await load() }
        .task { await keepFresh() }
        .onAppear(perform: open)
        .onChange(of: state.space) { replayOpening() }
    }

    // MARK: Apertura

    private func open() {
        guard !opened else { return }
        // Nelle foto di prova (finestra fuori schermo) le animazioni non avanzano: la Home è già aperta.
        if reduceMotion || WeatherBackdrop.stillFrames {
            opened = true
            return
        }
        let first = !Self.hasOpened
        Self.hasOpened = true
        withAnimation(.spring(duration: first ? 1.3 : 0.85, bounce: 0.14)) { opened = true }
    }

    /// Cambiando spazio la Home si richiude e si riapre, e il cielo torna a fuoco.
    private func replayOpening() {
        guard !reduceMotion else { return }
        opened = false
        introToken += 1
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            withAnimation(.spring(duration: 0.95, bounce: 0.14)) { opened = true }
        }
    }

    // MARK: Dati

    private func load() async {
        if CommandLine.arguments.contains("--home-demo") {
            day = DayData.demo(now: now)
            if let index = CommandLine.arguments.firstIndex(of: "--home-scroll"), let y = CommandLine.arguments.dropFirst(index + 1).first.flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(1))
                position.scrollTo(y: y)
            }
            return
        }
        var data = DayData()
        let calendar = Calendar.current
        if enabled(.calendar) {
            data.events = Overview.events()
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) {
                data.tomorrowCount = Overview.events(on: tomorrow).filter { !$0.isAllDay }.count
            }
        }
        if enabled(.reminders) {
            data.reminders = await Overview.openReminders(limit: 400)
            data.completedToday = await Overview.completedReminders(since: calendar.startOfDay(for: .now))
        }
        withAnimation(.smooth(duration: 0.5)) {
            day = data
            // I promemoria appena spuntati non sono più tra quelli aperti: il conteggio passa a «completati».
            completing.formIntersection(data.reminders.map(\.id))
        }
    }

    /// Ogni minuto aggiorna l'ora (anello, prossimo impegno); ogni 20 minuti il meteo.
    private func keepFresh() async {
        await state.weather.refresh()
        var minutes = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            now = .now
            minutes += 1
            if minutes % 20 == 0 { await state.weather.refresh() }
        }
    }

    private func toggle(_ reminder: ReminderItem) {
        let done = !completing.contains(reminder.id)
        withAnimation(.spring(duration: 0.35)) {
            if done { completing.insert(reminder.id) } else { completing.remove(reminder.id) }
        }
        try? Overview.setCompleted(reminderID: reminder.id, done)
        // Si vede la spunta, poi l'elenco si aggiorna.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            state.storeRevision += 1
        }
    }

    // MARK: Contenuto

    private var content: some View {
        VStack(alignment: .leading, spacing: 26) {
            header
            if let problem = state.availabilityProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular.tint(.orange.opacity(0.35)), in: .rect(cornerRadius: 18))
            }
            pills
            companionActions
            hero
            cards
            ideas
        }
        .frame(maxWidth: 920, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 14)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity)
    }

    private var companionActions: some View {
        HStack(spacing: 10) {
            Button {
                CompanionController.shared.showQuick()
            } label: {
                Label("Chat rapida", systemImage: "bubble.left.and.text.bubble.right")
            }
            Button { state.section = .activity } label: {
                Label("Attività", systemImage: "clock.arrow.circlepath")
            }
            Button {
                if let waiting = state.spaceAgents.first(where: { state.pendingApprovals(for: $0) > 0 }) {
                    state.openAgent(waiting.id)
                } else {
                    state.section = .agents
                }
            } label: {
                let pending = state.spaceAgents.reduce(0) { $0 + state.pendingApprovals(for: $1) }
                Label(pending > 0 ? String(localized: "\(pending) da approvare") : String(localized: "Approvazioni"), systemImage: "checkmark.shield")
            }
        }
        .buttonStyle(.glass)
        .font(.system(size: 13, weight: .medium))
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<13: String(localized: "Buongiorno, \(Self.firstName)")
        case 13..<18: String(localized: "Buon pomeriggio, \(Self.firstName)")
        default: String(localized: "Buonasera, \(Self.firstName)")
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Dates.locale)))
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.75))
                Text(greeting)
                    .font(.system(size: 36, weight: .bold))
                    .tracking(-0.6)
            }
            Spacer()
            Label(state.space.label, systemImage: state.space == .personale ? "house.fill" : "briefcase.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.22), radius: 12, y: 1)
    }

    // MARK: Pillole

    private var pills: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 10) {
                    ForEach(HomeFocus.allCases) { item in pill(item) }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        .scrollClipDisabled()
    }

    private func pill(_ item: HomeFocus) -> some View {
        let selected = item == focus
        return Button {
            withAnimation(.spring(duration: 0.55, bounce: 0.22)) { focusRaw = item.rawValue }
        } label: {
            HStack(spacing: 9) {
                pillIcon(item)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(pillTitle(item)).font(.system(size: 11.5, weight: .semibold)).opacity(0.7)
                    Text(pillValue(item)).font(.system(size: 14, weight: .semibold)).contentTransition(.numericText())
                }
                .fixedSize()
            }
            .foregroundStyle(selected ? Color.black.opacity(0.85) : Color.white)
            .padding(.leading, 9)
            .padding(.trailing, 16)
            .padding(.vertical, 7)
            // Come in Salute: la pillola scelta è bianca e piena, le altre sono vetro.
            .background {
                if selected {
                    Capsule().fill(.white.opacity(0.94))
                        .matchedGeometryEffect(id: "pillola", in: glassSpace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID(item.rawValue, in: glassSpace)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Icona della pillola su un tondo colorato, come in Salute: si legge sia sul vetro sia sulla pillola bianca.
    private func pillIcon(_ item: HomeFocus) -> some View {
        let symbol: String
        let fill: [Color]
        switch item {
        case .oggi: symbol = "calendar"; fill = [Color(hex: 0xFF5A4E), Color(hex: 0xE3342A)]
        case .daFare: symbol = "checklist"; fill = [Color(hex: 0xFFB340), Color(hex: 0xFF8A00)]
        case .agenti: symbol = "person.2.fill"; fill = [Color(hex: 0xC47BFF), Color(hex: 0x8E4BEA)]
        case .meteo: symbol = state.weather.snapshot?.symbol ?? "cloud.sun.fill"; fill = [Color(hex: 0x3B8BEB), Color(hex: 0x7CC0F5)]
        }
        return Group {
            if item == .meteo {
                Image(systemName: symbol).symbolRenderingMode(.multicolor).font(.system(size: 13))
            } else {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 26, height: 26)
        .background(LinearGradient(colors: fill, startPoint: .top, endPoint: .bottom), in: Circle())
    }

    private func pillTitle(_ item: HomeFocus) -> String {
        item == .meteo ? (state.weather.snapshot?.place ?? state.weather.city) : item.title
    }

    private func pillValue(_ item: HomeFocus) -> String {
        switch item {
        case .meteo:
            guard let snapshot = state.weather.snapshot else { return String(localized: "Meteo") }
            return "\(WeatherSnapshot.degrees(snapshot.temperature)) · \(snapshot.condition.label)"
        case .oggi:
            guard enabled(.calendar) else { return String(localized: "Collega") }
            let count = day.events.count
            return count == 0 ? String(localized: "Giornata libera") : "\(count) \(count == 1 ? "impegno" : "impegni")"
        case .daFare:
            guard enabled(.reminders) else { return String(localized: "Collega") }
            let open = day.dueToday(now: now).count + day.overdue(now: now).count
            return open == 0 ? String(localized: "Tutto fatto") : "\(open) \(open == 1 ? "promemoria" : "promemoria")"
        case .agenti:
            let agents = state.spaceAgents
            let pending = agents.reduce(0) { $0 + state.pendingApprovals(for: $1) }
            if pending > 0 { return String(localized: "\(pending) da approvare") }
            if agents.contains(where: { state.runningAgents.contains($0.id) }) { return String(localized: "Al lavoro") }
            let active = agents.filter(\.active).count
            return agents.isEmpty ? String(localized: "Nessuno") : "\(active) \(active == 1 ? "attivo" : "attivi")"
        }
    }

    // MARK: In evidenza

    private var hero: some View {
        let insight = self.insight
        return VStack(alignment: .leading, spacing: 20) {
            heroVisual
                .frame(maxWidth: .infinity)
                .frame(minHeight: 250)
            VStack(alignment: .leading, spacing: 7) {
                Text(insight.title)
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.5)
                    .fixedSize(horizontal: false, vertical: true)
                Text(insight.detail)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.2), radius: 10, y: 1)
            // Senza Calendario o Promemoria collegati niente grafico a zero: basta il pulsante «Collega».
            if !(focus == .oggi && !enabled(.calendar)) && !(focus == .daFare && !enabled(.reminders)) {
                GlassPanel {
                    VStack(alignment: .leading, spacing: 16) { heroPanel }
                }
            }
        }
        .id(focus)
        .transition(.blurReplace)
    }

    @ViewBuilder
    private var heroVisual: some View {
        switch focus {
        case .meteo:
            WeatherHero(weather: state.weather)
        case .oggi:
            if enabled(.calendar) {
                DayRing(events: day.timed, now: now)
            } else {
                connect(String(localized: "Collega il Calendario"), source: .calendar)
            }
        case .daFare:
            if enabled(.reminders) {
                TodoRing(done: day.completedToday + completing.count, open: max(0, day.dueToday(now: now).count + day.overdue(now: now).count - completing.count),
                         overdue: day.overdue(now: now).count)
            } else {
                connect(String(localized: "Collega i Promemoria"), source: .reminders)
            }
        case .agenti:
            let agents = state.spaceAgents
            AgentsConstellation(agents: agents, running: state.runningAgents,
                                pending: Dictionary(uniqueKeysWithValues: agents.map { ($0.id, state.pendingApprovals(for: $0)) }),
                                orb: state.orb)
        }
    }

    private func connect(_ title: String, source: SourceKind) -> some View {
        VStack(spacing: 14) {
            Tile(source, size: 64)
            Button(title) { state.section = .app(source) }.buttonStyle(.glass).controlSize(.large)
        }
    }

    private var insight: (title: String, detail: String) {
        switch focus {
        case .meteo:
            guard let snapshot = state.weather.snapshot else {
                return (String(localized: "Il meteo di \(state.weather.city)"), String(localized: "Sto leggendo le previsioni…"))
            }
            let insight = snapshot.insight(now: state.weather.demoNow ?? now)
            return (insight.title, insight.detail)
        case .oggi: return dayInsight
        case .daFare: return todoInsight
        case .agenti: return agentsInsight
        }
    }

    /// Il meteo dentro la giornata: pioggia o temporali all'ora di un impegno.
    private func weatherNote(at date: Date) -> String? {
        guard let snapshot = state.weather.snapshot,
              let hour = snapshot.hours.first(where: { Calendar.current.isDate($0.date, equalTo: date, toGranularity: .hour) }) else { return nil }
        let clock = Calendar.current.component(.hour, from: date)
        if hour.condition == .thunderstorm { return String(localized: "Alle \(clock) sono previsti temporali.") }
        if hour.condition == .snow { return String(localized: "Alle \(clock) è prevista neve.") }
        if hour.condition.isWet || hour.precipitationChance >= 50 {
            return String(localized: "Alle \(clock) è prevista pioggia (\(hour.precipitationChance)%): porta l'ombrello.")
        }
        return nil
    }

    /// Il meteo in una frase, per le giornate libere.
    private var weatherLine: String {
        guard let snapshot = state.weather.snapshot else { return "" }
        return String(localized: " Fuori \(WeatherSnapshot.degrees(snapshot.temperature)), \(snapshot.condition.label.lowercased()).")
    }

    private var dayInsight: (title: String, detail: String) {
        guard enabled(.calendar) else { return (String(localized: "La tua giornata"), String(localized: "Collega il Calendario per vedere qui i tuoi impegni.\(weatherLine)")) }
        let clock = { (date: Date) in date.formatted(.dateTime.hour().minute().locale(Dates.locale)) }
        let tomorrow = day.tomorrowCount == 0 ? String(localized: "Domani è libero.") : String(localized: "Domani \(day.tomorrowCount == 1 ? String(localized: "hai un impegno") : String(localized: "hai \(day.tomorrowCount) impegni")).")
        if let current = day.timed.first(where: { $0.start <= now && $0.end > now }) {
            let after = day.timed.first { $0.start >= current.end }
            let note = after.flatMap { weatherNote(at: $0.start) }.map { " \($0)" } ?? ""
            return (String(localized: "Adesso: \(current.title)"), String(localized: "Fino alle \(clock(current.end))\(current.location.map { " · \($0)" } ?? "").\(note)"))
        }
        if let next = day.timed.first(where: { $0.start > now }) {
            let others = day.timed.filter { $0.start > next.start }.count
            let after = others == 0 ? String(localized: "Poi sei libero.") : String(localized: "Poi \(others == 1 ? String(localized: "un altro impegno") : String(localized: "altri \(others) impegni")).")
            let minutes = Int(next.start.timeIntervalSince(now) / 60)
            let when = minutes < 60 ? String(localized: "tra \(max(1, minutes)) minuti") : String(localized: "alle \(clock(next.start))")
            let note = weatherNote(at: next.start).map { " \($0)" } ?? ""
            return (String(localized: "Prossimo: \(next.title)"), String(localized: "Inizia \(when)\(next.location.map { " · \($0)" } ?? ""). \(after)\(note)"))
        }
        if day.events.isEmpty { return (String(localized: "Giornata libera"), String(localized: "Nessun impegno in calendario.\(weatherLine) \(tomorrow)")) }
        return (String(localized: "Impegni finiti"), String(localized: "Hai concluso quelli di oggi.\(weatherLine) \(tomorrow)"))
    }

    private var todoInsight: (title: String, detail: String) {
        guard enabled(.reminders) else { return (String(localized: "Da fare"), String(localized: "Collega i Promemoria per vedere qui cosa scade oggi.")) }
        let overdue = day.overdue(now: now)
        let today = day.dueToday(now: now)
        if let oldest = overdue.first {
            let count = overdue.count
            return (count == 1 ? String(localized: "Un promemoria scaduto") : String(localized: "\(count) promemoria scaduti"),
                    String(localized: "Il più vecchio è «\(oldest.title)», \(oldest.due.map { Dates.friendly($0, time: oldest.dueHasTime) } ?? "")."))
        }
        if let first = today.first {
            let done = day.completedToday > 0 ? String(localized: "Ne hai già completati \(day.completedToday). ") : ""
            return (today.count == 1 ? String(localized: "Una cosa da fare oggi") : String(localized: "\(today.count) cose da fare oggi"),
                    String(localized: "\(done)Si parte da «\(first.title)»\(first.dueHasTime ? String(localized: " alle \(first.due!.formatted(.dateTime.hour().minute().locale(Dates.locale)))") : "")."))
        }
        let upcoming = day.week(now: now).dropFirst().reduce(0) { $0 + $1.count }
        return (String(localized: "Niente in scadenza"), upcoming == 0 ? String(localized: "Oggi e nei prossimi giorni non hai promemoria in scadenza.") : String(localized: "Nei prossimi sei giorni ne scadono \(upcoming)."))
    }

    private var agentsInsight: (title: String, detail: String) {
        let agents = state.spaceAgents
        guard !agents.isEmpty else {
            return (String(localized: "Nessun Genius"), String(localized: "Un Genius lavora quando vuoi tu: controlla la posta, prepara la giornata, tiene in ordine un progetto."))
        }
        if let waiting = agents.first(where: { state.pendingApprovals(for: $0) > 0 }) {
            let total = agents.reduce(0) { $0 + state.pendingApprovals(for: $1) }
            return (total == 1 ? String(localized: "Un'azione aspetta te") : String(localized: "\(total) azioni aspettano te"), String(localized: "\(waiting.displayName) ha preparato qualcosa da approvare."))
        }
        if let running = agents.first(where: { state.runningAgents.contains($0.id) }) {
            return (String(localized: "\(running.displayName) è al lavoro"), running.goal)
        }
        if let next = agents.compactMap({ agent in agent.nextRun.map { (agent, $0) } }).min(by: { $0.1 < $1.1 }) {
            return (String(localized: "Prossimo lavoro \(Dates.friendly(next.1))"), "\(next.0.displayName): \(next.0.goal)")
        }
        return (String(localized: "Genius in pausa"), String(localized: "Nessuna programmazione attiva. Riattiva un Genius o avvialo quando ti serve."))
    }

    @ViewBuilder
    private var heroPanel: some View {
        switch focus {
        case .meteo: weatherPanel
        case .oggi: dayPanel
        case .daFare: todoPanel
        case .agenti: agentsPanel
        }
    }

    @ViewBuilder
    private var weatherPanel: some View {
        if let snapshot = state.weather.snapshot {
            PanelLabel(text: String(localized: "Previsioni orarie"), symbol: "clock")
            HourlyStrip(hours: snapshot.upcoming(from: state.weather.demoNow ?? now, count: 13))
            Divider().overlay(.white.opacity(0.12))
            let sunEvent = sunMetric(snapshot)
            MetricsGrid(metrics: [
                DashMetric(label: String(localized: "Percepita"), value: WeatherSnapshot.degrees(snapshot.apparent),
                           note: snapshot.apparent < snapshot.temperature - 1 ? String(localized: "più fresco") : (snapshot.apparent > snapshot.temperature + 1 ? String(localized: "più caldo") : String(localized: "come l'aria")), tint: .orange),
                DashMetric(label: String(localized: "Vento"), value: String(localized: "\(Int(snapshot.windSpeed.rounded())) km/h"), note: windNote(snapshot.windSpeed), tint: .teal),
                DashMetric(label: String(localized: "Umidità"), value: "\(snapshot.humidity)%", note: snapshot.humidity >= 80 ? String(localized: "aria umida") : String(localized: "nella norma"), tint: Color(red: 0.4, green: 0.7, blue: 1)),
                DashMetric(label: sunEvent.label, value: sunEvent.value, note: sunEvent.note, tint: .pink),
            ])
            Text("Previsioni di Open-Meteo").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        } else {
            PanelLabel(text: String(localized: "Previsioni orarie"), symbol: "clock")
            Text("Le previsioni compariranno appena il Mac si collega al servizio meteo.").font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }

    private func sunMetric(_ snapshot: WeatherSnapshot) -> (label: String, value: String, note: String?) {
        let clock = { (date: Date) in date.formatted(.dateTime.hour().minute().locale(Dates.locale)) }
        let reference = state.weather.demoNow ?? now
        if let sunset = snapshot.today?.sunset, reference < sunset, let sunrise = snapshot.today?.sunrise, reference > sunrise {
            return (String(localized: "Tramonto"), clock(sunset), snapshot.today?.uvMax.map { String(localized: "UV massimo \(Int($0.rounded()))") })
        }
        if let sunrise = snapshot.tomorrow?.sunrise ?? snapshot.today?.sunrise {
            return (String(localized: "Alba"), clock(sunrise), "domani")
        }
        return (String(localized: "Alba"), "--", nil)
    }

    private func windNote(_ speed: Double) -> String {
        switch speed {
        case ..<6: "calma"
        case ..<20: "brezza"
        case ..<39: String(localized: "vento moderato")
        default: String(localized: "vento forte")
        }
    }

    @ViewBuilder
    private var dayPanel: some View {
        PanelLabel(text: String(localized: "La giornata ora per ora"), symbol: "calendar")
        BusyChart(events: day.timed, now: now)
        Divider().overlay(.white.opacity(0.12))
        let busy = day.busyMinutes
        let free = day.freeFrom(now: now)
        MetricsGrid(metrics: [
            DashMetric(label: String(localized: "Impegni"), value: "\(day.events.count)", note: day.allDay.isEmpty ? "oggi" : String(localized: "\(day.allDay.count) tutto il giorno"),
                       tint: .red, action: { state.section = .app(.calendar) }),
            DashMetric(label: String(localized: "Occupato"), value: busy == 0 ? String(localized: "0 min") : (busy >= 60 ? "\(busy / 60) h \(busy % 60 > 0 ? String(localized: "\(busy % 60) min") : "")" : String(localized: "\(busy) min")),
                       note: String(localized: "in calendario"), tint: .orange),
            DashMetric(label: String(localized: "Libero"), value: free.map { $0 <= now ? String(localized: "Adesso") : $0.formatted(.dateTime.hour().minute().locale(Dates.locale)) } ?? String(localized: "Domani"),
                       note: free.map { $0 <= now ? String(localized: "fino al prossimo impegno") : String(localized: "dopo gli impegni") }, tint: .green),
            DashMetric(label: String(localized: "Domani"), value: "\(day.tomorrowCount)", note: day.tomorrowCount == 1 ? "impegno" : "impegni", tint: Color(red: 0.4, green: 0.7, blue: 1)),
        ])
    }

    @ViewBuilder
    private var todoPanel: some View {
        PanelLabel(text: String(localized: "Prossimi sette giorni"), symbol: "checklist")
        WeekBars(days: day.week(now: now))
        Divider().overlay(.white.opacity(0.12))
        MetricsGrid(metrics: [
            DashMetric(label: String(localized: "Oggi"), value: "\(day.dueToday(now: now).count)", note: String(localized: "in scadenza"), tint: .orange, action: { state.section = .app(.reminders) }),
            DashMetric(label: String(localized: "Scaduti"), value: "\(day.overdue(now: now).count)", note: String(localized: "da recuperare"), tint: day.overdue(now: now).isEmpty ? .secondary : .red),
            DashMetric(label: String(localized: "Completati"), value: "\(day.completedToday + completing.count)", note: "oggi", tint: .green),
            DashMetric(label: String(localized: "Senza data"), value: "\(day.undated)", note: String(localized: "in lista"), tint: .gray),
        ])
    }

    @ViewBuilder
    private var agentsPanel: some View {
        let agents = state.spaceAgents
        let since = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now)) ?? now
        let runs = agents.flatMap { agent in agent.history.filter { $0.start >= since }.map { (date: $0.start, outcome: $0.outcome) } }
        PanelLabel(text: String(localized: "Esecuzioni degli ultimi sette giorni"), symbol: "clock.arrow.circlepath")
        RunsChart(runs: runs)
        Divider().overlay(.white.opacity(0.12))
        let pending = agents.reduce(0) { $0 + state.pendingApprovals(for: $1) }
        let next = agents.compactMap(\.nextRun).min()
        MetricsGrid(metrics: [
            DashMetric(label: String(localized: "Attivi"), value: "\(agents.filter(\.active).count)", note: String(localized: "su \(agents.count)"), tint: .purple, action: { state.section = .agents }),
            DashMetric(label: String(localized: "Da approvare"), value: "\(pending)", note: pending == 0 ? String(localized: "niente in attesa") : String(localized: "nella chat"), tint: pending > 0 ? .orange : .secondary,
                       action: pending > 0 ? { state.section = .schedule } : nil),
            DashMetric(label: String(localized: "Esecuzioni"), value: "\(runs.count)", note: String(localized: "in sette giorni"), tint: Color(red: 0.4, green: 0.7, blue: 1), action: { state.section = .schedule }),
            DashMetric(label: String(localized: "Prossima"), value: next.map { $0.formatted(.dateTime.hour().minute().locale(Dates.locale)) } ?? "—",
                       note: next.map { Dates.friendly($0, time: false) } ?? "nessuna", tint: .teal),
        ])
        if agents.isEmpty {
            Button { state.startGeniusCreation() } label: { Label("Nuovo Genius", systemImage: "plus") }
                .buttonStyle(.glass)
        }
    }

    // MARK: Suggerimenti

    private var ideaList: [(symbol: String, text: String)] {
        let city = state.weather.city
        var ideas: [(String, String)]
        switch state.space {
        case .personale:
            ideas = [
                ("cart", String(localized: "Crea una nota con la lista della spesa")),
                ("sun.max", String(localized: "Idee per il weekend vicino a \(city)")),
                ("message", String(localized: "Cosa mi hanno scritto oggi nei messaggi?")),
                ("gift", String(localized: "Ricordami i compleanni di questa settimana")),
                ("fork.knife", String(localized: "Una ricetta veloce con quello che ho in frigo")),
            ]
        default:
            ideas = [
                ("calendar", String(localized: "Organizza la mia giornata")),
                ("envelope", String(localized: "Riassumi le email non lette")),
                ("globe", String(localized: "Quali sono le notizie di oggi?")),
                ("doc.text", String(localized: "Scrivi una relazione sul lancio del prodotto")),
                ("photo", String(localized: "Genera un'immagine di un faro al tramonto")),
            ]
        }
        if let snapshot = state.weather.snapshot, snapshot.condition.isWet || snapshot.upcoming(count: 12).contains(where: { $0.precipitationChance >= 50 }) {
            ideas.insert(("umbrella", String(localized: "Cosa posso fare a \(city) se piove?")), at: 1)
        } else if Calendar.current.component(.hour, from: now) >= 17 {
            ideas.insert(("moon.stars", String(localized: "Prepara la mia giornata di domani")), at: 1)
        }
        return ideas
    }

    private var ideas: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chiedi a Siri AI+").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
            GlassEffectContainer(spacing: 10) {
                FlowLayout(spacing: 8) {
                    ForEach(ideaList, id: \.text) { idea in
                        Button { state.input = idea.text } label: {
                            Label(idea.text, systemImage: idea.symbol)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
            }
        }
    }

    // MARK: Schede

    private var cards: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("La tua giornata").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                calendarCard
                remindersCard
                if !state.spaceAgents.isEmpty { agentsCard }
                if state.space == .lavoro || !state.sortedProjects.isEmpty { projectsCard }
                createCard
                if !state.allArtifacts.isEmpty { documentsCard }
            }
        }
    }

    private var calendarCard: some View {
        DashCard(title: String(localized: "Calendario"), symbol: "calendar", tint: .red,
                 trailing: day.events.isEmpty ? nil : String(localized: "\(day.events.count) oggi"), action: { state.section = .app(.calendar) }) {
            if !enabled(.calendar) {
                Button("Collega il Calendario") { state.section = .app(.calendar) }.buttonStyle(.glass)
            } else if day.events.isEmpty {
                emptyLine(String(localized: "Nessun impegno oggi."), symbol: "sun.max")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(day.events.prefix(5)) { event in eventRow(event) }
                }
            }
        }
    }

    private func eventRow(_ event: EventItem) -> some View {
        let live = event.start <= now && event.end > now && !event.isAllDay
        let past = event.end <= now && !event.isAllDay
        return HStack(spacing: 10) {
            Capsule().fill(Color(event.color)).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(event.isAllDay ? String(localized: "Tutto il giorno") : String(localized: "\(event.start.formatted(.dateTime.hour().minute().locale(Dates.locale))) – \(event.end.formatted(.dateTime.hour().minute().locale(Dates.locale)))\(event.location.map { " · \($0)" } ?? "")"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if live {
                Text("ORA").font(.system(size: 10, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 3)
                    .glassEffect(.regular.tint(.red.opacity(0.7)), in: .capsule)
            }
        }
        .opacity(past ? 0.5 : 1)
    }

    private var remindersCard: some View {
        let items = (day.overdue(now: now) + day.dueToday(now: now))
        let shown = items.isEmpty ? Array(day.reminders.filter { $0.due != nil }.prefix(4)) : Array(items.prefix(5))
        return DashCard(title: String(localized: "Promemoria"), symbol: "checklist", tint: .orange,
                        trailing: items.isEmpty ? nil : String(localized: "\(items.count) oggi"), action: { state.section = .app(.reminders) }) {
            if !enabled(.reminders) {
                Button("Collega i Promemoria") { state.section = .app(.reminders) }.buttonStyle(.glass)
            } else if shown.isEmpty {
                emptyLine(String(localized: "Niente da fare. Goditi la giornata."), symbol: "checkmark.circle")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if items.isEmpty { Text("In arrivo").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
                    ForEach(shown) { reminder in reminderRow(reminder) }
                }
            }
        }
    }

    private func reminderRow(_ reminder: ReminderItem) -> some View {
        let done = completing.contains(reminder.id)
        let overdue = day.isOverdue(reminder, now: now)
        return HStack(spacing: 10) {
            Button { toggle(reminder) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(done ? Color.green : Color(reminder.color))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(done ? String(localized: "Segna come da fare") : String(localized: "Segna come completato"))
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title).font(.system(size: 14, weight: .medium)).lineLimit(1).strikethrough(done)
                if let due = reminder.due {
                    Text(Dates.friendly(due, time: reminder.dueHasTime)).font(.system(size: 12))
                        .foregroundStyle(overdue && !done ? Color.red : Color.secondary)
                }
            }
            Spacer(minLength: 0)
            if reminder.highPriority { Image(systemName: "exclamationmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.orange) }
        }
        .opacity(done ? 0.55 : 1)
    }

    private var agentsCard: some View {
        DashCard(title: String(localized: "Genius"), symbol: "person.2.fill", tint: .purple, action: { state.section = .agents }) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(state.spaceAgents.prefix(4)) { agent in
                    Button { state.openAgent(agent.id) } label: {
                        HStack(spacing: 10) {
                            AgentAvatar(agent: agent, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(agentStatus(agent)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if state.runningAgents.contains(agent.id) { ProgressView().controlSize(.small) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func agentStatus(_ agent: AgentSpec) -> String {
        if state.runningAgents.contains(agent.id) { return String(localized: "Al lavoro…") }
        let pending = state.pendingApprovals(for: agent)
        if pending > 0 { return String(localized: "\(pending) da approvare") }
        if !agent.active { return String(localized: "In pausa") }
        if let next = agent.nextRun { return String(localized: "Prossima: \(Dates.friendly(next))") }
        return agent.history.last.map { String(localized: "Ultima: \(Dates.friendly($0.start))") } ?? String(localized: "Quando lo avvii")
    }

    private var projectsCard: some View {
        DashCard(title: String(localized: "Progetti"), symbol: "folder.fill", tint: Color(red: 0.4, green: 0.7, blue: 1)) {
            if state.sortedProjects.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Collega una cartella per lavorare con AGENTS.md, memoria e task dedicate.").font(.system(size: 13)).foregroundStyle(.secondary)
                    Button("Nuovo progetto…") { ProjectPicker.choose { state.addProject(folder: $0) } }.buttonStyle(.glass)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(state.sortedProjects.prefix(4)) { project in
                        Button { state.openProject(project) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: project.pinned ? "pin.fill" : "folder.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(project.pinned ? Color.orange : Color(red: 0.4, green: 0.7, blue: 1))
                                    .frame(width: 32, height: 32)
                                    .glassEffect(.regular, in: .rect(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(project.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                    Text("\(state.tasks(for: project).count) task · \(project.lastOpened.formatted(.relative(presentation: .named).locale(Dates.locale)))")
                                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var createCard: some View {
        DashCard(title: String(localized: "Crea"), symbol: "sparkles", tint: .pink) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(ArtifactKind.allCases, id: \.self) { kind in
                    Button { state.newArtifact(kind) } label: {
                        HStack(spacing: 10) {
                            Tile(kind, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.app).font(.system(size: 14, weight: .semibold))
                                Text("Nuov\(kind.ending) \(kind.noun.lowercased())").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var documentsCard: some View {
        DashCard(title: String(localized: "Documenti recenti"), symbol: "doc.richtext.fill", tint: .yellow) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(state.allArtifacts.prefix(4)) { artifact in
                    Button { state.open(artifact) } label: {
                        HStack(spacing: 10) {
                            Tile(artifact.kind, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(artifact.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text("\(artifact.kind.noun) · \(artifact.stateLabel)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func emptyLine(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 14)).foregroundStyle(.secondary)
    }
}

/// Nome dell'utente del Mac (per il saluto).
extension HomeDashboard {
    static var firstName: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName() }
}

struct EmptyHint: View {
    let symbol: String
    let text: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(text).font(DS.Fonts.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let action { Button(action.0, action: action.1) }
        }
        .padding(16)
        .glassCard(radius: 24)
    }
}
