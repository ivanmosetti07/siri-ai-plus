import SiriCore
import SwiftUI

/// Piano di un compito complesso: catena di pensieri e lista dei passi con lo stato di ogni sub-agent.
struct TaskPlanCard: View {
    @Environment(AppState.self) private var state
    let model: TaskPlanCardModel
    @State private var showThoughts = true
    @State private var expanded = Set<UUID>()
    var body: some View {
        Card(title: String(localized: "Piano di lavoro"), subtitle: subtitle) {
            Image(systemName: "list.number").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.accentColor).frame(width: 26)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                DisclosureGroup(isExpanded: $showThoughts) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.plan.thoughts.enumerated()), id: \.offset) { _, thought in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "sparkle").font(.system(size: 9)).foregroundStyle(.secondary).padding(.top, 4)
                                Text(thought).font(DS.Fonts.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Label("Ragionamento", systemImage: "brain").font(DS.Fonts.captionStrong)
                }
                Divider()
                ForEach(Array(model.plan.steps.enumerated()), id: \.element.id) { index, step in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            StepStatusIcon(status: step.status)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("\(index + 1). \(step.title)").font(DS.Fonts.bodyStrong)
                                    if step.parallel {
                                        Text("in parallelo").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Color.primary.opacity(0.07), in: Capsule())
                                    }
                                    // ChatGPT e Claude: la versione che svolge il passo, scelta da Apple Intelligence in base alla difficoltà.
                                    if let sub = step.subAgent {
                                        Label(SubAgentRouting.label(sub), systemImage: "cpu").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                                            .help(step.difficulty.map { String(localized: "Passo \($0.label): lo svolge \(SubAgentRouting.label(sub))") } ?? SubAgentRouting.label(sub))
                                    }
                                }
                                Text(step.instruction).font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if !step.result.isEmpty {
                                Button {
                                    if expanded.contains(step.id) { expanded.remove(step.id) } else { expanded.insert(step.id) }
                                } label: { Image(systemName: expanded.contains(step.id) ? "chevron.up" : "chevron.down") }
                                .buttonStyle(.borderless)
                                .iconHelp(String(localized: "Mostra il risultato del passo"))
                            }
                        }
                        if expanded.contains(step.id) {
                            Text(step.result).font(DS.Fonts.caption).textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
                                .padding(.leading, 26)
                        }
                    }
                }
                if model.running {
                    HStack {
                        Spacer()
                        Button("Interrompi") { state.stopTask() }.controlSize(.small)
                    }
                } else if model.plan.steps.allSatisfy({ ["fatto", "conferma"].contains($0.status) }) {
                    HStack {
                        Spacer()
                        if model.savedAsSkill {
                            Label("Salvato come skill", systemImage: "checkmark").font(DS.Fonts.caption).foregroundStyle(.secondary)
                        } else {
                            Button { state.saveSkill(from: model) } label: { Label("Salva come skill", systemImage: "wand.and.stars") }
                                .controlSize(.small)
                                .help("Salva questo modo di lavorare: lo seguirò quando chiedi qualcosa di simile")
                        }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        let done = model.plan.steps.filter { $0.status == "fatto" }.count
        return String(localized: "\(done)/\(model.plan.steps.count) passi · fino a \(model.parallel) sub-agent insieme")
    }
}

struct StepStatusIcon: View {
    let status: String

    var body: some View {
        Group {
            switch status {
            case "corso": ProgressView().controlSize(.small)
            case "fatto": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case "errore": Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case "conferma": Image(systemName: "hand.raised.circle.fill").foregroundStyle(.blue)
            default: Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 15))
        .frame(width: 18, height: 18)
    }
}

/// Collegamento a una chat figlia, o il suo riepilogo quando è stata conclusa.
struct ChatLinkCard: View {
    @Environment(AppState.self) private var state
    let link: ChatLink

    var body: some View {
        Card(title: link.summary == nil ? String(localized: "Chat figlia aperta") : String(localized: "Riepilogo della chat figlia"),
             subtitle: link.title + (link.projectName.map { String(localized: " · progetto \($0)") } ?? "")) {
            Image(systemName: link.summary == nil ? "arrow.turn.down.right" : "arrow.uturn.backward.circle.fill")
                .font(.system(size: 16)).foregroundStyle(Color.accentColor).frame(width: 26)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = link.summary {
                    Text(summary).font(DS.Fonts.body).textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button(link.summary == nil ? String(localized: "Apri la chat") : String(localized: "Rivedi la chat")) { state.open(childID: link.childID) }
                        .buttonStyle(.link).font(DS.Fonts.caption)
                }
            }
        }
    }
}

/// Barra in cima a una chat figlia: da dove arriva e il pulsante per concluderla.
struct ChildChatBanner: View {
    @Environment(AppState.self) private var state
    let conversation: Conversation

    var body: some View {
        if let parent = state.parent(of: conversation) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                Text("Chat figlia di «\(parent.title)»").font(DS.Fonts.caption).lineLimit(1)
                Spacer()
                if conversation.returned {
                    Text("Conclusa").font(DS.Fonts.caption).foregroundStyle(.secondary)
                    Button("Torna alla madre") { state.select(parent) }.controlSize(.small)
                } else {
                    if conversation.id == state.currentID {
                        Button { state.newChatTab(with: parent) } label: { Image(systemName: "rectangle.split.2x1") }
                            .controlSize(.small)
                            .help("Apri la chat madre accanto, in una scheda")
                    }
                    Button("Concludi e invia alla chat madre") { state.returnToParent() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isResponding || conversation.messages.isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.08))
        }
    }
}

/// Nuova chat figlia: argomento, progetto facoltativo e primo messaggio.
struct NewChildChatSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var projectID = UUID?.none
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nuova chat figlia").font(DS.Fonts.section)
            Text("Lavora su un argomento a parte (anche in un progetto). Quando la concludi, il riepilogo torna in «\(state.current?.title ?? String(localized: "questa chat"))».")
                .font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Argomento", text: $title, prompt: Text("Es. Ricerca concorrenti"))
                Picker("Progetto", selection: $projectID) {
                    Text("Nessun progetto").tag(UUID?.none)
                    ForEach(state.sortedProjects) { project in Text(project.name).tag(Optional(project.id)) }
                }
                TextField("Primo messaggio (facoltativo)", text: $message, axis: .vertical).lineLimit(2...5)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }
                Button("Apri chat") {
                    let project = projectID.flatMap { id in state.projects.first { $0.id == id } }
                    state.newChildChat(title: title, project: project, firstMessage: message)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear { projectID = state.current?.projectID }
    }
}

// MARK: - Come ho lavorato

/// Riga discreta sopra la risposta: quali strumenti ha usato l'assistente, con esiti e tempi.
/// «Anonimizzato prima dell'invio a Claude · 12 dati: 3 nomi, 2 codici fiscali…», con i dati sostituiti
/// (visibili solo qui, sul Mac: il modello ha ricevuto i segnaposto).
struct PrivacyRow: View {
    let report: PrivacyReport
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: "lock.shield.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.green)
                    Text("Anonimizzato prima dell'invio a \(report.destination) · \(report.total) \(report.total == 1 ? "dato" : "dati"): \(report.summary)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("I dati veri restano sul Mac: \(report.destination) ha ricevuto solo i segnaposto e la risposta è stata ricostruita qui.")
            .accessibilityLabel("Anonimizzati \(report.total) dati prima dell'invio a \(report.destination)")
            .accessibilityHint(expanded ? String(localized: "Nascondi i dati") : String(localized: "Mostra i dati sostituiti"))

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                        ForEach(report.placeholders, id: \.self) { placeholder in
                            GridRow {
                                Text(placeholder).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                Text(report.values[placeholder] ?? "—").font(.system(size: 12)).textSelection(.enabled)
                            }
                        }
                    }
                    Text("Visibili solo qui, sul Mac: \(report.destination) ha ricevuto i segnaposto.")
                        .font(DS.Fonts.micro).foregroundStyle(.tertiary)
                }
                .padding(.leading, 22)
                .transition(.opacity)
            }
        }
    }
}

struct TraceRow: View {
    let trace: RequestTrace
    /// `--expand-traces`: aperta subito (per le foto di prova).
    @State private var expanded = ProcessInfo.processInfo.arguments.contains("--expand-traces")
    private var seconds: String {
        (Double(trace.totalMilliseconds) / 1000).formatted(.number.precision(.fractionLength(1)).locale(Language.system.locale))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: trace.steps.allSatisfy(\.ok) ? "wand.and.sparkles" : "exclamationmark.triangle")
                        .symbolRenderingMode(.hierarchical)
                    Text(trace.steps.count == 1 ? String(localized: "Come ho lavorato · 1 passaggio · \(seconds) s") : String(localized: "Come ho lavorato · \(trace.steps.count) passaggi · \(seconds) s"))
                }
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Come ho lavorato: \(trace.steps.count) passaggi")
            .accessibilityHint(expanded ? String(localized: "Comprimi") : String(localized: "Espandi"))

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let rewritten = trace.rewritten {
                        Label("Ho inteso: «\(rewritten)»", systemImage: "text.bubble").font(DS.Fonts.caption).foregroundStyle(.secondary)
                    }
                    if let reasoning = trace.reasoning, !reasoning.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Catena di pensieri", systemImage: "brain").font(DS.Fonts.captionStrong)
                            ForEach(Array(reasoning.enumerated()), id: \.offset) { _, line in
                                Text("· " + line).font(DS.Fonts.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    ForEach(Array(trace.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1)").font(.caption2.monospacedDigit().weight(.semibold))
                                .frame(width: 18, height: 18)
                                .background(step.ok ? Color.accentColor.opacity(0.14) : Color.orange.opacity(0.18), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.label(step.action)).font(DS.Fonts.captionStrong)
                                if !step.detail.isEmpty { Text(step.detail).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2) }
                                Text(step.result).font(DS.Fonts.caption).foregroundStyle(step.ok ? Color.secondary : Color.orange)
                            }
                            Spacer(minLength: 0)
                            Text("\(step.milliseconds) ms").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                    Text("Modello: \(trace.model)").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(10)
                .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Nome leggibile dell'azione.
    static func label(_ action: String) -> String {
        let names = ["agenda": String(localized: "Agenda"), "eventi": String(localized: "Eventi del calendario"), "promemoria": String(localized: "Promemoria"), "calendari": String(localized: "Calendari e liste"),
                     "crea_evento": String(localized: "Nuovo evento"), "crea_promemoria": String(localized: "Nuovo promemoria"), "crea_lista_promemoria": String(localized: "Lista di promemoria"),
                     "elimina_evento": String(localized: "Elimina evento"), "completa_promemoria": String(localized: "Completa promemoria"), "scrivi_email": String(localized: "Bozza email"),
                     "crea_documento": String(localized: "Documento"), "crea_foglio": String(localized: "Foglio"), "crea_presentazione": String(localized: "Presentazione"), "piano": String(localized: "Piano"),
                     "mail_leggi": String(localized: "Posta"), "note": String(localized: "Note"), "file": String(localized: "File sul Mac"), "messaggi": String(localized: "Messaggi"), "crea_nota": String(localized: "Nuova nota"),
                     "invia_messaggio": String(localized: "Messaggio"), "genera_immagine": String(localized: "Immagine"), "ricorda": String(localized: "Memoria"), "file_elenca": String(localized: "Elenco file"),
                     "file_leggi": String(localized: "Lettura file"), "file_cerca": String(localized: "Ricerca nei file"), "file_scrivi": String(localized: "Modifica file"), "file_sposta": String(localized: "Sposta file"),
                     "file_cartella": String(localized: "Nuova cartella"), "file_elimina": String(localized: "Cestino"), "strumento_esterno": String(localized: "Connettore"),
                     "modifica_artefatto": String(localized: "Modifica documento"), "cerca_web": String(localized: "Ricerca sul web"), "leggi_pagina": String(localized: "Lettura pagina"),
                     "naviga": String(localized: "Browser"), "segui_link": String(localized: "Link"), "nuova_chat": String(localized: "Nuova chat"), "crea_agente": String(localized: "Nuovo Genius"),
                     "crea_sito": String(localized: "Pagina web"), "cerca_conversazioni": String(localized: "Conversazioni passate"), "skill": String(localized: "Skill"),
                     "calcolo": String(localized: "Calcolo esatto"), "immagine": String(localized: "Immagine allegata"), "ragionamento": String(localized: "Ragionamento prima della risposta"),
                     "lettura_a_pezzi": String(localized: "Sub-agent · lettura a pezzi"), "smistatore": String(localized: "Sub-agent · scelta degli strumenti e del piano")]
        if action.hasPrefix("mcp:") { return String(localized: "Connettore · ") + action.dropFirst(4).trimmingCharacters(in: .whitespaces) }
        return names[action] ?? action.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
