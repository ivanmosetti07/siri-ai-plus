import AppKit
import ImagePlayground
import SiriCore
import SwiftUI

private let timeFormat = Date.FormatStyle.dateTime.hour().minute().locale(Dates.locale)
private let dayFormat = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Dates.locale)

private func openApp(_ bundleID: String) {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

// MARK: - Agenda (lettura: risultato immediato)

struct AgendaCard: View {
    @Environment(AppState.self) private var state
    let agenda: Agenda

    var body: some View {
        Card(title: agenda.title, subtitle: subtitle) {
            Tile(agenda.showsEvents ? .calendar : .reminders)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                if agenda.showsEvents {
                    Group {
                        if agenda.events.isEmpty {
                            Text("Nessun evento in calendario.").font(DS.Fonts.body).foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(agenda.events) { EventLine(event: $0, showsDay: multiDay) }
                            }
                        }
                    }
                }
                if agenda.showsReminders {
                    if agenda.showsEvents { Divider() }
                    if agenda.reminders.isEmpty && agenda.overdue.isEmpty {
                        Text("Nessun promemoria in scadenza.").font(DS.Fonts.body).foregroundStyle(.secondary)
                    }
                    ReminderGroup(title: agenda.showsEvents ? String(localized: "Promemoria") : nil, items: agenda.reminders)
                    ReminderGroup(title: String(localized: "Arretrati"), items: agenda.overdue, overdue: true)
                }
                HStack {
                    Spacer()
                    if agenda.showsEvents { Button("Apri Calendario") { openApp("com.apple.iCal") } }
                    if agenda.showsReminders { Button("Apri Promemoria") { openApp("com.apple.reminders") } }
                }
                .buttonStyle(.link)
                .font(DS.Fonts.caption)
            }
        }
    }

    private var multiDay: Bool {
        guard let first = agenda.events.first?.start, let last = agenda.events.last?.start else { return false }
        return !Calendar.current.isDate(first, inSameDayAs: last)
    }

    private var subtitle: String {
        var parts: [String] = []
        if agenda.showsEvents { parts.append(agenda.events.count == 1 ? String(localized: "1 evento") : String(localized: "\(agenda.events.count) eventi")) }
        if agenda.showsReminders { parts.append(String(localized: "\(agenda.reminders.count + agenda.overdue.count) promemoria")) }
        return parts.joined(separator: " · ")
    }

    struct EventLine: View {
        let event: EventItem
        let showsDay: Bool

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(event.color)).frame(width: 3, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(when).font(DS.Fonts.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text(event.title).font(DS.Fonts.body).lineLimit(2)
                }
                Spacer()
                Text(event.calendar).font(DS.Fonts.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }

        private var when: String {
            let day = showsDay ? event.start.formatted(dayFormat) + " · " : ""
            return day + (event.isAllDay ? String(localized: "Tutto il giorno") : "\(event.start.formatted(timeFormat)) – \(event.end.formatted(timeFormat))")
        }
    }

    struct ReminderGroup: View {
        @Environment(AppState.self) private var state
        let title: String?
        let items: [ReminderItem]
        var overdue = false
        @State private var done = Set<String>()
        var body: some View {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    if let title { Text(title).font(DS.Fonts.captionStrong).foregroundStyle(overdue ? .red : .secondary) }
                    ForEach(items) { item in
                        HStack(spacing: 9) {
                            Button {
                                withAnimation { _ = done.insert(item.id) }
                                state.complete(item)
                            } label: {
                                Image(systemName: done.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color(item.color))
                            }
                            .buttonStyle(.plain)
                            .disabled(done.contains(item.id))
                            .help("Segna come completato")
                            Text(item.title).font(DS.Fonts.body).strikethrough(done.contains(item.id)).lineLimit(2)
                            if item.highPriority { Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(.orange) }
                            Spacer()
                            if let due = item.due {
                                Text(item.dueHasTime ? due.formatted(dayFormat) + " " + due.formatted(timeFormat) : due.formatted(dayFormat))
                                    .font(DS.Fonts.caption).monospacedDigit()
                                    .foregroundStyle(overdue ? .red : .secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 06 Evento

struct EventCard: View {
    @Environment(AppState.self) private var state
    @Bindable var model: EventCardModel

    var body: some View {
        Card(title: title, subtitle: subtitle, status: model.status,
             statusLabel: model.edit != nil && model.status == .done ? String(localized: "Modificato") : nil) {
            Tile(.calendar)
        } content: {
            if model.status == .draft {
                editor
            } else {
                summary
            }
        }
    }

    private var title: String {
        if model.status == .done { return model.draft.title }
        return model.edit == nil ? String(localized: "Nuovo evento") : String(localized: "Modifica evento")
    }

    private var subtitle: String {
        if let edit = model.edit {
            return model.status == .done ? String(localized: "Aggiornato in «\(model.draft.calendar)»") : String(localized: "Prima: «\(edit.before.title)», \(Self.when(edit.before))")
        }
        return model.status == .done ? String(localized: "Salvato in «\(model.draft.calendar)»") : String(localized: "Calendario")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Titolo", text: $model.draft.title)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    FieldLabel("Inizio")
                    DatePicker("Inizio", selection: $model.draft.start, displayedComponents: model.draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                        .labelsHidden()
                }
                if !model.draft.isAllDay {
                    GridRow {
                        FieldLabel("Fine")
                        DatePicker("Fine", selection: $model.draft.end, in: model.draft.start..., displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }
                }
                GridRow {
                    FieldLabel("")
                    Toggle("Tutto il giorno", isOn: $model.draft.isAllDay).toggleStyle(.checkbox).font(DS.Fonts.body)
                }
                GridRow {
                    FieldLabel("Calendario")
                    Picker("Calendario", selection: $model.draft.calendar) {
                        ForEach(EventKitService.writableCalendars(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    FieldLabel("Luogo")
                    TextField("Aggiungi un luogo", text: $model.draft.location).textFieldStyle(.roundedBorder)
                }
            }
            .font(DS.Fonts.body)
            if let conflict = model.conflicts.first {
                InlineBanner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                             text: String(localized: "Si sovrappone a «\(conflict.title)» (\(conflict.start.formatted(timeFormat))–\(conflict.end.formatted(timeFormat)))\(model.conflicts.count > 1 ? String(localized: " e ad altri \(model.conflicts.count - 1)") : "").")) {
                    Button("Sposta dopo") { withAnimation { model.moveAfterConflicts() } }.controlSize(.small)
                }
            }
            if let edit = model.edit, edit.attendees > 0 {
                Label(edit.attendees == 1 ? String(localized: "L'evento ha un invitato: il calendario potrebbe avvisarlo del cambiamento.")
                                          : String(localized: "L'evento ha \(edit.attendees) invitati: il calendario potrebbe avvisarli del cambiamento."),
                      systemImage: "person.2")
                    .font(DS.Fonts.caption).foregroundStyle(.secondary)
            }
            CardActions(primary: model.edit == nil ? String(localized: "Salva evento") : String(localized: "Salva modifiche"),
                        primaryDisabled: model.draft.title.trimmingCharacters(in: .whitespaces).isEmpty || (model.edit.map { $0.before == model.draft } ?? false),
                        cancel: { model.status = .cancelled }) { state.save(model) }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(when, systemImage: "clock").font(DS.Fonts.body)
            if !model.draft.location.isEmpty { Label(model.draft.location, systemImage: "mappin.and.ellipse").font(DS.Fonts.body) }
            if let error = model.error { Text(error).font(DS.Fonts.caption).foregroundStyle(.red) }
            if model.status == .done {
                HStack {
                    UndoButton(since: model.doneAt, available: model.createdID != nil || model.savedStart != nil) { state.undo(model) }
                    Spacer()
                    Button("Apri in Calendario") { openApp("com.apple.iCal") }.buttonStyle(.link).font(DS.Fonts.caption)
                }
            }
        }
        .foregroundStyle(model.status == .cancelled ? .secondary : .primary)
    }

    private var when: String {
        let day = model.draft.start.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Dates.locale)).capitalized
        return model.draft.isAllDay ? String(localized: "\(day), tutto il giorno")
            : "\(day), \(model.draft.start.formatted(timeFormat)) – \(model.draft.end.formatted(timeFormat))"
    }

    static func when(_ draft: EventDraft) -> String {
        let day = draft.start.formatted(dayFormat)
        return draft.isAllDay ? String(localized: "\(day), tutto il giorno") : "\(day), \(draft.start.formatted(timeFormat))–\(draft.end.formatted(timeFormat))"
    }
}

struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(DS.Fonts.caption).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
    }
}

// MARK: - 08 Promemoria

struct RemindersCard: View {
    @Environment(AppState.self) private var state
    @Bindable var model: RemindersCardModel

    var body: some View {
        Card(title: model.edit != nil ? String(localized: "Modifica promemoria") : model.drafts.count == 1 ? String(localized: "Nuovo promemoria") : String(localized: "Nuovi promemoria"),
             subtitle: subtitle, status: model.status, statusLabel: model.edit != nil && model.status == .done ? String(localized: "Modificato") : nil) {
            Tile(.reminders)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($model.drafts) { $draft in
                    ReminderDraftRow(draft: $draft, editable: model.status == .draft)
                }
                if let error = model.error { Text(error).font(DS.Fonts.caption).foregroundStyle(.red) }
                if model.status == .draft {
                    Divider()
                    HStack {
                        Picker("Lista", selection: $model.list) {
                            ForEach(EventKitService.reminderLists(), id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        Button("Annulla") { model.status = .cancelled }
                        Button(model.edit != nil ? String(localized: "Salva modifiche") : model.includedCount == 1 ? String(localized: "Aggiungi promemoria") : String(localized: "Aggiungi \(model.includedCount) promemoria")) {
                            state.add(model)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.includedCount == 0)
                    }
                } else if model.status == .done {
                    HStack {
                        UndoButton(since: model.doneAt, available: !model.createdIDs.isEmpty || model.edit != nil) { state.undo(model) }
                        Spacer()
                        Button("Apri Promemoria") { openApp("com.apple.reminders") }.buttonStyle(.link).font(DS.Fonts.caption)
                    }
                }
            }
        }
    }
}

extension RemindersCard {
    private var subtitle: String {
        guard let edit = model.edit else { return String(localized: "Lista «\(model.list)»") }
        let due = edit.before.due.map { String(localized: ", scadeva \(edit.before.dueHasTime ? $0.formatted(dayFormat) + " " + $0.formatted(timeFormat) : $0.formatted(dayFormat))") } ?? ""
        return String(localized: "Prima: «\(edit.before.title)»\(due) · lista \(edit.beforeList)")
    }
}

struct ReminderDraftRow: View {
    @Binding var draft: ReminderDraft
    let editable: Bool
    @State private var editingDate = false
    var body: some View {
        HStack(spacing: 10) {
            Button { draft.included.toggle() } label: {
                Image(systemName: draft.included ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(draft.included ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!editable)
            .accessibilityLabel(draft.included ? String(localized: "Incluso") : String(localized: "Escluso"))

            TextField(String(localized: "reminder.placeholder", defaultValue: "Promemoria"), text: $draft.title)
                .textFieldStyle(.plain)
                .font(DS.Fonts.body)
                .disabled(!editable)
                .opacity(draft.included ? 1 : 0.45)

            Button { editingDate = true } label: {
                Text(dueLabel)
                    .font(DS.Fonts.caption).monospacedDigit()
                    .foregroundStyle(draft.due == nil ? .tertiary : .secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!editable)
            .popover(isPresented: $editingDate) {
                VStack(alignment: .leading, spacing: 10) {
                    DatePicker("Scadenza", selection: Binding(get: { draft.due ?? .now }, set: { draft.due = $0 }),
                               displayedComponents: draft.dueHasTime ? [.date, .hourAndMinute] : [.date])
                        .datePickerStyle(.graphical)
                    Toggle("Con orario e notifica", isOn: $draft.dueHasTime)
                    HStack {
                        Button("Nessuna data") { draft.due = nil; editingDate = false }
                        Spacer()
                        Button(String(localized: "button.done", defaultValue: "Fine")) { editingDate = false }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(14)
                .frame(width: 260)
            }

            Button { draft.highPriority.toggle() } label: {
                Image(systemName: draft.highPriority ? "flag.fill" : "flag")
                    .font(.system(size: 12))
                    .foregroundStyle(draft.highPriority ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!editable)
            .help("Priorità alta")
        }
    }

    private var dueLabel: String {
        guard let due = draft.due else { return String(localized: "Nessuna data") }
        return draft.dueHasTime ? due.formatted(dayFormat) + " " + due.formatted(timeFormat) : due.formatted(dayFormat)
    }
}

// MARK: - Conferma (eliminazione / completamento)

struct ConfirmCard: View {
    @Environment(AppState.self) private var state
    let model: ConfirmCardModel

    var body: some View {
        Card(title: model.action.title, subtitle: model.action.detail, status: model.status) {
            Tile(model.source)
        } content: {
            if model.status == .awaiting {
                CardActions(note: note,
                            primary: model.isDestructive ? String(localized: "Elimina") : String(localized: "Completa"), primaryRole: model.isDestructive ? .destructive : nil,
                            cancel: { model.status = .cancelled }) { state.perform(model) }
            } else if let error = model.error {
                Text(error).font(DS.Fonts.caption).foregroundStyle(.red)
            }
        }
    }
}

extension ConfirmCard {
    private var note: String {
        switch model.action.kind {
        case .deleteEvent: String(localized: "L'evento verrà rimosso dal calendario.")
        case .deleteReminder: String(localized: "Il promemoria verrà eliminato.")
        case .completeReminder: String(localized: "Il promemoria verrà segnato come fatto.")
        }
    }
}

// MARK: - 07 Mail

struct MailCard: View {
    @Environment(AppState.self) private var state
    @Bindable var model: MailCardModel

    var body: some View {
        Card(title: model.status == .opened || model.status == .done ? model.subject : model.reply != nil ? String(localized: "Risposta \(Self.to(MailReader.senderName(model.recipients)))") : String(localized: "Bozza email"),
             subtitle: model.status == .opened || model.status == .done ? String(localized: "Bozza aperta in Mail: invia da lì") : model.reply != nil ? String(localized: "Mail · nella stessa conversazione") : String(localized: "Mail"),
             status: model.status) {
            Tile(.mail)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if model.status == .draft || model.status == .awaiting {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            FieldLabel("A")
                            // Nella risposta destinatario e oggetto li decide Mail (quelli dell'email ricevuta).
                            if model.reply != nil {
                                Text(model.recipients + (model.reply?.replyAll == true ? String(localized: " e tutti gli altri") : "")).lineLimit(1).foregroundStyle(.secondary)
                            } else {
                                TextField("nome@esempio.it, …", text: $model.recipients).textFieldStyle(.plain)
                            }
                        }
                        Divider().gridCellColumns(2)
                        GridRow {
                            FieldLabel("Oggetto")
                            if model.reply != nil {
                                Text(model.subject).font(DS.Fonts.bodyStrong).lineLimit(1)
                            } else {
                                TextField("Oggetto", text: $model.subject).textFieldStyle(.plain).font(DS.Fonts.bodyStrong)
                            }
                        }
                    }
                    .font(DS.Fonts.body)
                    .disabled(model.status == .awaiting)
                    TextEditor(text: $model.body)
                        .font(DS.Fonts.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 140, maxHeight: 280)
                        .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .disabled(model.status == .awaiting)
                    if let reply = model.reply {
                        if MailMessage(id: reply.messageID, subject: "", sender: reply.to, date: "").isAutomatic {
                            Label("Questo indirizzo manda solo notifiche automatiche: probabilmente nessuno leggerà la risposta.", systemImage: "exclamationmark.triangle")
                                .font(DS.Fonts.caption).foregroundStyle(.orange)
                        }
                        DisclosureGroup("Email originale") {
                            Text(reply.quote).font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(14)
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                        .font(DS.Fonts.caption)
                    } else if model.missingAddresses {
                        Label("Alcuni destinatari non hanno un indirizzo email: completali qui o in Mail.", systemImage: "info.circle")
                            .font(DS.Fonts.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.error { Text(error).font(DS.Fonts.caption).foregroundStyle(.red) }
                if model.status == .draft {
                    CardActions(primary: model.reply != nil ? String(localized: "Rispondi…") : String(localized: "Invia…"),
                                primaryDisabled: model.recipientList.isEmpty || model.subject.isEmpty || model.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                cancel: { model.status = .cancelled }) { withAnimation(DS.Motion.standard) { model.status = .awaiting } }
                } else if model.status == .awaiting {
                    InlineBanner(symbol: "paperplane", tint: .orange,
                                 text: model.reply != nil
                                    ? String(localized: "Aprirò in Mail la risposta, nella stessa conversazione e con l'email originale citata. L'invio parte solo quando premi Invia in Mail.")
                                    : String(localized: "Aprirò Mail con il messaggio per \(model.recipientList.joined(separator: ", ")). L'invio parte solo quando premi Invia in Mail.")) {
                        Button("Indietro") { withAnimation { model.status = .draft } }.controlSize(.small)
                        Button("Apri in Mail") { model.reply != nil ? state.openReply(model) : state.openInMail(model) }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                } else if model.status == .opened || model.status == .done {
                    Text(model.body).font(DS.Fonts.body).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
    }
}

extension MailCard {
    /// "a Marco", "ad Alex".
    static func to(_ name: String) -> String {
        if Language.system == .en { return "to \(name)" }
        return name.lowercased().hasPrefix("a") ? "ad \(name)" : "a \(name)"
    }
}

// MARK: - 05 Piano e conferma

struct PlanCard: View {
    @Environment(AppState.self) private var state
    @Bindable var model: PlanCardModel

    var body: some View {
        Card(title: String(localized: "Piano proposto"), subtitle: model.plan.summary, status: model.status,
             ) {
            OrbView(state: model.status == .running ? .thinking : .idle, size: 26, animated: model.status == .running)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($model.plan.steps) { $step in
                        PlanStepRow(step: $step, status: model.stepStatus[step.id], result: model.stepResult[step.id],
                                    editable: model.status == .awaiting)
                    }
                }
                if !model.sources.isEmpty {
                    HStack(spacing: 6) {
                        Text("Fonti usate").font(DS.Fonts.caption).foregroundStyle(.secondary)
                        ForEach(model.sources) { source in
                            HStack(spacing: 4) { Tile(source, size: 14); Text(source.label).font(DS.Fonts.caption) }
                        }
                    }
                }
                if model.status == .awaiting {
                    HStack {
                        Text("Le email restano bozze: le invii tu dopo averle controllate.")
                            .font(DS.Fonts.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Annulla piano") { model.status = .cancelled }
                        Button("Conferma ed esegui") { state.execute(model) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.plan.steps.contains(where: \.included))
                    }
                }
            }
        }
    }
}

struct PlanStepRow: View {
    @Binding var step: PlanDraft.Step
    let status: ItemStatus?
    let result: String?
    let editable: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if editable {
                    Button { step.included.toggle() } label: {
                        Image(systemName: step.included ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(step.included ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(step.included ? String(localized: "Incluso") : String(localized: "Escluso"))
                } else {
                    switch status {
                    case .running?: ProgressView().controlSize(.small)
                    case .done?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed?: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    case .cancelled?: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    default: Image(systemName: "circle").foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.system(size: 15))
            .frame(width: 18, height: 18)

            stepTile
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(DS.Fonts.bodyStrong)
                Text([step.when.flatMap { Dates.parse($0) }.map { Dates.friendly($0.date, time: $0.hasTime) }, step.detail]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let result {
                    Text(result).font(DS.Fonts.caption).foregroundStyle(status == .failed ? .red : .green)
                }
            }
            .opacity(step.included ? 1 : 0.45)
        }
    }

    @ViewBuilder private var stepTile: some View {
        switch step.kind {
        case .evento: Tile(.calendar, size: 22)
        case .promemoria: Tile(.reminders, size: 22)
        case .email: Tile(.mail, size: 22)
        case .documento: Tile(ArtifactKind.pages, size: 22)
        case .foglio: Tile(ArtifactKind.numbers, size: 22)
        case .presentazione: Tile(ArtifactKind.keynote, size: 22)
        }
    }
}

// MARK: - Chip dell'artefatto

struct ArtifactChip: View {
    @Environment(AppState.self) private var state
    let artifact: ArtifactModel
    @State private var hovered = false
    private var isOpen: Bool { state.openArtifact?.id == artifact.id }

    var body: some View {
        Button {
            // Apre sempre: prima un secondo clic chiudeva il documento e riportava alla Home.
            state.open(artifact)
        } label: {
            HStack(spacing: 12) {
                Tile(artifact.kind, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title).font(DS.Fonts.bodyStrong).lineLimit(1)
                    Text("\(artifact.kind.noun) · \(artifact.summary) · \(artifact.stateLabel)")
                        .font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(isOpen ? String(localized: "Aperto") : String(localized: "Apri"))
                    .font(DS.Fonts.captionStrong)
                    .foregroundStyle(isOpen ? Color.secondary : artifact.kind.tint)
            }
            .padding(12)
            .frame(maxWidth: 440, alignment: .leading)
            .modifier(CardSurface(radius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isOpen ? artifact.kind.tint.opacity(0.6) : Color.clear, lineWidth: 1.5))
            .scaleEffect(hovered ? 1.01 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

// MARK: - Fonte non disponibile / permesso mancante

struct UnavailableCard: View {
    @Environment(AppState.self) private var state
    let model: UnavailableCardModel

    var body: some View {
        Card(title: title, subtitle: model.source.label) {
            Tile(model.source, dimmed: model.kind == .comingSoon)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Text(message).font(DS.Fonts.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.resolved {
                    HStack {
                        Spacer()
                        switch model.kind {
                        case .comingSoon:
                            Button("Vedi le fonti") { state.sourcesSheet = model.source; state.showSourcesSheet = true }
                        case .notConnected:
                            if state.systemDenied(model.source) {
                                Button("Apri Impostazioni di Sistema") { state.openPrivacySettings(for: model.source) }
                            } else {
                                Button("Collega \(model.source.label) e riprova") { state.resolve(model) }.buttonStyle(.borderedProminent)
                            }
                        case .notSelected:
                            Button("Includi \(model.source.label) e riprova") { state.resolve(model) }.buttonStyle(.borderedProminent)
                        case .readOnly:
                            Button("Consenti le modifiche e riprova") { state.resolve(model) }.buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
    }

    private var title: String {
        switch model.kind {
        case .comingSoon: String(localized: "\(model.source.label) non è ancora collegabile")
        case .notConnected: String(localized: "Serve l'accesso a \(model.source.label)")
        case .notSelected: String(localized: "\(model.source.label) è esclusa da questa richiesta")
        case .readOnly: String(localized: "Accesso in sola lettura")
        }
    }

    private var message: String {
        switch model.kind {
        case .comingSoon:
            String(localized: "Il collegamento a \(model.source.label) arriverà in una prossima versione. Oggi Siri AI+ lavora con Calendario, Promemoria, bozze Mail e documenti, fogli e presentazioni.")
        case .notConnected:
            state.systemDenied(model.source)
                ? String(localized: "macOS ha negato l'accesso a \(model.source.label). Riattivalo in Privacy e sicurezza, poi torna qui.")
                : String(localized: "Per rispondere devo poter \(model.source.readCapability.lowercased()). Le risposte possono usare Private Cloud Compute di Apple quando è disponibile.")
        case .notSelected:
            String(localized: "Hai limitato la richiesta ad altre fonti, ma per rispondere mi serve anche \(model.source.label).")
        case .readOnly:
            String(localized: "Hai concesso a Siri AI+ solo la lettura di \(model.source.label). Per questa azione servono i permessi di modifica.")
        }
    }
}

// MARK: - Immagini

struct ImageCard: View {
    @Environment(AppState.self) private var state
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @Bindable var model: ImageCardModel
    @State private var showSheet = false
    var body: some View {
        card
            .imagePlaygroundSheet(isPresented: $showSheet, concept: model.prompt) { url in
                state.adopt(url, into: model)
            }
            .onAppear {
                if state.imageSheetCardID == model.id {
                    state.imageSheetCardID = nil
                    showSheet = supportsImagePlayground
                }
            }
            .onChange(of: state.imageSheetCardID) { _, id in
                if id == model.id { state.imageSheetCardID = nil; showSheet = supportsImagePlayground }
            }
    }

    private var card: some View {
        Card(title: String(localized: "Immagine"), subtitle: String(localized: "Image Playground · \(ImageService.label(model.style))"), status: model.status,
             statusLabel: model.status == .running ? String(localized: "Creazione…") : nil) {
            Image(systemName: "photo.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(LinearGradient(colors: [Color(hex: 0xFF6F91), Color(hex: 0x6E6BFF)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.prompt).font(DS.Fonts.body).foregroundStyle(.secondary).lineLimit(2)
                if model.needsSheet {
                    InlineBanner(symbol: "sparkles", tint: .purple,
                                 text: supportsImagePlayground ? String(localized: "Su questo Mac le immagini si creano nel foglio di Image Playground: ho già preparato la descrizione.") : String(localized: "Image Playground non è disponibile su questo Mac.")) {
                        if supportsImagePlayground {
                            Button("Crea con Image Playground") { showSheet = true }.buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                } else if model.status == .running {
                    HStack(spacing: 10) {
                        ForEach(0..<2, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06))
                                .frame(height: 150)
                                .overlay(ProgressView())
                        }
                    }
                } else if !model.urls.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                        ForEach(model.urls, id: \.self) { url in
                            ImageThumb(url: url)
                        }
                    }
                }
                if let error = model.error { Text(error).font(DS.Fonts.caption).foregroundStyle(.red) }
                if model.status != .running && !model.needsSheet {
                    HStack {
                        Picker("Stile", selection: $model.style) {
                            ForEach(ImageService.styles, id: \.id) { Text($0.label).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        if let first = model.urls.first {
                            Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.urls.isEmpty ? [first] : model.urls) }
                        }
                        Button("Rigenera") { state.regenerate(model) }.buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

struct ImageThumb: View {
    @Environment(AppState.self) private var state
    let url: URL

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.primary.opacity(0.06).overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            }
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .draggable(url)
        .contextMenu {
            Button("Apri") { NSWorkspace.shared.open(url) }
            Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            if let artifact = state.openArtifact, artifact.kind != .numbers {
                Button("Inserisci in «\(artifact.title)»") { EditorBridge.insertImage(url, into: artifact) }
            }
            Button("Copia") {
                NSPasteboard.general.clearContents()
                if let image = NSImage(contentsOf: url) { NSPasteboard.general.writeObjects([image]) }
            }
        }
        .help("Doppio clic per aprire, trascina per usarla altrove")
    }
}

// MARK: - File di progetto

struct FilesCard: View {
    @Environment(AppState.self) private var state
    let paths: [String]

    var body: some View {
        Card(title: String(localized: "File del progetto"), subtitle: state.currentProject?.name ?? "") {
            Image(systemName: "folder.fill").font(.system(size: 18)).foregroundStyle(Color.accentColor).frame(width: 26)
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(paths.prefix(20), id: \.self) { path in
                    Text(path).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                }
                if paths.count > 20 { Text("…e altri \(paths.count - 20)").font(DS.Fonts.caption).foregroundStyle(.secondary) }
                if let project = state.currentProject {
                    HStack { Spacer(); Button("Apri il progetto") { state.openProject(project) }.buttonStyle(.link).font(DS.Fonts.caption) }
                }
            }
        }
    }
}

struct FileWriteCard: View {
    @Environment(AppState.self) private var state
    @Bindable var model: FileWriteCardModel
    @State private var showPrevious = false
    var body: some View {
        Card(title: model.draft.exists ? String(localized: "Modifica file") : String(localized: "Nuovo file"), subtitle: model.draft.path, status: model.status,
             ) {
            Image(systemName: model.draft.exists ? "doc.badge.ellipsis" : "doc.badge.plus")
                .font(.system(size: 16)).foregroundStyle(Color.accentColor).frame(width: 26)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if model.status == .awaiting {
                    TextField("Percorso", text: $model.draft.path).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    if let change = model.draft.change {
                        Text(change)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        Text("Contenuto completo dopo la modifica:").font(DS.Fonts.caption).foregroundStyle(.secondary)
                    }
                    TextEditor(text: $model.draft.content)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 120, maxHeight: 260)
                        .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
                    if let previous = model.draft.previous {
                        DisclosureGroup("Versione attuale", isExpanded: $showPrevious) {
                            Text(previous).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(DS.Fonts.caption)
                    }
                    CardActions(note: model.draft.exists ? (model.draft.change == nil ? String(localized: "Il file verrà sovrascritto con questo contenuto.") : String(localized: "Il resto del file resta invariato.")) : String(localized: "Il file verrà creato nella cartella del progetto."),
                                primary: model.draft.exists ? String(localized: "Salva modifiche") : String(localized: "Crea file"), cancel: { model.status = .cancelled }) { state.confirm(model) }
                } else if let error = model.error {
                    Text(error).font(DS.Fonts.caption).foregroundStyle(.red)
                } else if model.status == .done {
                    Text(model.draft.content).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4)
                    if let project = state.projects.first(where: { $0.id == model.projectID }) {
                        HStack {
                            UndoButton(since: model.doneAt, available: true) { state.undo(model) }
                            Spacer()
                            Button("Apri nell'editor") { state.openProjectFile(project, path: model.draft.path) }
                            if ["html", "htm"].contains((model.draft.path as NSString).pathExtension.lowercased()),
                               let url = try? project.files.resolve(model.draft.path) {
                                Button { state.openInBrowser(url) } label: { Label("Apri nel browser", systemImage: "safari") }
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

struct FileOpCard: View {
    @Environment(AppState.self) private var state
    @Bindable var model: FileOpCardModel

    var body: some View {
        Card(title: model.draft.title, subtitle: state.projects.first { $0.id == model.projectID }?.name ?? String(localized: "Progetto"), status: model.status,
             statusLabel: model.status == .done ? String(localized: "Fatto") : nil) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(model.draft.kind == .trash ? Color.red : Color.accentColor).frame(width: 26)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                switch model.draft.kind {
                case .move:
                    if model.status == .awaiting {
                        LabeledContent("Da") { Text(model.draft.from).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                        LabeledContent("A") { TextField("Destinazione", text: $model.draft.to).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)) }
                    } else {
                        Text("\(model.draft.from) → \(model.draft.to)").font(.system(size: 12, design: .monospaced))
                    }
                case .folder:
                    if model.status == .awaiting {
                        TextField("Cartella", text: $model.draft.from).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    } else {
                        Text(model.draft.from).font(.system(size: 12, design: .monospaced))
                    }
                case .trash:
                    Text(model.draft.from).font(.system(size: 12, design: .monospaced))
                    Text("Finisce nel Cestino del Mac: puoi recuperarlo da lì.").font(DS.Fonts.caption).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).font(DS.Fonts.caption).foregroundStyle(.red) }
                if model.status == .awaiting {
                    CardActions(primary: model.draft.title, primaryRole: model.draft.kind == .trash ? .destructive : nil,
                                cancel: { model.status = .cancelled }) { state.confirm(model) }
                } else if model.status == .done {
                    HStack {
                        UndoButton(since: model.doneAt, available: model.draft.kind != .trash || model.trashedURL != nil) { state.undo(model) }
                        Spacer()
                    }
                }
            }
        }
    }

    private var symbol: String {
        switch model.draft.kind {
        case .move: "arrow.right.doc.on.clipboard"
        case .folder: "folder.badge.plus"
        case .trash: "trash"
        }
    }
}

// MARK: - Strumenti esterni (MCP)

struct MCPCallCard: View {
    @Environment(AppState.self) private var state
    let model: MCPCallCardModel

    var body: some View {
        // Le letture partite da sole: una riga, con argomenti e risultato a richiesta.
        if model.status != .awaiting, model.status != .cancelled, state.mcp.runsFreely(model.draft.tool) {
            MCPReadRow(model: model)
        } else {
            card
        }
    }

    private var card: some View {
        Card(title: model.draft.displayName, subtitle: String(localized: "Connettore «\(model.draft.tool.serverName)»") + ((model.draft.steps ?? []).isEmpty ? "" : String(localized: " · passo \((model.draft.steps ?? []).count + 1)")), status: model.status,
             ) {
            Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 15)).foregroundStyle(.purple).frame(width: 26)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if !toolDescription.isEmpty {
                    Text(toolDescription).font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                // I campi come righe «chiave: valore» (sui servizi a catalogo quelli dello strumento interno): si vede cosa si conferma.
                Text(ConnectorResult.readable(model.draft.displayArguments.compactString, limit: 1500))
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
                if model.status == .awaiting {
                    CardActions(primary: String(localized: "Esegui"), cancel: { model.status = .cancelled }, secondary: {
                        // Sui servizi a catalogo varrebbe per tutto ciò che scrive (execute_write_tool), non solo per questo strumento.
                        if model.draft.inner == nil {
                            Button("Consenti sempre") { state.approve(model, always: true) }
                                .help("Non chiederò più conferma per questo strumento")
                        }
                    }) { state.approve(model, always: false) }
                } else if let error = model.error {
                    Text(error).font(DS.Fonts.caption).foregroundStyle(.red)
                } else if let result = model.result {
                    DisclosureGroup("Risultato") {
                        Text(result).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(DS.Fonts.caption)
                }
            }
        }
    }

    private var toolDescription: String {
        if let inner = model.draft.inner, !inner.description.isEmpty { return inner.description }
        return model.draft.tool.description
    }
}

/// Una lettura da un connettore, partita senza chiedere: «Agency OS · search_tools · 12 elementi».
struct MCPReadRow: View {
    let model: MCPCallCardModel
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 11)).foregroundStyle(.purple)
                    Text("\(model.draft.tool.serverName) · \(model.draft.displayName)").font(DS.Fonts.caption).foregroundStyle(.secondary)
                    switch model.status {
                    case .running:
                        ProgressView().controlSize(.mini)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    default:
                        if let result = model.result {
                            Text(ConnectorResult.summary(result)).font(DS.Fonts.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Lettura da \(model.draft.tool.serverName): \(model.draft.displayName)"))
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.draft.arguments.compactString)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    if let error = model.error {
                        Text(error).font(DS.Fonts.caption).foregroundStyle(.orange).textSelection(.enabled)
                    } else if let result = model.result {
                        Text(ConnectorResult.readable(result, limit: 4000))
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 2)
    }
}


/// «Annulla» per qualche minuto dopo la conferma: poi sparisce.
struct UndoButton: View {
    let since: Date?
    var available = true
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            if available, UndoWindow.isOpen(since) {
                Button(action: action) { Label("Annulla", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.link)
                    .font(DS.Fonts.caption)
                    .help("Ripristina com'era prima (disponibile per 10 minuti)")
            }
        }
    }
}
