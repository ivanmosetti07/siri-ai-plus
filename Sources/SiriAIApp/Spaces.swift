import SiriCore
import SwiftUI

/// Gli spazi di Siri AI+: ognuno ha la sua vista, i suoi calendari, la sua posta, i suoi connettori e (se vuoi) il suo modello.
enum Space: String, Codable, CaseIterable, Identifiable {
    case personale, lavoro
    /// Spazio di coding per creare app e siti (il valore salvato resta «programmazioni» per le conversazioni esistenti).
    case codice = "programmazioni"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .personale: "Personale"
        case .lavoro: "Lavoro"
        case .codice: "Programmazione"
        }
    }

    var symbol: String {
        switch self {
        case .personale: "person.fill"
        case .lavoro: "briefcase.fill"
        case .codice: "chevron.left.forwardslash.chevron.right"
        }
    }

    var tint: Color {
        switch self {
        case .personale: .green
        case .lavoro: .blue
        case .codice: .purple
        }
    }

    var subtitle: String {
        switch self {
        case .personale: "Vita privata: famiglia, casa, tempo libero, messaggi"
        case .lavoro: "Progetti, clienti, connettori e documenti"
        case .codice: "App e siti con Codex"
        }
    }
}

/// Impostazioni di uno spazio (nil = nessun filtro).
struct SpaceSettings: Codable, Equatable {
    var calendars: [String]?
    var defaultCalendar: String?
    var reminderLists: [String]?
    var defaultReminderList: String?
    var mailAccount: String?
    var connectorIDs: [UUID]?
    var instructions = ""
    var provider: String?
    /// Versione e ragionamento dell'ultimo modello scelto in questo spazio (valgono per le chat nuove).
    var model: String?
    var effort: String?
}

// MARK: - Selettore nella barra laterale

struct SpaceSwitcher: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Space.allCases) { space in
                let selected = state.space == space
                Button {
                    state.switchSpace(space)
                } label: {
                    Image(systemName: space.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .frame(width: 28, height: 22)
                        .background {
                            if selected {
                                Capsule().fill(space.tint.gradient)
                                    .shadow(color: space.tint.opacity(0.35), radius: 3, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(space.label) — \(space.subtitle)")
                .accessibilityLabel("Spazio \(space.label)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .animation(.smooth(duration: 0.25), value: state.space)
        .contextMenu {
            Button("Impostazioni degli spazi…") { state.openSettings("spazi") }
        }
    }
}

// MARK: - Programmazioni

/// Una prossima esecuzione di un agente (o il suo sogno).
private struct Occurrence: Identifiable {
    let id = UUID()
    let date: Date
    let agent: AgentSpec
    let routineID: UUID?
    let text: String
    let isDream: Bool
}

/// Centro di controllo di tutto ciò che è programmato: prossime esecuzioni, approvazioni, programmazioni e ultimi risultati.
/// Le programmazioni ora stanno nella sezione Agenti (pillola «Programmazioni»).
struct ScheduleCenterView: View {
    var body: some View { AgentsGallery(initialTab: "programmazioni") }
}

/// Programmazioni degli agenti: riepilogo, approvazioni, prossimi 7 giorni, tutte le programmazioni.
struct ScheduleContent: View {
    @Environment(AppState.self) private var state

    private var occurrences: [Occurrence] {
        let now = Date.now
        let limit = now.addingTimeInterval(7 * 86_400)
        var items: [Occurrence] = []
        for agent in state.agents where agent.active {
            for routine in agent.routines where routine.enabled && routine.schedule.kind != .manuale {
                var date = routine.nextRun ?? routine.schedule.next(after: now)
                var count = 0
                // Le programmazioni frequenti si mostrano al massimo 6 volte.
                while let current = date, current <= limit, count < 6 {
                    items.append(Occurrence(date: current, agent: agent, routineID: routine.id,
                                            text: routine.task.isEmpty ? agent.goal : routine.task, isDream: false))
                    date = routine.schedule.next(after: current)
                    count += 1
                }
            }
            if agent.dreamsEnabled {
                var day = Calendar.current.startOfDay(for: now)
                for _ in 0..<7 {
                    if let dream = Calendar.current.date(bySettingHour: agent.dreamHour, minute: 0, second: 0, of: day), dream > now {
                        items.append(Occurrence(date: dream, agent: agent, routineID: nil, text: "Sogno: rilegge la giornata e si migliora", isDream: true))
                    }
                    day = Calendar.current.date(byAdding: .day, value: 1, to: day)!
                }
            }
        }
        return items.sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            header
            approvals
            upcoming
            allRoutines
        }
    }

    private var header: some View {
        let active = state.agents.filter(\.active)
        let routines = state.agents.flatMap(\.routines).filter { $0.enabled && $0.schedule.kind != .manuale }
        let pending = state.agents.reduce(0) { $0 + state.pendingApprovals(for: $1) }
        return GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                PanelLabel(text: "Tutto ciò che fanno da soli", symbol: "calendar.badge.clock")
                MetricsGrid(metrics: [
                    DashMetric(label: "Agenti attivi", value: "\(active.count)", note: "su \(state.agents.count)", tint: .purple),
                    DashMetric(label: "Programmazioni", value: "\(routines.count)", note: "attive", tint: Color(red: 0.4, green: 0.7, blue: 1)),
                    DashMetric(label: "Prossima", value: occurrences.first.map { $0.date.formatted(.dateTime.hour().minute()) } ?? "—",
                               note: occurrences.first.map { Dates.friendly($0.date, time: false) } ?? "niente in programma", tint: .teal),
                    DashMetric(label: "Da approvare", value: "\(pending)", note: pending == 0 ? "niente in attesa" : "nelle chat degli agenti", tint: pending > 0 ? .orange : .secondary),
                ])
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded))
            Text(label).font(DS.Fonts.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 20)
    }

    @ViewBuilder
    private var approvals: some View {
        let waiting = state.agents.filter { state.pendingApprovals(for: $0) > 0 }
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Da approvare", systemImage: "hand.raised.fill").font(DS.Fonts.section).foregroundStyle(.orange)
                ForEach(waiting) { agent in
                    HStack(spacing: 12) {
                        AgentAvatar(agent: agent, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent.displayName).font(DS.Fonts.bodyStrong)
                            Text("\(state.pendingApprovals(for: agent)) azioni aspettano la tua conferma").font(DS.Fonts.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Approva tutte") {
                            let count = state.approveAll(for: agent.id)
                            state.showToast(count == 0 ? "Restano da confermare una per una (email, messaggi o connettori)" : "\(count) azioni approvate")
                        }
                        .help("Approva eventi, promemoria, note e file in attesa. Email, messaggi e connettori restano da confermare uno per uno.")
                        Button("Rivedi") { state.openAgent(agent.id) }.buttonStyle(.borderedProminent).tint(.orange)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prossimi 7 giorni").font(DS.Fonts.section)
            if occurrences.isEmpty {
                EmptyHint(symbol: "calendar.badge.plus", text: "Niente in programma. Crea un agente con una programmazione per far lavorare Siri AI+ da sola.",
                          action: ("Nuovo agente…", { state.editingAgent = AgentSpec(name: "", goal: "") }))
            } else {
                let days = Dictionary(grouping: occurrences.prefix(60)) { Calendar.current.startOfDay(for: $0.date) }
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(days.keys.sorted(), id: \.self) { day in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(dayTitle(day)).font(DS.Fonts.captionStrong).foregroundStyle(.secondary).textCase(.uppercase)
                            VStack(spacing: 0) {
                                ForEach(days[day] ?? []) { item in
                                    occurrenceRow(item)
                                    if item.id != days[day]?.last?.id { Divider().padding(.leading, 104) }
                                }
                            }
                            .glassCard(radius: 18)
                        }
                    }
                }
            }
        }
    }

    private func occurrenceRow(_ item: Occurrence) -> some View {
        HStack(spacing: 12) {
            Text(item.date.formatted(.dateTime.hour().minute())).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .frame(width: 48, alignment: .trailing)
            ZStack(alignment: .bottomTrailing) {
                AgentAvatar(agent: item.agent, size: 28)
                if item.isDream {
                    Image(systemName: "moon.stars.fill").font(.system(size: 9)).foregroundStyle(.white)
                        .frame(width: 15, height: 15).background(Color.purple, in: Circle())
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.agent.displayName).font(DS.Fonts.bodyStrong).lineLimit(1)
                Text(item.text).font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !item.isDream {
                Button { state.runAgent(item.agent.id, routine: item.routineID) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless).iconHelp("Esegui ora").disabled(state.runningAgents.contains(item.agent.id))
            }
            Button { state.openAgent(item.agent.id) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Oggi" }
        if Calendar.current.isDateInTomorrow(day) { return "Domani" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Dates.locale))
    }

    @ViewBuilder
    private var allRoutines: some View {
        if !state.agents.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Agenti e programmazioni").font(DS.Fonts.section)
                ForEach(state.agents) { agent in
                    HStack(alignment: .top, spacing: 12) {
                        AgentAvatar(agent: agent, size: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(agent.displayName).font(DS.Fonts.bodyStrong)
                                Text(Space(rawValue: agent.space)?.label ?? "").font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 1)
                                    .background((Space(rawValue: agent.space)?.tint ?? .gray).gradient, in: Capsule())
                                Spacer()
                                Toggle("", isOn: Binding(get: { agent.active }, set: { _ in state.toggleActive(agent.id) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                            if agent.routines.isEmpty {
                                Text("Solo quando lo avvii").font(DS.Fonts.caption).foregroundStyle(.secondary)
                            }
                            ForEach(agent.routines) { routine in
                                HStack(spacing: 8) {
                                    Image(systemName: routine.enabled ? "clock.fill" : "clock").foregroundStyle(routine.enabled ? agent.tint : .secondary).font(.system(size: 11))
                                    Text(routine.schedule.label).font(DS.Fonts.caption)
                                    if !routine.task.isEmpty { Text("· \(routine.task)").font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                            }
                        }
                    }
                    .padding(14)
                    .glassCard(radius: 18)
                    .onTapGesture { state.openAgent(agent.id) }
                }
            }
        }
    }

}

// MARK: - Impostazioni degli spazi

struct SpacesSettings: View {
    @Environment(AppState.self) private var state
    @State private var editing = Space.lavoro
    @State private var accounts = [String]()
    var body: some View {
        let space = editing
        let settings = state.settings(for: space)
        VStack(alignment: .leading, spacing: 18) {
            Text("Ogni spazio ha i suoi calendari, la sua posta, i suoi connettori, le sue indicazioni e, se vuoi, il suo modello. Le Programmazioni usano calendari e posta di Lavoro.")
                .font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Spazio", selection: $editing) {
                ForEach(Space.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if space != .codice {
                group("Calendari") {
                    choices(all: EventKitService.allWritableCalendars(), selected: settings.calendars) { value in
                        state.updateSpace(space) { $0.calendars = value }
                    }
                    Picker("Calendario per i nuovi eventi", selection: Binding(get: { settings.defaultCalendar ?? "" },
                                                                               set: { value in state.updateSpace(space) { $0.defaultCalendar = value.isEmpty ? nil : value } })) {
                        Text("Predefinito del Mac").tag("")
                        ForEach(settings.calendars ?? EventKitService.allWritableCalendars(), id: \.self) { Text($0).tag($0) }
                    }
                }
                group("Promemoria") {
                    choices(all: EventKitService.allReminderLists(), selected: settings.reminderLists) { value in
                        state.updateSpace(space) { $0.reminderLists = value }
                    }
                    Picker("Lista per i nuovi promemoria", selection: Binding(get: { settings.defaultReminderList ?? "" },
                                                                              set: { value in state.updateSpace(space) { $0.defaultReminderList = value.isEmpty ? nil : value } })) {
                        Text("Predefinita del Mac").tag("")
                        ForEach(settings.reminderLists ?? EventKitService.allReminderLists(), id: \.self) { Text($0).tag($0) }
                    }
                }
                group("Email") {
                    Picker("Account da leggere", selection: Binding(get: { settings.mailAccount ?? "" },
                                                                    set: { value in state.updateSpace(space) { $0.mailAccount = value.isEmpty ? nil : value } })) {
                        Text("Tutti (posta in arrivo unificata)").tag("")
                        ForEach(Array(Set(accounts + [settings.mailAccount].compactMap { $0 })).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    if accounts.isEmpty {
                        Text("Gli account compaiono dopo aver dato a Siri AI+ il permesso di usare Mail.").font(DS.Fonts.caption).foregroundStyle(.secondary)
                    }
                }
            }
            group("Connettori") {
                if state.mcp.servers.isEmpty {
                    Text("Nessun connettore configurato.").font(DS.Fonts.body).foregroundStyle(.secondary)
                } else {
                    Toggle("Usa tutti i connettori attivi", isOn: Binding(get: { settings.connectorIDs == nil }, set: { all in
                        state.updateSpace(space) { $0.connectorIDs = all ? nil : state.mcp.servers.map(\.id) }
                    }))
                    ForEach(state.mcp.servers) { server in
                        Toggle(server.name, isOn: Binding(get: { state.spaceUses(server.id, in: space) }, set: { use in
                            state.updateSpace(space) { settings in
                                var ids = Set(settings.connectorIDs ?? state.mcp.servers.map(\.id))
                                if use { ids.insert(server.id) } else { ids.remove(server.id) }
                                settings.connectorIDs = Array(ids)
                            }
                        }))
                        .disabled(settings.connectorIDs == nil)
                        .padding(.leading, 18)
                    }
                }
            }
            group("Modello per le risposte") {
                Picker("Modello", selection: Binding(get: { settings.provider ?? "" }, set: { value in
                    state.updateSpace(space) { $0.provider = value.isEmpty ? nil : value; $0.model = nil; $0.effort = nil }
                })) {
                    Text("Quello generale (\(state.defaultProvider.label))").tag("")
                    ForEach(ResponseProvider.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            group("Indicazioni per questo spazio") {
                TextField("Es. «Nel lavoro dammi del lei nelle email e firma Mainstream Agency»", text: Binding(
                    get: { settings.instructions }, set: { value in state.updateSpace(space) { $0.instructions = value } }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
            }
        }
        .task {
            editing = state.space
            accounts = await MailReader.accounts()
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(DS.Fonts.captionStrong).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(radius: 24)
        }
    }

    /// «Tutti» oppure una scelta puntuale.
    @ViewBuilder
    private func choices(all: [String], selected: [String]?, update: @escaping ([String]?) -> Void) -> some View {
        Toggle("Tutti", isOn: Binding(get: { selected == nil }, set: { everything in update(everything ? nil : all) }))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(all, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { selected?.contains(name) ?? true }, set: { on in
                    var set = Set(selected ?? all)
                    if on { set.insert(name) } else { set.remove(name) }
                    update(Array(set))
                }))
                .toggleStyle(.checkbox)
                .disabled(selected == nil)
            }
        }
        .padding(.leading, 18)
    }
}
