import ImagePlayground
import SiriCore
import SwiftUI

extension AgentSpec {
    var tint: Color { Self.tint(named: color) }

    static func tint(named color: String) -> Color {
        switch color {
        case "blue": .blue
        case "teal": .teal
        case "green": .green
        case "orange": .orange
        case "red": .red
        case "pink": .pink
        case "purple": .purple
        case "gray": .gray
        default: .indigo
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Idee di partenza, come la galleria di Comandi rapidi.
struct AgentTemplate: Identifiable {
    let id = UUID()
    let person: String
    let name: String
    let goal: String
    let symbol: String
    let color: String
    let schedule: AgentSchedule
    var connectors = false

    static let all: [AgentTemplate] = [
        AgentTemplate(person: String(localized: "Giulia"), name: String(localized: "Rassegna stampa"), goal: String(localized: "Cerca le notizie più importanti su intelligenza artificiale e marketing digitale e riassumile in 5 punti con le fonti."),
                      symbol: "newspaper.fill", color: "orange", schedule: AgentSchedule(kind: .giornaliero, hour: 8)),
        AgentTemplate(person: String(localized: "Marco"), name: String(localized: "Posta in ordine"), goal: String(localized: "Leggi le email non lette, dimmi a quali devo rispondere e prepara le bozze delle risposte più urgenti."),
                      symbol: "envelope.fill", color: "blue", schedule: AgentSchedule(kind: .giornaliero, hour: 18)),
        AgentTemplate(person: String(localized: "Sofia"), name: String(localized: "Settimana pronta"), goal: String(localized: "Guarda calendario e promemoria della settimana, segnala sovrapposizioni e prepara un piano con le priorità."),
                      symbol: "calendar", color: "red", schedule: AgentSchedule(kind: .settimanale, hour: 9, weekday: 2)),
        AgentTemplate(person: String(localized: "Luca"), name: String(localized: "Osservatore"), goal: String(localized: "Controlla le novità su un argomento che mi interessa e avvisami solo se cambia qualcosa di importante."),
                      symbol: "binoculars.fill", color: "teal", schedule: AgentSchedule(kind: .giornaliero, hour: 12)),
        AgentTemplate(person: String(localized: "Elena"), name: String(localized: "Obiettivo"), goal: String(localized: "Aiutami a raggiungere un obiettivo: prepara un piano concreto, dividilo in passi e fallo avanzare un po' ogni giorno."),
                      symbol: "target", color: "purple", schedule: AgentSchedule(kind: .giornaliero, hour: 9)),
        AgentTemplate(person: String(localized: "Davide"), name: String(localized: "Priorità agenzia"), goal: String(localized: "Controlla su Agency OS i task in scadenza e i clienti che richiedono attenzione e dimmi le priorità di oggi."),
                      symbol: "briefcase.fill", color: "indigo", schedule: AgentSchedule(kind: .giornaliero, hour: 8, minute: 30), connectors: true),
    ]

    var spec: AgentSpec {
        var spec = AgentSpec(name: name, goal: goal)
        spec.personName = person
        spec.symbol = symbol
        spec.color = color
        spec.routines = [AgentRoutine(schedule: schedule)]
        spec.allowConnectors = connectors
        return spec
    }
}

// MARK: - Tessera

struct AgentTile: View {
    @Environment(AppState.self) private var state
    let agent: AgentSpec
    var height: CGFloat = 134

    var body: some View {
        let running = state.runningAgents.contains(agent.id)
        let pending = state.pendingApprovals(for: agent)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(agent.gradient)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: agent.tint.opacity(0.25), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    AgentAvatar(agent: agent, size: 38, onTile: true)
                    Spacer()
                    if running {
                        ProgressView().controlSize(.small).tint(.white)
                    } else if pending > 0 {
                        Text("\(pending)").font(.system(size: 11, weight: .bold)).foregroundStyle(agent.tint)
                            .frame(minWidth: 20, minHeight: 20).background(.white, in: Capsule())
                            .help("\(pending) da approvare")
                    } else if !agent.active {
                        Image(systemName: "pause.circle.fill").foregroundStyle(.white.opacity(0.8))
                    }
                }
                Spacer(minLength: 6)
                Text(agent.personName.isEmpty ? agent.name : agent.personName).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if !agent.personName.isEmpty {
                    Text(agent.name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                }
                Text(running ? String(localized: "Al lavoro…") : agent.active ? agent.scheduleLabel : String(localized: "In pausa"))
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            }
            .padding(14)
        }
        .frame(height: height)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contextMenu {
            Button("Esegui ora") { state.runAgent(agent.id) }.disabled(running)
            Button(agent.active ? String(localized: "Metti in pausa") : String(localized: "Riattiva")) { state.toggleActive(agent.id) }
            Button("Modifica…") { state.editingAgent = agent }
            Divider()
            Button("Elimina Genius", role: .destructive) { state.deleteAgent(agent.id) }
        }
    }
}

// MARK: - Sezione Agenti

/// La sezione Agenti: i tuoi agenti, le loro programmazioni e lo storico di ciò che hanno fatto, con le pillole in alto.
struct AgentsGallery: View {
    var initialTab = "agenti"
    @Environment(AppState.self) private var state
    @State private var tab: String?
    @State private var description = ""
    @State private var working = false
    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 14)]

    var body: some View {
        let selected = tab ?? initialTab
        GlassPage(maxWidth: 980) {
            PageHeader(eyebrow: String(localized: "Lavorano per te"), title: String(localized: "Genius"),
                       subtitle: String(localized: "Dai un obiettivo a ogni Genius: prepara un piano, lavora anche quando non ci sei e torna da te quando serve una conferma.")) {
                Button { state.editingAgent = AgentSpec(name: "", goal: "") } label: { Label("Nuovo Genius", systemImage: "plus") }
                    .buttonStyle(.glassProminent)
            }
            describeField
            GlassPills(items: pills, selection: Binding(get: { selected }, set: { tab = $0 }))
            Group {
                switch selected {
                case "programmazioni": ScheduleContent()
                case "storico":
                    RunHistoryView(items: HistoryItem.items(for: state.spaceAgents, dreams: true), showAgent: true,
                                   emptyText: String(localized: "Nessuna esecuzione finora. Qui trovi ogni lavoro fatto dai Genius, programmato o avviato da te, con il suo esito."))
                default: agentsTab
                }
            }
            .id(selected)
            .transition(.blurReplace)
        }
    }

    private var pills: [GlassPill] {
        let pending = state.spaceAgents.reduce(0) { $0 + state.pendingApprovals(for: $1) }
        let next = state.spaceAgents.compactMap(\.nextRun).min()
        let since = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: .now)) ?? .now
        let runs = state.spaceAgents.reduce(0) { $0 + $1.history.filter { $0.start >= since }.count }
        return [
            GlassPill(id: "agenti", title: String(localized: "I tuoi Genius"), value: state.spaceAgents.isEmpty ? String(localized: "Nessuno") : String(localized: "\(state.spaceAgents.filter(\.active).count) attivi"),
                      symbol: "person.2.fill", colors: Hue.purple, badge: pending),
            GlassPill(id: "programmazioni", title: String(localized: "Programmazioni"), value: next.map { String(localized: "Prossima \($0.formatted(.dateTime.hour().minute()))") } ?? String(localized: "Nessuna"),
                      symbol: "calendar.badge.clock", colors: Hue.orange),
            GlassPill(id: "storico", title: String(localized: "Storico"), value: String(localized: "\(runs) in 7 giorni"), symbol: "clock.arrow.circlepath", colors: Hue.blue),
        ]
    }

    /// Crea un agente descrivendolo a parole, come si scrive a Siri AI+.
    private var describeField: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor)
            TextField("Descrivi un Genius: «ogni mattina alle 8 fammi la rassegna stampa sull'AI»", text: $description)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit(create)
            if working { ProgressView().controlSize(.small) }
            Button("Crea", action: create)
                .buttonStyle(.glassProminent)
                .disabled(description.trimmingCharacters(in: .whitespaces).isEmpty || working)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    @ViewBuilder
    private var agentsTab: some View {
        if state.spaceAgents.isEmpty {
            GlassEmptyState(symbol: "person.2.fill", title: String(localized: "Il tuo primo Genius"),
                            message: String(localized: "Scegli un'idea qui sotto o descrivi cosa vuoi: il Genius lavora agli orari che decidi tu e chiede conferma prima di scrivere o inviare."),
                            colors: Hue.purple, actionTitle: String(localized: "Nuovo Genius")) { state.editingAgent = AgentSpec(name: "", goal: "") }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                GroupTitle(text: String(localized: "I tuoi Genius"))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(state.spaceAgents) { agent in
                        Button { state.openAgent(agent.id) } label: { AgentTile(agent: agent) }.buttonStyle(.plain)
                    }
                    Button { state.editingAgent = AgentSpec(name: "", goal: "") } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
                            Text("Nuovo Genius").font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).frame(height: 134)
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                }
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            GroupTitle(text: String(localized: "Idee per iniziare"))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(AgentTemplate.all) { template in
                    Button { state.editingAgent = template.spec } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: template.symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 36, height: 36).background(template.spec.gradient, in: Circle())
                            Text("\(template.person) - \(template.name)").font(.system(size: 14, weight: .semibold))
                            Text(template.goal).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Text(template.schedule.label).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(template.spec.tint)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                }
            }
        }
    }

    private func create() {
        let text = description.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        working = true
        Task {
            state.editingAgent = await state.draftAgent(text)
            working = false
            description = ""
        }
    }
}

// MARK: - Pagina dell'agente

struct AgentDetailView: View {
    @Environment(AppState.self) private var state
    let agentID: UUID
    @State private var tab = 0
    @State private var newMemory = ""
    /// Sezioni del dettaglio: elenco a sinistra, come nelle Impostazioni di sistema.
    private static let sections: [(tag: Int, label: String, symbol: String)] = [
        (0, String(localized: "Attività"), "clock.arrow.circlepath"), (4, String(localized: "Programmazioni"), "calendar.badge.clock"),
        (1, String(localized: "Cronologia"), "clock"), (8, String(localized: "Skill"), "wand.and.stars"), (5, String(localized: "Cartelle"), "folder"),
        (6, String(localized: "Anima"), "heart.text.square"), (7, String(localized: "Sogni"), "moon.stars"), (2, String(localized: "Memoria"), "brain"), (3, String(localized: "Accessi"), "lock.shield"),
    ]

    var body: some View {
        if let agent = state.agent(agentID) {
            GlassPage(maxWidth: 900) {
                header(agent)
                GlassPills(items: Self.sections.map { section in
                    GlassPill(id: String(section.tag), title: section.label, symbol: section.symbol,
                              colors: Self.colors(section.tag), badge: badge(section.tag, agent))
                }, selection: Binding(get: { String(tab) }, set: { tab = Int($0) ?? 0 }))
                VStack(alignment: .leading, spacing: 22) {
                    content(agent)
                }
                .id(tab)
                .transition(.blurReplace)
            }
            .task(id: state.agentTabRequest) {
                // Nelle foto di prova la vista viene creata due volte: la richiesta resta valida.
                if let request = state.agentTabRequest {
                    tab = request
                    if !CommandLine.arguments.contains("--snapshot") { state.agentTabRequest = nil }
                }
            }
        } else {
            AgentsGallery()
        }
    }

    private static func colors(_ tag: Int) -> [Color] {
        switch tag {
        case 0: Hue.blue
        case 1: Hue.blue
        case 4: Hue.orange
        case 8: Hue.purple
        case 5: Hue.teal
        case 6: Hue.pink
        case 7: Hue.purple
        case 2: Hue.indigo
        default: Hue.gray
        }
    }

    private func badge(_ tag: Int, _ agent: AgentSpec) -> Int {
        _ = state.skillsRevision
        return switch tag {
        case 0: state.pendingApprovals(for: agent)
        case 4: agent.routines.filter(\.enabled).count
        case 8: SkillStore.forAgent(agent.id).count
        case 5: agent.folders.count
        default: 0
        }
    }

    @ViewBuilder
    private func content(_ agent: AgentSpec) -> some View {
                    switch tab {
                    case 0: activity(agent); lastWork(agent)
                    case 1:
                        RunHistoryView(items: HistoryItem.items(for: [agent], dreams: false),
                                       emptyText: String(localized: "Nessuna esecuzione finora. Qui troverai i lavori programmati e quelli avviati da te."),
                                       initialFilter: .programmate)
                    case 2: memory(agent)
                    case 4:
                        RoutinesEditor(routines: Binding(get: { state.agent(agentID)?.routines ?? [] },
                                                         set: { value in state.updateAgent(agentID) { $0.routines = value; $0.reschedule() } }),
                                       run: { routine in state.runAgent(agentID, routine: routine) })
                        Button { tab = 1 } label: { Label("Vedi cronologia", systemImage: "clock.arrow.circlepath") }
                            .buttonStyle(.link)
                    case 8: AgentSkillsView(agent: agent).id(agent.id)
                    case 5:
                        FoldersEditor(folders: Binding(get: { state.agent(agentID)?.folders ?? [] },
                                                       set: { value in state.updateAgent(agentID) { $0.folders = value } }))
                    case 6: SoulEditor(agent: agent).id(agent.id)
                    case 7: dreams(agent)
                    default: access(agent)
                    }
    }

    /// Intestazione dell'agente: ritratto nel vetro, nome grande, obiettivo, stato e azioni.
    private func header(_ agent: AgentSpec) -> some View {
        let running = state.runningAgents.contains(agent.id)
        return HStack(alignment: .center, spacing: 20) {
            PortraitButton(agentID: agent.id, size: 88)
                .padding(5)
                .glassEffect(.regular, in: .circle)
                .overlay {
                    if running {
                        Circle()
                            .trim(from: 0, to: 0.72)
                            .stroke(AngularGradient(colors: [agent.tint.opacity(0), agent.tint, .white], center: .center),
                                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                            .rotationEffect(.degrees(running ? 360 : 0))
                            .animation(.linear(duration: 1.6).repeatForever(autoreverses: false), value: running)
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                Text((running ? String(localized: "Al lavoro") : agent.active ? String(localized: "Attivo") : String(localized: "In pausa")).uppercased() + " · " + (Space(rawValue: agent.space)?.label.uppercased() ?? ""))
                    .font(.system(size: 13, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(running ? agent.tint : .secondary)
                Text(agent.displayName).font(.system(size: 30, weight: .bold)).tracking(-0.4).lineLimit(2)
                Text(agent.goal).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(3)
                HStack(spacing: 8) {
                    chip(agent.active ? agent.scheduleLabel : String(localized: "In pausa"), symbol: agent.active ? "clock" : "pause.circle")
                    if let next = agent.nextRun, agent.active { chip(String(localized: "Prossima \(Dates.friendly(next))"), symbol: "arrow.forward.circle") }
                    if let project = agent.projectName { chip(project, symbol: "folder") }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                if running {
                    Button(role: .destructive) { state.cancelAgent(agent.id) } label: {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Ferma") }
                    }
                    .buttonStyle(.glass)
                    .help("Interrompe l'esecuzione: i passi già fatti restano")
                } else {
                    Button { state.runAgent(agent.id) } label: { Label("Esegui ora", systemImage: "play.fill") }
                        .buttonStyle(.glassProminent)
                        .tint(agent.tint)
                }
                HStack(spacing: 6) {
                    Button(agent.active ? String(localized: "Pausa") : String(localized: "Riattiva")) { state.toggleActive(agent.id) }
                    Button("Modifica") { state.editingAgent = agent }
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
    }

    private func chip(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder
    private func activity(_ agent: AgentSpec) -> some View {
        let pending = state.pendingApprovals(for: agent)
        if pending > 0 {
            Label("\(pending) \(pending == 1 ? String(localized: "azione aspetta") : String(localized: "azioni aspettano")) la tua approvazione nella chat a destra.", systemImage: "hand.raised.fill")
                .font(DS.Fonts.body).foregroundStyle(.orange)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.tint(.orange.opacity(0.25)), in: .rect(cornerRadius: 18))
        }
        VStack(alignment: .leading, spacing: 0) {
            if agent.active, let next = agent.nextRun {
                timelineRow(symbol: "calendar.badge.clock", tint: .secondary, title: String(localized: "In programma"), text: String(localized: "Prossima esecuzione \(Dates.friendly(next))"), date: nil)
            }
            if agent.log.isEmpty {
                Text("Nessuna attività. Premi «Esegui ora» per farlo lavorare subito.").font(DS.Fonts.body).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(agent.log.reversed().prefix(80)) { event in
                timelineRow(symbol: symbol(event.kind), tint: tint(event.kind, agent), title: title(event.kind), text: event.text, date: event.date)
            }
        }
        .padding(16)
        .glassCard(radius: 24)
    }

    private func timelineRow(symbol: String, tint: Color, title: String, text: String, date: Date?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 26, height: 26).background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(DS.Fonts.bodyStrong)
                    Spacer()
                    if let date { Text(date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Dates.locale))).font(DS.Fonts.caption).foregroundStyle(.tertiary) }
                }
                Text(text).font(DS.Fonts.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func lastWork(_ agent: AgentSpec) -> some View {
        if let summary = agent.lastSummary {
            VStack(alignment: .leading, spacing: 8) {
                Text("Risultato dell'ultima esecuzione").font(DS.Fonts.captionStrong).foregroundStyle(.secondary)
                Text(MessageView.markdown(summary)).font(DS.Fonts.message).textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: 24)
        } else {
            Text("Ancora nessun risultato.").font(DS.Fonts.body).foregroundStyle(.secondary)
        }
        if let plan = state.conversations.first(where: { $0.agentID == agent.id })?.messages.reversed().compactMap({ message -> TaskPlanCardModel? in
            if case .taskPlan(let card) = message.content { return card }
            return nil
        }).first {
            TaskPlanCard(model: plan)
        }
    }

    @ViewBuilder
    private func dreams(_ agent: AgentSpec) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ogni notte il Genius «sogna»: rilegge quello che ha fatto, come hai risposto alle sue proposte e le tue indicazioni, scrive le lezioni nella sua anima e migliora le proprie istruzioni.")
                .font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle("Sogna ogni notte", isOn: Binding(get: { agent.dreamsEnabled }, set: { value in state.updateAgent(agent.id) { $0.dreamsEnabled = value } }))
                    .toggleStyle(.switch)
                Picker("alle", selection: Binding(get: { agent.dreamHour }, set: { value in state.updateAgent(agent.id) { $0.dreamHour = value } })) {
                    ForEach(0..<7, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                .frame(width: 130)
                .disabled(!agent.dreamsEnabled)
                Spacer()
                Button { state.dreamAgent(agent.id) } label: { Label("Sogna adesso", systemImage: "moon.stars") }
                    .disabled(state.runningAgents.contains(agent.id))
            }
            if !agent.instructions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Istruzioni attuali").font(DS.Fonts.captionStrong).foregroundStyle(.secondary)
                    Text(agent.instructions).font(DS.Fonts.body).textSelection(.enabled)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(radius: 18)
            }
            if agent.dreams.isEmpty {
                Text("Nessun sogno ancora: il primo arriva la notte dopo che il Genius ha lavorato.").font(DS.Fonts.body).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(agent.dreams.reversed()) { dream in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "moon.stars.fill").foregroundStyle(.purple)
                        Text(dream.date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute().locale(Dates.locale))).font(DS.Fonts.bodyStrong)
                        Spacer()
                        if dream.previousInstructions != dream.newInstructions {
                            Button("Ripristina istruzioni di prima") { state.undoDream(dream, for: agent.id) }.controlSize(.small)
                        }
                    }
                    Text(dream.reflection).font(DS.Fonts.body).foregroundStyle(.secondary)
                    ForEach(dream.lessons, id: \.self) { lesson in
                        Label(lesson, systemImage: "lightbulb").font(DS.Fonts.caption)
                    }
                    if dream.previousInstructions != dream.newInstructions {
                        DisclosureGroup("Istruzioni cambiate") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Prima: \(dream.previousInstructions.isEmpty ? "nessuna" : dream.previousInstructions)").font(DS.Fonts.caption).foregroundStyle(.secondary)
                                Text("Dopo: \(dream.newInstructions)").font(DS.Fonts.caption)
                            }
                        }
                        .font(DS.Fonts.caption)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(radius: 24)
            }
        }
    }

    @ViewBuilder
    private func memory(_ agent: AgentSpec) -> some View {
        Text("Quello che il Genius deve ricordare. Si aggiorna anche quando gli dai indicazioni in chat («d'ora in poi includi anche…»).")
            .font(DS.Fonts.caption).foregroundStyle(.secondary)
        HStack {
            TextField("Aggiungi un'indicazione", text: $newMemory).textFieldStyle(.roundedBorder).onSubmit { addMemory(agent) }
            Button("Aggiungi") { addMemory(agent) }.disabled(newMemory.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        ForEach(Array(agent.memory.enumerated()), id: \.offset) { index, item in
            HStack {
                Text(item).font(DS.Fonts.body)
                Spacer()
                Button { state.updateAgent(agent.id) { $0.memory.remove(at: index) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        }
    }

    private func addMemory(_ agent: AgentSpec) {
        let text = newMemory.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        state.updateAgent(agent.id) { $0.memory.append(text) }
        newMemory = ""
    }

    @ViewBuilder
    private func access(_ agent: AgentSpec) -> some View {
        Text("Scegli cosa può usare questo Genius. Le azioni importanti (email, eventi, file, messaggi, connettori) chiedono sempre la tua conferma.")
            .font(DS.Fonts.caption).foregroundStyle(.secondary)
        Toggle("Ricerca sul web", isOn: Binding(get: { agent.allowWeb }, set: { value in state.updateAgent(agent.id) { $0.allowWeb = value } }))
        Toggle(isOn: Binding(get: { agent.autoApprove }, set: { value in state.updateAgent(agent.id) { $0.autoApprove = value } })) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Approva da solo eventi, promemoria, note e file")
                Text("Email, messaggi, connettori e Cestino chiedono sempre la tua conferma.").font(DS.Fonts.caption).foregroundStyle(.secondary)
            }
        }
        Toggle(isOn: Binding(get: { agent.heartbeat }, set: { value in state.updateAgent(agent.id) { $0.heartbeat = value } })) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Controlla prima se c'è qualcosa da fare")
                Text("Nelle programmazioni «di continuo» guarda agenda, promemoria e posta e lavora solo se serve.").font(DS.Fonts.caption).foregroundStyle(.secondary)
            }
        }
        Toggle("Connettori (\(Set(state.mcp.allTools.map(\.serverName)).sorted().joined(separator: ", ")))",
               isOn: Binding(get: { agent.allowConnectors }, set: { value in state.updateAgent(agent.id) { $0.allowConnectors = value } }))
        ForEach(SourceKind.allCases) { source in
            Toggle(isOn: Binding(get: { agent.allowApps.contains(source) }, set: { value in
                state.updateAgent(agent.id) { if value { $0.allowApps.insert(source) } else { $0.allowApps.remove(source) } }
            })) {
                HStack(spacing: 8) { Tile(source, size: 18); Text(source.label) }
            }
        }
    }

    private func symbol(_ kind: AgentEvent.Kind) -> String {
        switch kind {
        case .avvio: "play.fill"
        case .piano: "list.number"
        case .passo: "checkmark"
        case .approvazione: "hand.raised.fill"
        case .risultato: "sparkles"
        case .errore: "exclamationmark.triangle.fill"
        case .nota: "note.text"
        case .sogno: "moon.stars.fill"
        }
    }

    private func tint(_ kind: AgentEvent.Kind, _ agent: AgentSpec) -> Color {
        switch kind {
        case .approvazione: .orange
        case .errore: .red
        case .risultato: agent.tint
        case .passo: .green
        case .sogno: .purple
        default: .secondary
        }
    }

    private func title(_ kind: AgentEvent.Kind) -> String {
        switch kind {
        case .avvio: String(localized: "Al lavoro")
        case .piano: String(localized: "Piano")
        case .passo: String(localized: "Passo completato")
        case .approvazione: String(localized: "Serve la tua approvazione")
        case .risultato: String(localized: "Risultato")
        case .errore: String(localized: "Problema")
        case .nota: String(localized: "Nota")
        case .sogno: String(localized: "Sogno")
        }
    }
}

// MARK: - Skill del Genius

private struct AgentSkillsView: View {
    @Environment(AppState.self) private var state
    let agent: AgentSpec
    @State private var selection: String?
    @State private var text = ""
    @State private var confirmDelete = false

    private var skills: [Skill] {
        _ = state.skillsRevision
        return SkillStore.forAgent(agent.id)
    }
    private var selected: Skill? { skills.first { $0.id == selection } }
    private var reusableSkills: [Skill] {
        let project = agent.projectName.flatMap { name in state.projects.first { $0.name == name && $0.exists }?.folder }
        return SkillStore.all(project: project).filter { source in
            !skills.contains { $0.name.localizedCaseInsensitiveCompare(source.name) == .orderedSame }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skill di \(agent.personName.isEmpty ? agent.name : agent.personName)").font(DS.Fonts.section)
                    Text("Procedure private di questo Genius, salvate nella sua cartella.")
                        .font(DS.Fonts.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Nuova skill") { createSkill() }
                    if !reusableSkills.isEmpty {
                        Divider()
                        ForEach(reusableSkills) { source in
                            Button("Copia «\(source.name)»") { copySkill(source) }
                        }
                    }
                } label: {
                    Label("Aggiungi skill", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            Text("Si attivano quando il compito o un messaggio contiene il nome della skill o una parola in «cues». Le skill generali restano disponibili; una skill privata con lo stesso nome ha la precedenza.")
                .font(DS.Fonts.caption).foregroundStyle(.secondary)

            if skills.isEmpty {
                ContentUnavailableView("Nessuna skill dedicata", systemImage: "wand.and.stars",
                                       description: Text("Crea una procedura o copia una skill esistente per questo Genius."))
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .glassCard(radius: 18)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(skills) { skill in
                                Button {
                                    selection = skill.id
                                    text = skill.text
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(skill.name).font(DS.Fonts.bodyStrong).lineLimit(1)
                                        if !skill.description.isEmpty {
                                            Text(skill.description).font(DS.Fonts.caption)
                                                .foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(9)
                                    .background(selection == skill.id ? Color.accentColor.opacity(0.14) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selection == skill.id ? .isSelected : [])
                            }
                        }
                    }
                    .frame(width: 220, height: 360)

                    VStack(alignment: .leading, spacing: 9) {
                        if let skill = selected {
                            Text(skill.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(DS.Fonts.micro).foregroundStyle(.secondary).lineLimit(1)
                            TextEditor(text: $text)
                                .font(DS.Fonts.mono)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .frame(height: 280)
                                .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10))
                            HStack {
                                Button("Sposta nel Cestino", role: .destructive) { confirmDelete = true }
                                Spacer()
                                Button("Salva") { saveSkill(skill) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(text == skill.text)
                            }
                        } else {
                            ContentUnavailableView("Scegli una skill", systemImage: "wand.and.stars")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .glassCard(radius: 18)
            }
            Button { showFolder() } label: { Label("Mostra cartella delle skill", systemImage: "folder") }
                .buttonStyle(.link)
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: state.skillsRevision) { _, _ in selectFirstIfNeeded() }
        .confirmationDialog("Spostare «\(selected?.name ?? "")» nel Cestino?", isPresented: $confirmDelete) {
            Button("Sposta nel Cestino", role: .destructive) {
                guard let skill = selected else { return }
                do {
                    try SkillStore.delete(skill)
                    state.skillsRevision += 1
                    selection = nil
                    selectFirstIfNeeded()
                } catch {
                    state.showToast(String(localized: "Skill non eliminata: \(error.localizedDescription)"), symbol: "exclamationmark.triangle.fill")
                }
            }
        }
    }

    private func selectFirstIfNeeded() {
        guard selected == nil else { return }
        let first = skills.first
        selection = first?.id
        text = first?.text ?? ""
    }

    private func createSkill() {
        do {
            let skill = try SkillStore.save(name: String(localized: "Nuova skill"), description: String(localized: "Cosa fa questa procedura"), cues: [],
                                            body: "## Procedura\n1. Primo passo\n2. Secondo passo", agent: agent.id)
            state.skillsRevision += 1
            selection = skill.id
            text = skill.text
        } catch {
            state.showToast(String(localized: "Skill non creata: \(error.localizedDescription)"), symbol: "exclamationmark.triangle.fill")
        }
    }

    private func copySkill(_ source: Skill) {
        do {
            let skill = try SkillStore.copy(source, toAgent: agent.id)
            state.skillsRevision += 1
            selection = skill.id
            text = skill.text
            state.showToast(String(localized: "Skill «\(skill.name)» aggiunta a \(agent.personName.isEmpty ? agent.name : agent.personName)"), symbol: "wand.and.stars")
        } catch {
            state.showToast(String(localized: "Skill non aggiunta: \(error.localizedDescription)"), symbol: "exclamationmark.triangle.fill")
        }
    }

    private func saveSkill(_ skill: Skill) {
        do {
            try text.write(to: skill.url, atomically: true, encoding: .utf8)
            state.skillsRevision += 1
            state.showToast(String(localized: "Skill salvata"), symbol: "wand.and.stars")
        } catch {
            state.showToast(String(localized: "Skill non salvata: \(error.localizedDescription)"), symbol: "exclamationmark.triangle.fill")
        }
    }

    private func showFolder() {
        let folder = SkillStore.agentFolder(agent.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

// MARK: - Editor

struct AgentEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentSpec

    init(agent: AgentSpec) { _draft = State(initialValue: agent) }

    var body: some View {
        let binding = $draft
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AgentAvatar(agent: draft, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.agent(draft.id) == nil ? String(localized: "Nuovo Genius") : String(localized: "Modifica \(draft.displayName)")).font(DS.Fonts.section)
                    Text("Lavora da solo sull'obiettivo e ti chiede conferma prima delle azioni importanti.").font(DS.Fonts.caption).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Nome", text: binding.personName, prompt: Text("Es. Giulia"))
                TextField("Ruolo", text: binding.name, prompt: Text("Es. Rassegna stampa"))
                TextField("Obiettivo", text: binding.goal, prompt: Text("Cosa deve fare ogni volta che lavora"), axis: .vertical).lineLimit(2...5)
                TextField("Istruzioni (facoltative)", text: binding.instructions, prompt: Text("Tono, formato, cosa evitare…"), axis: .vertical).lineLimit(1...4)
                Picker("Spazio", selection: binding.space) {
                    Text("Personale").tag(Space.personale.rawValue)
                    Text("Lavoro").tag(Space.lavoro.rawValue)
                }
                Picker("Progetto", selection: binding.projectName) {
                    Text("Nessuno").tag(String?.none)
                    ForEach(state.sortedProjects) { Text($0.name).tag(Optional($0.name)) }
                }
                Toggle("Può cercare sul web", isOn: binding.allowWeb)
                Toggle("Può usare i connettori", isOn: binding.allowConnectors)
                Toggle("Approva da solo eventi, promemoria, note e file", isOn: binding.autoApprove)
                Toggle("Controlla prima se c'è qualcosa da fare", isOn: binding.heartbeat)
            }
            .formStyle(.grouped)
            .frame(maxHeight: 330)
            DisclosureGroup("Programmazioni (\(draft.routines.count))") {
                RoutinesEditor(routines: binding.routines, run: nil).padding(.top, 6)
            }
            DisclosureGroup("Cartelle collegate (\(draft.folders.count))") {
                FoldersEditor(folders: binding.folders).padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Icona dietro al Genmoji").font(DS.Fonts.captionStrong).foregroundStyle(.secondary)
                Text("Il primo simbolo sceglie automaticamente l'icona dal lavoro del Genius. Il ritratto davanti viene generato con Image Playground di Apple.")
                    .font(DS.Fonts.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(AgentSpec.colors, id: \.self) { color in
                        Circle().fill(AgentSpec.tint(named: color)).frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(.white, lineWidth: draft.color == color ? 2.5 : 0))
                            .shadow(radius: draft.color == color ? 2 : 0)
                            .onTapGesture { draft.color = color }
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 8), spacing: 8) {
                    ForEach(AgentSpec.symbols, id: \.self) { symbol in
                        Image(systemName: symbol == "sparkles" ? draft.roleSymbol : symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(draft.symbol == symbol ? .white : .secondary)
                            .frame(width: 32, height: 32)
                            .background(draft.symbol == symbol ? AnyShapeStyle(draft.gradient) : AnyShapeStyle(Color.primary.opacity(0.06)),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .onTapGesture { draft.symbol = symbol }
                            .help(symbol == "sparkles" ? String(localized: "Automatica, in base al lavoro del Genius") : symbol)
                    }
                }
            }
            HStack {
                if state.agent(draft.id) != nil {
                    Button("Elimina", role: .destructive) { state.deleteAgent(draft.id); dismiss() }
                }
                Spacer()
                Button("Annulla") { dismiss() }
                Button(state.agent(draft.id) == nil ? String(localized: "Crea Genius") : String(localized: "Salva")) {
                    let isNew = state.agent(draft.id) == nil
                    state.saveAgent(draft)
                    dismiss()
                    if isNew { state.openAgent(draft.id) }
                }
                .buttonStyle(.borderedProminent)
                .tint(draft.tint)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.goal.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 580)
    }
}

/// Agente proposto in chat: anteprima e creazione con un clic.
struct AgentDraftCard: View {
    @Environment(AppState.self) private var state
    let model: AgentDraftCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentTile(agent: model.spec, height: 104).frame(maxWidth: 260)
            Text(model.spec.goal).font(DS.Fonts.body)
            HStack(spacing: 12) {
                Label(model.spec.scheduleLabel, systemImage: "clock")
                if model.spec.allowWeb { Label("Web", systemImage: "globe") }
                if model.spec.allowConnectors { Label("Connettori", systemImage: "puzzlepiece.extension") }
                if let project = model.spec.projectName { Label(project, systemImage: "folder") }
            }
            .font(DS.Fonts.caption).foregroundStyle(.secondary)
            HStack {
                if model.created {
                    Label("Genius creato", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(DS.Fonts.caption)
                    Spacer()
                    Button("Apri") { state.openAgent(model.spec.id) }
                } else {
                    Spacer()
                    Button("Modifica…") { state.editingAgent = model.spec }
                    Button("Crea Genius") { state.createAgent(from: model) }
                        .buttonStyle(.borderedProminent).tint(model.spec.tint)
                }
            }
        }
        .padding(14)
        .glassCard(radius: 24)
    }
}

// MARK: - Programmazioni

/// Le programmazioni di un agente: ognuna ha orario e, se vuoi, un compito suo.
struct RoutinesEditor: View {
    @Binding var routines: [AgentRoutine]
    var run: ((UUID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if routines.isEmpty {
                Text("Nessuna programmazione: il Genius lavora solo quando premi «Esegui ora».").font(DS.Fonts.body).foregroundStyle(.secondary)
            }
            ForEach($routines) { $routine in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Toggle("", isOn: $routine.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Picker("", selection: $routine.schedule.kind) {
                            ForEach(AgentSchedule.Kind.allCases.filter { $0 != .manuale }) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                        if routine.schedule.kind == .settimanale {
                            Picker("", selection: $routine.schedule.weekday) {
                                ForEach(1...7, id: \.self) { day in Text(Dates.locale.calendar.weekdaySymbols[day - 1].capitalized).tag(day) }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                        }
                        if routine.schedule.kind == .continuo {
                            Picker("", selection: Binding(get: { routine.schedule.interval }, set: { routine.schedule.intervalMinutes = $0 })) {
                                ForEach([15, 30, 60, 120, 240], id: \.self) { Text($0 < 60 ? String(localized: "ogni \($0) min") : String(localized: "ogni \($0 / 60) h")).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }
                        if [.giornaliero, .settimanale].contains(routine.schedule.kind) {
                            DatePicker("", selection: Binding(get: {
                                Calendar.current.date(bySettingHour: routine.schedule.hour, minute: routine.schedule.minute, second: 0, of: .now) ?? .now
                            }, set: { date in
                                routine.schedule.hour = Calendar.current.component(.hour, from: date)
                                routine.schedule.minute = Calendar.current.component(.minute, from: date)
                            }), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                        }
                        Spacer()
                        if let run {
                            Button { run(routine.id) } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless).iconHelp(String(localized: "Esegui ora questa programmazione"))
                        }
                        Button(role: .destructive) { routines.removeAll { $0.id == routine.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .iconHelp(String(localized: "Elimina questa programmazione"))
                    }
                    TextField("Compito (vuoto = obiettivo principale)", text: $routine.task, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                    HStack(spacing: 14) {
                        if let next = routine.nextRun, routine.enabled {
                            Label("Prossima: \(Dates.friendly(next))", systemImage: "arrow.forward.circle")
                        }
                        Label(routine.lastRun.map { String(localized: "Ultima: \(Dates.friendly($0))") } ?? String(localized: "Mai eseguita"), systemImage: "clock.arrow.circlepath")
                    }
                    .font(DS.Fonts.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .glassCard(radius: 18)
            }
            Button {
                routines.append(AgentRoutine(schedule: AgentSchedule(kind: .giornaliero, hour: 9)))
            } label: {
                Label("Aggiungi programmazione", systemImage: "plus")
            }
        }
    }
}

// MARK: - Cartelle

/// Cartelle collegate all'agente, ognuna in sola lettura o in lettura e scrittura.
struct FoldersEditor: View {
    @Binding var folders: [AgentFolder]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Il Genius legge e cerca nei file di queste cartelle. Scrive, sposta o crea file solo in quelle con permesso di scrittura, e sempre dopo la tua conferma.")
                .font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach($folders) { $folder in
                HStack(spacing: 10) {
                    Image(systemName: folder.exists ? "folder.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(folder.exists ? Color.accentColor : Color.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.name).font(DS.Fonts.bodyStrong)
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Picker("", selection: $folder.writable) {
                        Text("Solo lettura").tag(false)
                        Text("Lettura e scrittura").tag(true)
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).iconHelp(String(localized: "Mostra nel Finder"))
                    Button(role: .destructive) { folders.removeAll { $0.id == folder.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).iconHelp(String(localized: "Scollega"))
                }
                .padding(10)
                .glassCard(radius: 18)
            }
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = true
                panel.prompt = String(localized: "Collega")
                panel.message = String(localized: "Scegli una o più cartelle per il Genius.")
                guard panel.runModal() == .OK else { return }
                for url in panel.urls where !folders.contains(where: { $0.path == url.path }) {
                    folders.append(AgentFolder(path: url.path, writable: false))
                }
            } label: {
                Label("Collega cartelle…", systemImage: "folder.badge.plus")
            }
        }
    }
}

// MARK: - Anima

/// soul.md dell'agente: identità, missione, valori, stile e ciò che ha imparato sognando.
struct SoulEditor: View {
    @Environment(AppState.self) private var state
    let agent: AgentSpec
    @State private var text = ""
    @State private var saved = ""
    @State private var editing = false
    private let controller = TextEditingController()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("L'anima guida ogni lavoro del Genius. I sogni aggiungono ciò che impara in «Cosa ho imparato»; il resto lo decidi tu.")
                    .font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Picker("", selection: $editing) {
                    Text("Leggi").tag(false)
                    Text("Modifica").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Menu {
                    Button("Mostra soul.md nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppState.soulURL(agent.id)]) }
                    Button("Ripristina l'anima iniziale", role: .destructive) { text = agent.defaultSoul; editing = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden).fixedSize()
                Button("Salva") {
                    state.saveSoul(text, for: agent)
                    saved = text
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s")
                .disabled(text == saved)
            }
            Group {
                if editing {
                    CodeTextView(text: $text, controller: controller, monospaced: false)
                } else {
                    HTMLPreview(source: .html(Markdown.page(text, title: "soul.md")))
                }
            }
            .frame(minHeight: 420)
            .glassCard(radius: 18)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline))
        }
        .onAppear {
            let soul = state.soul(of: agent)
            text = soul
            saved = soul
        }
    }
}

// MARK: - Ritratto

/// Genmoji in primo piano e icona del lavoro su uno sfondo colorato.
struct AgentAvatar: View {
    let agent: AgentSpec
    var size: CGFloat = 32
    /// Sulla tessera colorata: bordo bianco per staccare dal fondo.
    var onTile = false

    private var glyph: NSAdaptiveImageGlyph? {
        guard let path = agent.avatarPath, path.hasSuffix(".genmoji"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return NSAdaptiveImageGlyph(imageContent: data)
    }

    private var portrait: NSImage? {
        guard let path = agent.avatarPath, !path.hasSuffix(".genmoji") else { return nil }
        return NSImage(contentsOfFile: path)
    }

    var body: some View {
        ZStack {
            Circle().fill(agent.gradient)
            Image(systemName: agent.roleSymbol)
                .font(.system(size: size * 0.39, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .offset(x: -size * 0.22, y: -size * 0.19)
            if let glyph {
                Text(AttributedString(NSAttributedString(adaptiveImageGlyph: glyph,
                                                         attributes: [.font: NSFont.systemFont(ofSize: size * 0.72)])))
                    .font(.system(size: size * 0.72))
                    .lineLimit(1)
                    .frame(width: size * 0.77, height: size * 0.77)
                    .background(.white.opacity(0.88), in: Circle())
                    .offset(x: size * 0.12, y: size * 0.11)
            } else if let portrait {
                Image(nsImage: portrait).resizable().scaledToFill()
                    .frame(width: size * 0.77, height: size * 0.77)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: max(0.5, size * 0.018)))
                    .offset(x: size * 0.12, y: size * 0.11)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.37, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.68, height: size * 0.68)
                    .background(.white.opacity(0.24), in: Circle())
                    .offset(x: size * 0.14, y: size * 0.13)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(onTile ? 0.7 : 0.25), lineWidth: onTile ? 1.5 : 0.5))
        .accessibilityLabel(agent.displayName)
    }
}

/// Genmoji grande, creato nel foglio nativo di Image Playground.
struct PortraitButton: View {
    @Environment(AppState.self) private var state
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    let agentID: UUID
    var size: CGFloat = 76
    @State private var showSheet = false
    @State private var concept = ""
    @State private var preparing = false
    var body: some View {
        if let agent = state.agent(agentID) {
            Menu {
                Button(agent.hasGenmoji ? String(localized: "Rigenera con Image Playground…") : String(localized: "Genera Genmoji con Image Playground…")) { open(agent) }
                    .disabled(!supportsImagePlayground)
                if agent.avatarPath != nil {
                    Button(agent.hasGenmoji ? String(localized: "Togli il Genmoji") : String(localized: "Togli il ritratto"),
                           role: .destructive) { state.removeAvatar(for: agentID) }
                }
                if !supportsImagePlayground { Text("Richiede Image Playground e Apple Intelligence") }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    AgentAvatar(agent: agent, size: size)
                        .shadow(color: agent.tint.opacity(0.3), radius: 8, y: 4)
                    Image(systemName: preparing ? "hourglass" : "wand.and.stars")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24).background(Color.accentColor, in: Circle())
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Genmoji di \(agent.displayName) generato con Image Playground, con l'icona del suo lavoro sullo sfondo")
            .imagePlaygroundSheet(isPresented: $showSheet, concept: concept,
                                  onCompletion: { _ in
                                      state.showToast(String(localized: "Image Playground ha creato una foto: scegli lo stile Genmoji e riprova"),
                                                      symbol: "exclamationmark.triangle.fill")
                                  },
                                  onAdaptiveImageGlyphCreation: { glyph in state.setGenmoji(glyph, for: agentID) })
            .imagePlaygroundGenerationStyle(.emoji, in: [.emoji])
            .onChange(of: state.genmojiRequestAgentID, initial: true) { _, request in
                guard request == agentID else { return }
                state.genmojiRequestAgentID = nil
                guard supportsImagePlayground else {
                    state.showToast(String(localized: "Genmoji richiede Apple Intelligence attiva su questo Mac"), symbol: "exclamationmark.triangle.fill")
                    return
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard case .agent(let visibleID) = state.section, visibleID == agentID,
                          let current = state.agent(agentID), !current.hasGenmoji else { return }
                    open(current)
                }
            }
        }
    }

    private func open(_ agent: AgentSpec) {
        preparing = true
        Task {
            concept = await state.portraitConcept(for: agent)
            preparing = false
            showSheet = true
        }
    }
}
