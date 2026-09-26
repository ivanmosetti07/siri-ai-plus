import SiriCore
import SwiftUI

/// Una voce dello storico: un'esecuzione di un agente o un suo sogno.
struct HistoryItem: Identifiable {
    let agent: AgentSpec
    let run: AgentRun?
    let dream: AgentDream?
    var id: UUID { run?.id ?? dream?.id ?? agent.id }
    var date: Date { run?.start ?? dream?.date ?? .distantPast }

    /// Esecuzioni (e, se richiesto, sogni) degli agenti, dalla più recente.
    static func items(for agents: [AgentSpec], dreams: Bool) -> [HistoryItem] {
        var items: [HistoryItem] = []
        for agent in agents {
            items += agent.history.map { HistoryItem(agent: agent, run: $0, dream: nil) }
            if dreams { items += agent.dreams.map { HistoryItem(agent: agent, run: nil, dream: $0) } }
        }
        return items.sorted { $0.date > $1.date }
    }
}

/// Storico delle esecuzioni: raggruppato per giorno, con filtro ed esito espandibile.
struct RunHistoryView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case tutte = "Tutte", programmate = "Programmate", manuali = "Avviate da te", problemi = "Con problemi"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .tutte: Language.t("Tutte", "All")
            case .programmate: Language.t("Programmate", "Scheduled")
            case .manuali: Language.t("Avviate da te", "Started by you")
            case .problemi: Language.t("Con problemi", "With problems")
            }
        }
    }

    @Environment(AppState.self) private var state
    let items: [HistoryItem]
    /// Mostra avatar e nome dell'agente (nella pagina Programmazioni, con più agenti).
    var showAgent = false
    var emptyText = Language.t("Nessuna esecuzione finora.", "No runs yet.")
    @State private var filter: Filter
    @State private var expanded = Set<UUID>()
    @State private var limit = 30

    init(items: [HistoryItem], showAgent: Bool = false,
         emptyText: String = Language.t("Nessuna esecuzione finora.", "No runs yet."), initialFilter: Filter = .tutte) {
        self.items = items
        self.showAgent = showAgent
        self.emptyText = emptyText
        _filter = State(initialValue: initialFilter)
    }

    private var filtered: [HistoryItem] {
        items.filter { item in
            guard let run = item.run else { return filter == .tutte }
            switch filter {
            case .tutte: return true
            case .programmate: return run.trigger != .manuale
            case .manuali: return run.trigger == .manuale
            case .problemi: return [.errore, .interrotta].contains(run.outcome) || run.errors > 0
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Language.t("Storico delle esecuzioni", "Run history")).font(DS.Fonts.section)
                Spacer()
                if !items.isEmpty {
                    Picker(Language.t("Mostra", "Show"), selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if items.isEmpty {
                Text(emptyText).font(DS.Fonts.body).foregroundStyle(.secondary)
            } else if filtered.isEmpty {
                Text(Language.t("Nessuna esecuzione con questo filtro.", "No runs match this filter.")).font(DS.Fonts.body).foregroundStyle(.secondary)
            } else {
                let shown = Array(filtered.prefix(limit))
                let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.dayTitle(day)).font(DS.Fonts.captionStrong).foregroundStyle(.secondary).textCase(.uppercase)
                        VStack(spacing: 0) {
                            let rows = days[day] ?? []
                            ForEach(rows) { item in
                                row(item)
                                if item.id != rows.last?.id { Divider().padding(.leading, 60) }
                            }
                        }
                        .glassCard(radius: 18)
                    }
                }
                if filtered.count > limit {
                    Button(Language.t("Mostra altre \(min(30, filtered.count - limit))", "Show \(min(30, filtered.count - limit)) more")) { limit += 30 }
                        .buttonStyle(.link)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: HistoryItem) -> some View {
        let open = expanded.contains(item.id)
        let detail = item.run?.summary ?? item.dream?.reflection ?? ""
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(DS.Motion.quick) {
                    if open { expanded.remove(item.id) } else { expanded.insert(item.id) }
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Text(item.date.formatted(.dateTime.hour().minute())).font(DS.Fonts.captionStrong).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    if showAgent {
                        AgentAvatar(agent: item.agent, size: 24)
                    }
                    Image(systemName: symbol(item)).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint(item))
                        .frame(width: 22, height: 22).background(tint(item).opacity(0.12), in: Circle())
                        .accessibilityLabel(status(item))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(item)).font(DS.Fonts.bodyStrong).lineLimit(1)
                        Text(subtitle(item)).font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Text(status(item)).font(DS.Fonts.caption).foregroundStyle(tint(item)).lineLimit(1)
                    if !detail.isEmpty {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(detail.isEmpty)
            .accessibilityHint(open ? Language.t("Nasconde il riepilogo", "Hide summary") : Language.t("Mostra il riepilogo", "Show summary"))
            if open, !detail.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(MessageView.markdown(detail)).font(DS.Fonts.callout).textSelection(.enabled)
                    HStack {
                        Button(Language.t("Apri la chat del Genius", "Open Genius chat")) { state.openAgent(item.agent.id) }
                        if let run = item.run, run.trigger != .manuale || run.routineID != nil, !state.runningAgents.contains(item.agent.id) {
                            Button(Language.t("Esegui di nuovo", "Run again")) { state.runAgent(item.agent.id, routine: run.routineID) }
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.leading, showAgent ? 110 : 74)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func title(_ item: HistoryItem) -> String {
        if item.dream != nil { return Language.t("Sogno", "Dream") }
        guard let run = item.run else { return "" }
        return run.task.isEmpty ? (run.routineLabel ?? Language.t("Obiettivo principale", "Main goal")) : run.task
    }

    private func subtitle(_ item: HistoryItem) -> String {
        let who = showAgent ? "\(item.agent.displayName) · " : ""
        if let dream = item.dream {
            return who + (dream.lessons.isEmpty ? Language.t("Ha riletto la giornata", "Reviewed the day")
                        : Language.t("\(dream.lessons.count) \(dream.lessons.count == 1 ? "lezione" : "lezioni") imparate",
                                     "\(dream.lessons.count) \(dream.lessons.count == 1 ? "lesson" : "lessons") learned"))
        }
        guard let run = item.run else { return "" }
        var parts = [run.trigger.label]
        if let label = run.routineLabel, !run.task.isEmpty { parts.append(label) }
        if let duration = run.duration { parts.append(Self.duration(duration)) }
        if run.steps > 0 { parts.append(Language.t("\(run.steps) \(run.steps == 1 ? "passo" : "passi")", "\(run.steps) \(run.steps == 1 ? "step" : "steps")")) }
        if run.approvals > 0 { parts.append(Language.t("\(run.approvals) \(run.approvals == 1 ? "azione" : "azioni") in attesa", "\(run.approvals) \(run.approvals == 1 ? "action" : "actions") pending")) }
        if run.errors > 0 { parts.append(Language.t("\(run.errors) \(run.errors == 1 ? "errore" : "errori")", "\(run.errors) \(run.errors == 1 ? "error" : "errors")")) }
        return who + parts.joined(separator: " · ")
    }

    private func status(_ item: HistoryItem) -> String {
        if item.dream != nil { return Language.t("Sogno", "Dream") }
        if let run = item.run, run.outcome == .inCorso, !state.runningAgents.contains(item.agent.id) { return AgentRun.Outcome.interrotta.label }
        return item.run?.outcome.label ?? ""
    }

    private func symbol(_ item: HistoryItem) -> String {
        if item.dream != nil { return "moon.stars.fill" }
        switch item.run?.outcome ?? .completata {
        case .inCorso: return "hourglass"
        case .completata: return item.run?.trigger == .manuale ? "play.fill" : "clock.badge.checkmark"
        case .daApprovare: return "hand.raised.fill"
        case .errore: return "exclamationmark.triangle.fill"
        case .interrotta: return "stop.fill"
        }
    }

    private func tint(_ item: HistoryItem) -> Color {
        if item.dream != nil { return .purple }
        switch item.run?.outcome ?? .completata {
        case .inCorso: return .blue
        case .completata: return .green
        case .daApprovare: return .orange
        case .errore: return .red
        case .interrotta: return .secondary
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(total, 1)) s" }
        if total < 3600 { return "\(total / 60) min" + (total % 60 >= 10 && total < 600 ? " \(total % 60) s" : "") }
        return "\(total / 3600) h \((total % 3600) / 60) min"
    }

    static func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return Language.t("Oggi", "Today") }
        if Calendar.current.isDateInYesterday(day) { return Language.t("Ieri", "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Dates.locale))
    }
}
