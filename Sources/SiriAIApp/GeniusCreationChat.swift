import SiriCore
import SwiftUI

/// L'unico percorso di creazione: una domanda alla volta, poi un riepilogo da confermare.
struct GeniusCreationChat: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentSpec
    @State private var step: Step = .task
    @State private var input: String
    @State private var result = ""
    @State private var time: Date
    @State private var weekday: Int
    @State private var lines: [Line]
    /// Modello cloud in attesa dell'avviso sulla privacy, e se è per la programmazione.
    @State private var pendingCloud: ModelSelection?
    @State private var pendingForRoutine = false
    @FocusState private var inputFocused: Bool

    private enum Step: Int { case task, result, access, cadence, time, model, routineModel, role, name, review }
    private struct Line: Identifiable {
        let id = UUID()
        let fromGenius: Bool
        let text: String
    }

    init(initial: AgentSpec) {
        _draft = State(initialValue: initial)
        _input = State(initialValue: initial.goal)
        let schedule = initial.routines.first?.schedule
        _time = State(initialValue: Calendar.current.date(bySettingHour: schedule?.hour ?? 9,
                                                           minute: schedule?.minute ?? 0, second: 0, of: .now) ?? .now)
        _weekday = State(initialValue: schedule?.weekday ?? 2)
        _lines = State(initialValue: [Line(fromGenius: true, text: initial.goal.isEmpty
            ? Language.t("Ciao! Creiamo il tuo Genius. Quale compito vuoi affidargli?", "Hi! Let's create your Genius. What task should it handle?")
            : Language.t("Partiamo da questa idea. Conferma il compito o riscrivilo come preferisci.", "Let's start with this idea. Confirm the task or rewrite it as you like."))])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AgentAvatar(agent: draft, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Language.t("Crea un Genius", "Create a Genius")).font(DS.Fonts.section)
                    Text(step == .review ? Language.t("Pronto da controllare", "Ready to review")
                         : Language.t("Un passo alla volta", "One step at a time"))
                        .font(DS.Fonts.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(Language.t("Chiudi", "Close"))
            }
            .padding(20)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(lines) { line in bubble(line) }
                        if step == .review { review }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(20)
                }
                .onChange(of: lines.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: step.rawValue) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            Divider()
            controls.padding(20)
        }
        .frame(width: 650, height: 700)
        .onAppear { inputFocused = true }
        .cloudConsent($pendingCloud) { cloud in
            if pendingForRoutine, !draft.routines.isEmpty { draft.routines[0].model = cloud } else { draft.model = cloud }
        }
        .task {
            // Diagnostica (solo istanze di prova, per le foto del README): risponde da sola fino alla scelta del modello.
            guard AppTesting.ephemeral, CommandLine.arguments.contains("--genius-creation-demo"), step == .task else { return }
            submitText()
            input = Language.t("Cinque punti con i link alle fonti e i prossimi passi più utili.",
                               "A five-point brief with source links and the most useful next steps.")
            submitText()
            draft.allowWeb = true
            draft.allowApps = [.calendar, .reminders, .mail, .notes, .files]
            answer(Language.t("Web e app", "Web and apps"), next: .cadence)
            draft.routines = [AgentRoutine(schedule: AgentSchedule(kind: .giornaliero, hour: 8))]
            answer(Language.t("Ogni giorno", "Every day"), next: .time)
            answer(draft.routines[0].schedule.label, next: .model)
        }
    }

    private func bubble(_ line: Line) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !line.fromGenius { Spacer(minLength: 90) }
            if line.fromGenius {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 25, height: 25)
                    .background(AgentSpec.tint(named: draft.color), in: Circle())
            }
            Text(line.text).font(DS.Fonts.body)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(line.fromGenius ? Color.primary.opacity(0.07) : Color.accentColor.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 17))
                .textSelection(.enabled)
            if line.fromGenius { Spacer(minLength: 90) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var controls: some View {
        switch step {
        case .task, .result, .role, .name:
            VStack(alignment: .leading, spacing: 8) {
                if step == .name, input.isEmpty {
                    let suggestion = AgentSpec.suggestedPersonName(for: draft.name, avoiding: state.agents.map(\.personName))
                    Button(Language.t("Usa \(suggestion)", "Use \(suggestion)")) { input = suggestion; submitText() }
                        .buttonStyle(.borderless)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField(placeholder, text: $input, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4)
                        .focused($inputFocused).onSubmit(submitText)
                    Button(step == .task && !draft.goal.isEmpty ? Language.t("Conferma", "Confirm") : Language.t("Continua", "Continue"), action: submitText)
                        .buttonStyle(.borderedProminent)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        case .access:
            choices([
                (Language.t("App del Mac", "Mac apps"), "apps"),
                (Language.t("Web e app", "Web and apps"), "web-apps"),
                (Language.t("Solo web", "Web only"), "web"),
                (Language.t("App e connettori", "Apps and connectors"), "connectors"),
            ]) { key, label in
                draft.allowWeb = key == "web-apps" || key == "web"
                draft.allowConnectors = key == "connectors"
                draft.allowApps = key == "web" ? [] : [.calendar, .reminders, .mail, .notes, .files]
                answer(label, next: .cadence)
            }
        case .cadence:
            choices([
                (Language.t("Solo quando lo avvio", "Only when I start it"), "manuale"),
                (Language.t("Ogni giorno", "Every day"), "giornaliero"),
                (Language.t("Ogni settimana", "Every week"), "settimanale"),
                (Language.t("Ogni ora", "Every hour"), "orario"),
            ]) { key, label in
                if key == "manuale" { draft.routines = [] }
                else if let kind = AgentSchedule.Kind(rawValue: key) { draft.routines = [AgentRoutine(schedule: AgentSchedule(kind: kind))] }
                answer(label, next: key == "giornaliero" || key == "settimanale" ? .time : .model)
            }
        case .time:
            VStack(alignment: .leading, spacing: 12) {
                if draft.routines.first?.schedule.kind == .settimanale {
                    Picker(Language.t("Giorno", "Day"), selection: $weekday) {
                        ForEach(1...7, id: \.self) { day in
                            Text(Dates.locale.calendar.weekdaySymbols[day - 1].capitalized).tag(day)
                        }
                    }
                }
                DatePicker(Language.t("Ora", "Time"), selection: $time, displayedComponents: .hourAndMinute)
                Button(Language.t("Continua", "Continue")) {
                    draft.routines[0].schedule.hour = Calendar.current.component(.hour, from: time)
                    draft.routines[0].schedule.minute = Calendar.current.component(.minute, from: time)
                    draft.routines[0].schedule.weekday = weekday
                    answer(draft.routines[0].schedule.label, next: .model)
                }
                .buttonStyle(.borderedProminent)
            }
        case .model:
            VStack(alignment: .leading, spacing: 10) {
                ModelPicker(current: draft.model ?? state.defaultSelection(for: Space(rawValue: draft.space) ?? .lavoro), offersAuto: true) {
                    let choice = state.resolved($0)
                    if choice.needsCloudConsent(after: draft.model ?? state.defaultSelection(for: Space(rawValue: draft.space) ?? .lavoro)) {
                        pendingForRoutine = false
                        pendingCloud = choice
                    } else { draft.model = choice }
                }
                Text(Language.t("Questo modello sarà usato dal Genius. Potrai sceglierne uno diverso per ogni programmazione.",
                                "This model will be used by the Genius. You can choose a different one for each schedule."))
                    .font(DS.Fonts.caption).foregroundStyle(.secondary)
                Button(Language.t("Continua", "Continue")) {
                    draft.model = state.resolved(draft.model ?? state.defaultSelection(for: Space(rawValue: draft.space) ?? .lavoro))
                    answer(state.label(for: draft.model!), next: draft.routines.isEmpty ? .role : .routineModel)
                }
                .buttonStyle(.borderedProminent)
            }
        case .routineModel:
            VStack(alignment: .leading, spacing: 10) {
                Text(Language.t("Puoi lasciare il modello del Genius o sceglierne uno solo per questa programmazione.",
                                "You can use the Genius model or choose one just for this schedule."))
                    .font(DS.Fonts.caption).foregroundStyle(.secondary)
                HStack {
                    Button(Language.t("Usa il modello del Genius", "Use the Genius model")) {
                        draft.routines[0].model = nil
                        answer(Language.t("Modello del Genius", "Genius model"), next: .role)
                    }
                    .buttonStyle(.bordered)
                    ModelPicker(current: draft.routines[0].model ?? draft.model!, compact: true, offersAuto: true) {
                        let choice = state.resolved($0)
                        if choice.needsCloudConsent(after: draft.routines[0].model ?? draft.model) {
                            pendingForRoutine = true
                            pendingCloud = choice
                        } else { draft.routines[0].model = choice }
                    }
                }
                if let model = draft.routines[0].model {
                    Button(Language.t("Continua", "Continue")) { answer(state.label(for: model), next: .role) }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .review:
            HStack {
                Button(Language.t("Modifica le risposte", "Edit answers")) { edit(.task) }
                Spacer()
                Button(Language.t("Crea Genius", "Create Genius"), action: create)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var placeholder: String {
        switch step {
        case .task: Language.t("Descrivi il compito", "Describe the task")
        case .result: Language.t("Es. Un riepilogo con fonti e prossimi passi", "E.g. A summary with sources and next steps")
        case .role: Language.t("Es. Rassegna stampa", "E.g. News briefing")
        case .name: Language.t("Es. Giulia", "E.g. Giulia")
        default: ""
        }
    }

    private func choices(_ options: [(String, String)], action: @escaping (String, String) -> Void) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.1) { label, key in
                Button(label) { action(key, label) }.buttonStyle(.bordered)
            }
        }
    }

    private func submitText() {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch step {
        case .task: draft.goal = value; answer(value, next: .result)
        case .result: result = value; answer(value, next: .access)
        case .role: draft.name = value; answer(value, next: .name)
        case .name: draft.personName = value; answer(value, next: .review)
        default: break
        }
    }

    private func answer(_ text: String, next: Step) {
        lines.append(Line(fromGenius: false, text: text))
        step = next
        if next != .review { lines.append(Line(fromGenius: true, text: question(next))) }
        else { lines.append(Line(fromGenius: true, text: Language.t("Ecco il tuo Genius. Controlla tutto, poi crealo.", "Here's your Genius. Review everything, then create it."))) }
        input = next == .role ? (draft.name.isEmpty ? suggestedRole : draft.name)
              : next == .name ? draft.personName : ""
        inputFocused = [.result, .role, .name].contains(next)
    }

    private var suggestedRole: String {
        let words = draft.goal.split(separator: " ").prefix(4).joined(separator: " ")
        return words.isEmpty ? Language.t("Assistente personale", "Personal assistant") : words.capitalized
    }

    private func question(_ step: Step) -> String {
        switch step {
        case .task: Language.t("Quale compito vuoi affidargli?", "What task should it handle?")
        case .result: Language.t("Che risultato vuoi ricevere quando ha finito?", "What result would you like when it finishes?")
        case .access: Language.t("Dove deve cercare o lavorare? Le azioni importanti richiederanno comunque una conferma.",
                                 "Where should it search or work? Important actions will still need confirmation.")
        case .cadence: Language.t("Quando deve occuparsene?", "When should it work on this?")
        case .time: Language.t("A che ora deve iniziare?", "What time should it start?")
        case .model: Language.t("Quale modello vuoi per questo Genius?", "Which model would you like for this Genius?")
        case .routineModel: Language.t("E per questa programmazione, quale modello vuoi?", "Which model should this schedule use?")
        case .role: Language.t("Come descriveresti il suo ruolo?", "How would you describe its role?")
        case .name: Language.t("Come vuoi chiamarlo?", "What would you like to call it?")
        case .review: ""
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentAvatar(agent: draft, size: 54)
            Text(draft.displayName).font(DS.Fonts.section)
            Text(draft.goal).font(DS.Fonts.body)
            Label(result, systemImage: "checkmark.circle").font(DS.Fonts.caption)
            Label(draft.routines.first?.schedule.label ?? Language.t("Quando lo avvii", "When you start it"), systemImage: "calendar")
            Label(draft.model.map(state.label(for:)) ?? "", systemImage: "cpu")
            if let model = draft.routines.first?.model {
                Label(Language.t("Programmazione: \(state.label(for: model))", "Schedule: \(state.label(for: model))"), systemImage: "cpu.fill")
            }
            Text(Language.t("Spazio: \(draft.space == "personale" ? "Personale" : "Lavoro")", "Space: \(draft.space == "personale" ? "Personal" : "Work")"))
                .font(DS.Fonts.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(radius: 20)
    }

    private func edit(_ step: Step) {
        self.step = step
        input = draft.goal
        lines.append(Line(fromGenius: true, text: Language.t("Va bene, ripartiamo dal compito.", "Sure, let's start again from the task.")))
        inputFocused = true
    }

    private func create() {
        guard !draft.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var spec = draft
        let expected = Language.t("Risultato atteso", "Expected result")
        let instruction = "\(expected): \(result)"
        if !result.isEmpty { spec.instructions = [spec.instructions, instruction].filter { !$0.isEmpty }.joined(separator: "\n") }
        state.saveAgent(spec)
        dismiss()
        state.openAgent(spec.id)
    }
}

/// Solo per le foto (`--snapshot … --genius-creation-demo`): la chat guidata sopra la finestra, come il foglio vero,
/// che la foto della sola finestra non catturerebbe.
struct GeniusCreationSnapshot: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            GeniusCreationChat(initial: {
                var spec = AgentTemplate.all[0].spec
                spec.space = state.space == .codice ? Space.lavoro.rawValue : state.space.rawValue
                return spec
            }())
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        }
    }
}
