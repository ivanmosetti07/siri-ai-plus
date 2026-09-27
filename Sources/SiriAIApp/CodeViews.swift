import AppKit
import SiriCore
import SwiftUI

// MARK: - Home dello spazio Programmazione

/// Home del coding: modelli per partire, progetti recenti, stato di Codex, Claude Code e Xcode.
struct CodeHomeView: View {
    @Environment(AppState.self) private var state

    private var codeProjects: [ProjectModel] { state.sortedProjects }

    var body: some View {
        GlassPage(maxWidth: 940) {
            PageHeader(eyebrow: String(localized: "Programmazione"), title: String(localized: "Dall'idea, al codice."),
                       subtitle: String(localized: "Descrivi un'app o un sito: il modello che scegli (ChatGPT con Codex, Claude con Claude Code, oppure Apple Intelligence e Gemma sul Mac) lo costruisce passo passo, ti mostra ogni modifica e salva un punto di ripristino prima di toccare i file.")) {
                Button {
                    ProjectPicker.choose { state.addCodeProject(folder: $0) }
                } label: { Label("Apri cartella…", systemImage: "folder") }
                .buttonStyle(.glass)
                Menu {
                    ForEach(CodeTemplate.allCases) { template in
                        Button { state.newCodeTemplate = template } label: { Label(template.label, systemImage: template.symbol) }
                    }
                } label: { Label("Nuovo progetto", systemImage: "plus") }
                .menuIndicator(.hidden)
                .buttonStyle(.glassProminent)
                .tint(.purple)
                .fixedSize()
            }
            engines
            VStack(alignment: .leading, spacing: 12) {
                GroupTitle(text: String(localized: "Inizia un progetto"))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                    ForEach(CodeTemplate.allCases) { template in
                        Button { state.newCodeTemplate = template } label: { TemplateCard(template: template) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if !codeProjects.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    GroupTitle(text: String(localized: "I tuoi progetti"))
                    VStack(spacing: 12) {
                        ForEach(codeProjects) { project in
                            GlassRow(symbol: "folder.fill", colors: Hue.purple, title: project.name,
                                     subtitle: project.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                                     action: { state.section = .project(project.id); state.showAssistant = true }) {
                                if state.devRun(for: project)?.running == true {
                                    Label("In esecuzione", systemImage: "play.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
                                } else {
                                    Text(project.lastOpened.formatted(.relative(presentation: .named).locale(Dates.locale)))
                                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .glassCard(radius: 24)
                }
            }
        }
        .task { await state.models.refresh() }
    }

    private var engines: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { badges }
            VStack(alignment: .leading, spacing: 8) { badges }
        }
    }

    @ViewBuilder private var badges: some View {
        let models = state.models
        EngineBadge(name: String(localized: "Codex"), ok: models.codexInstalled && models.codexLoggedIn,
                    detail: !models.codexInstalled ? String(localized: "non installato") : models.codexLoggedIn ? String(localized: "pronto") : String(localized: "accesso da fare"))
        EngineBadge(name: String(localized: "Claude Code"), ok: models.claudeInstalled && models.claudeLoggedIn,
                    detail: !models.claudeInstalled ? String(localized: "non installato") : models.claudeLoggedIn ? String(localized: "pronto") : String(localized: "accesso da fare"))
        EngineBadge(name: String(localized: "Sul Mac"), ok: state.availabilityProblem == nil,
                    detail: ([String(localized: "Apple Intelligence")] + (models.downloadedVariants.isEmpty ? [] : [String(localized: "Gemma")])).joined(separator: ", "))
        EngineBadge(name: String(localized: "Xcode"), ok: FileManager.default.fileExists(atPath: "/Applications/Xcode.app"), detail: String(localized: "per le app Apple"))
    }
}

private struct EngineBadge: View {
    let name: String
    let ok: Bool
    let detail: String

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(ok ? Color.green : Color.gray.opacity(0.5)).frame(width: 8, height: 8)
                .shadow(color: ok ? .green.opacity(0.7) : .clear, radius: 4)
            Text(name).font(.system(size: 12.5, weight: .semibold))
            Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

private struct TemplateCard: View {
    let template: CodeTemplate
    @State private var hovered = false

    private var colors: [Color] {
        switch template {
        case .sito: Hue.blue
        case .webapp: Hue.teal
        case .swiftui: Hue.orange
        case .vuoto: Hue.gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconBadge(symbol: template.symbol, colors: colors, size: 38)
            Text(template.label).font(.system(size: 15, weight: .semibold))
            Text(template.summary).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        .scaleEffect(hovered ? 1.015 : 1)
        .onHover { hovered = $0 }
        .animation(DS.Motion.quick, value: hovered)
    }
}

// MARK: - Nuovo progetto

struct NewCodeProjectSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let template: CodeTemplate
    @State private var name = ""
    @State private var wish = ""
    @State private var parent = AppState.codeProjectsFolder
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Nome del progetto", text: $name, prompt: Text(template.label))
                        .focused($focused)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cosa vuoi costruire?").font(DS.Fonts.callout)
                        TextEditor(text: $wish)
                            .font(DS.Fonts.body)
                            .frame(minHeight: 110)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                    }
                } header: {
                    Label(template.label, systemImage: template.symbol)
                } footer: {
                    Text(template.summary).font(DS.Fonts.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Cartella") {
                        HStack {
                            Text(parent.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                            Button("Cambia…") { ProjectPicker.choose { parent = $0 } }
                        }
                    }
                    LabeledContent("Modello") {
                        ModelPicker(current: state.codeDefault) { state.chooseCodeModel($0, for: nil) }
                    }
                    if let problem = state.codeModelProblem(state.codeDefault) {
                        Text(problem).font(DS.Fonts.caption).foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Crea progetto") {
                    state.createCodeProject(template: template, name: name, description: wish, parent: parent)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(state.codeModelProblem(state.codeDefault) != nil)
            }
            .padding(DS.Space.lg)
        }
        .frame(width: 540)
        .onAppear {
            focused = true
        }
    }
}

// MARK: - Area di lavoro del progetto

/// Progetto di codice al centro: file ed editor, e sotto la console del server di sviluppo.
struct CodeWorkspaceView: View {
    @Environment(AppState.self) private var state
    let project: ProjectModel
    private var working: ProjectModel { state.workingCodeProject(project) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !working.exists {
                ContentUnavailableView("Cartella non trovata", systemImage: "exclamationmark.triangle",
                                       description: Text(working.folder.path))
            } else if let run = state.devRun(for: project), !run.lines.isEmpty || run.running {
                VSplitView {
                    CodeFilesView(project: working).id(working.folder.path).frame(minHeight: 240)
                    DevConsole(run: run) { state.stopProject(project) }
                        .clipShape(.rect(cornerRadius: 20))
                        .glassCard(radius: 20)
                        .padding(.horizontal, 20).padding(.bottom, 16)
                        .frame(minHeight: 120, idealHeight: 180)
                }
            } else {
                CodeFilesView(project: working).id(working.folder.path)
            }
        }
    }

    private var header: some View {
        let command = DevCommand.detect(in: working.folder)
        let run = state.devRun(for: project)
        let isolated = state.currentCodeSession?.isolation == .worktree
        return VStack(alignment: .leading, spacing: 10) {
            PageHeader(eyebrow: isolated ? String(localized: "Progetto di codice · copia isolata") : String(localized: "Progetto di codice"), title: project.name) {
                Menu {
                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([working.folder]) }
                    Button("Apri nel Terminale") { NSWorkspace.shared.open([working.folder], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: .init()) }
                    if FileManager.default.fileExists(atPath: "/Applications/Xcode.app") {
                        Button("Apri in Xcode") { NSWorkspace.shared.open([working.folder], withApplicationAt: URL(fileURLWithPath: "/Applications/Xcode.app"), configuration: .init()) }
                    }
                    if let url = run?.url ?? command?.page {
                        Button("Apri in Safari (l'app)") {
                            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/Applications/Safari.app"), configuration: .init())
                        }
                    }
                    Divider()
                    Button("Modifica le regole (AGENTS.md)") { state.openProjectFile(project, path: "AGENTS.md") }
                } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .fixedSize()
                .iconHelp(String(localized: "Altre azioni"))
                runButtons(command: command, run: run)
            }
            HStack(spacing: 8) {
                Label(working.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                if let session = state.currentCodeSession, session.isolation == .worktree {
                    Text(session.workingFolder == nil
                         ? String(localized: "La copia sarà creata al primo invio")
                         : String(localized: "Applica le modifiche dalla revisione"))
                        .foregroundStyle(.purple)
                }
                // Le app aperte in questa sessione (Safari con l'anteprima, Note…): restano con lei.
                ForEach(state.appTabs.filter { $0 != .launcher }, id: \.self) { tab in
                    Button { withAnimation(.smooth(duration: 0.35)) { state.selectTab(tab) } } label: {
                        HStack(spacing: 5) {
                            AppTabIcon(tab: tab, size: 14)
                            Text(state.title(of: tab)).lineLimit(1)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .frame(maxWidth: 170)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .help("Apri \(state.title(of: tab)), aperta in questa sessione")
                }
            }
            .font(.system(size: 12.5, weight: .medium))
        }
        .padding(.horizontal, 32)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    /// Anteprima (siti e app web nel Safari della sessione, con la chat del coding sempre a destra), avvio e stop.
    @ViewBuilder
    private func runButtons(command: DevCommand?, run: DevRun?) -> some View {
        switch command?.kind {
        case .staticPage?:
            Button { state.openPreview(project) } label: { Label("Anteprima", systemImage: "safari") }
                .buttonStyle(.glassProminent)
                .tint(.purple)
                .help("Apri il sito nel Safari di questa sessione: la chat resta a destra")
        case .server?:
            if let run, run.running {
                Button { state.openPreview(project) } label: { Label("Anteprima", systemImage: "safari") }
                    .buttonStyle(.glassProminent)
                    .tint(.purple)
                    .disabled(run.url == nil)
                    .help(run.url == nil ? String(localized: "Il server sta partendo…") : String(localized: "Apri l'app web nel Safari di questa sessione"))
                Button(role: .destructive) { state.stopProject(project) } label: { Label("Ferma", systemImage: "stop.fill") }
                    .buttonStyle(.glass)
            } else {
                Button { state.openPreview(project) } label: { Label("Avvia e mostra", systemImage: "play.fill") }
                    .buttonStyle(.glassProminent)
                    .tint(.purple)
                    .help("Avvia il server di sviluppo (\(command?.label ?? "")) e apri l'anteprima")
            }
        default:
            if let run, run.running {
                Button(role: .destructive) { state.stopProject(project) } label: { Label("Ferma", systemImage: "stop.fill") }
                    .buttonStyle(.glass)
            } else {
                Button { state.runProject(project) } label: { Label(command?.label ?? String(localized: "Esegui"), systemImage: command?.kind == .xcode ? "hammer.fill" : "play.fill") }
                    .buttonStyle(.glassProminent)
                    .tint(.purple)
                    .disabled(command == nil)
                    .help(command == nil ? String(localized: "Non so ancora come avviare questo progetto: chiedilo all'assistente") : String(localized: "Avvia il progetto (\(command?.label ?? ""))"))
            }
        }
    }
}

/// Uscita del server di sviluppo o del programma.
struct DevConsole: View {
    let run: DevRun
    let stop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text(run.command.label).font(DS.Fonts.captionStrong)
                if run.running { ProgressView().controlSize(.mini) }
                if let url = run.url { Link(url.absoluteString, destination: url).font(DS.Fonts.caption) }
                Spacer()
                if run.running { Button("Ferma", action: stop).controlSize(.small) }
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, 6)
            .background(.bar)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(run.lines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.sm)
                    Color.clear.frame(height: 1).id("fine")
                }
                .onChange(of: run.lines.count) { proxy.scrollTo("fine", anchor: .bottom) }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

// MARK: - Pannello dell'agente di coding

/// Colonna destra nei progetti di codice: la sessione con il modello scelto. Resta anche con le app davanti
/// (Safari con l'anteprima del sito): la sessione ha le sue app, come ogni chat.
struct CodePanel: View {
    @Environment(AppState.self) private var state
    let project: ProjectModel
    @State private var input = ""
    @FocusState private var focused: Bool

    private var session: CodeSession? { state.currentCodeSession }
    /// Errori che l'anteprima di questa sessione vede adesso.
    private var previewErrors: [String] { session.flatMap { state.browsers[$0.id]?.consoleErrors } ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let session, !session.events.isEmpty {
                CodeTranscript(session: session)
            } else {
                emptyState
            }
            composer
        }
        .sheet(isPresented: Binding(get: { session != nil && state.codeReviewSessionID == session?.id },
                                    set: { if !$0 { state.codeReviewSessionID = nil } })) {
            if let session { CodeReviewView(project: project, session: session) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Spacer()
            VStack(spacing: 8) {
                IconBadge(symbol: "chevron.left.forwardslash.chevron.right", colors: Hue.purple, size: 44)
                Text("Cosa costruiamo?").font(DS.Fonts.section)
                Text("Lavora \(state.codeEngineLabel(session?.selection ?? state.codeDefault)). Ogni richiesta parte da un punto di ripristino; il sito si prova con «Anteprima», qui accanto.")
                    .font(DS.Fonts.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
            ForEach(suggestions, id: \.self) { text in
                SuggestionRow(symbol: "sparkle", text: text) { send(text) }
            }
            Spacer()
        }
        .padding(DS.Space.md)
    }

    private var suggestions: [String] {
        let folder = state.workingCodeProject(project).folder
        func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appending(path: name).path) }
        if has("package.json") { return [String(localized: "Spiegami la struttura del progetto"), String(localized: "Aggiungi una pagina di contatti"), String(localized: "Trova e correggi gli errori di TypeScript")] }
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.contains(where: { $0.hasSuffix(".xcodeproj") }) == true {
            return [String(localized: "Spiegami la struttura dell'app"), String(localized: "Aggiungi una schermata delle impostazioni"), String(localized: "Compila e correggi gli errori")]
        }
        if has("index.html") { return [String(localized: "Controlla la pagina e correggi gli errori"), String(localized: "Rendi il sito responsive e aggiungi il tema scuro"), String(localized: "Aggiungi un modulo di contatto")] }
        return [String(localized: "Crea un sito di presentazione con index.html, style.css e script.js"), String(localized: "Crea un piccolo gioco nel browser"), String(localized: "Spiegami come iniziare")]
    }

    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            Menu {
                ForEach(state.codeSessions(for: project)) { item in
                    Button { state.selectCodeSession(item) } label: {
                        if item.id == session?.id { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                    }
                }
                Divider()
                Button("Nuova sessione") { state.newCodeSession(in: project) }
                if let session {
                    Button(session.workingFolder == nil ? String(localized: "Elimina questa sessione") : String(localized: "Elimina sessione (conserva la copia)"), role: .destructive) {
                        state.deleteCodeSession(session)
                    }
                    .disabled(session.running)
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(session?.title ?? String(localized: "Nuova sessione")).font(DS.Fonts.bodyStrong).lineLimit(1)
                    Text(session.map { $0.running ? String(localized: "\(state.codeWorkerName($0.selection)) al lavoro…") : state.codeEngineLabel($0.selection) }
                         ?? state.codeEngineLabel(state.codeDefault))
                        .font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            if let session {
                Button { state.codeReviewSessionID = session.id } label: { Image(systemName: "square.split.2x1") }
                    .buttonStyle(.borderless)
                    .disabled(session.running || session.events.isEmpty)
                    .iconHelp(String(localized: "Rivedi le modifiche"))
            }
            Button { state.newCodeSession(in: project) } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .iconHelp(String(localized: "Nuova sessione"))
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, 10)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if !previewErrors.isEmpty, session?.running != true {
                Button { state.fixPreviewErrors(previewErrors) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(previewErrors.count == 1 ? String(localized: "1 errore nell'anteprima") : String(localized: "\(previewErrors.count) errori nell'anteprima")).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("Correggi").fontWeight(.semibold)
                    }
                    .font(DS.Fonts.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(previewErrors.prefix(4).joined(separator: "\n"))
            }
            TextField(session?.mode == .plan ? String(localized: "Chiedi un piano (non modifico i file)…") : String(localized: "Descrivi cosa fare nel codice…"), text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Fonts.message)
                .lineLimit(1...10)
                .focused($focused)
                .onSubmit { send(input) }
            HStack(spacing: 6) {
                ModelPicker(current: session?.selection ?? state.codeDefault, compact: true) { state.chooseCodeModel($0, for: session) }
                    .disabled(session?.running == true)
                    .layoutPriority(1)
                if let session { optionsMenu(session) }
                Spacer(minLength: 4)
                if session?.applied == true {
                    Button("Nuova sessione") { state.newCodeSession(in: project) }
                        .font(DS.Fonts.caption)
                        .help("Le modifiche della copia isolata sono già state applicate")
                }
                if session?.running == true {
                    Button { if let session { state.cancelCode(session) } } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 28, height: 28).background(Color.primary.opacity(0.75), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .iconHelp(String(localized: "Interrompi"))
                } else {
                    Button { send(input) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.35) : Color.purple, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session?.applied == true)
                    .keyboardShortcut(.return, modifiers: .command)
                    .iconHelp(String(localized: "Invia (⌘↩)"))
                }
            }
        }
        .padding(DS.Space.md)
        .glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.composer))
        .padding(DS.Space.sm)
        .onAppear { focused = true }
    }

    /// Modalità e cartella di lavoro in un menu solo: «Modifica» o «Chiedi prima», cartella originale o copia isolata.
    private func optionsMenu(_ session: CodeSession) -> some View {
        let isolationLocked = session.running || session.workingFolder != nil || session.events.contains(where: { $0.snapshot != nil })
        return Menu {
            Section("Modalità") {
                ForEach(CodeMode.allCases) { mode in
                    Button { session.mode = mode; state.saveCodeSessions() } label: {
                        if mode == session.mode { Label(mode.label, systemImage: "checkmark") } else { Text(mode.label) }
                    }
                }
            }
            Section(isolationLocked ? String(localized: "Dove lavora (si sceglie prima della prima richiesta)") : String(localized: "Dove lavora")) {
                ForEach(CodeIsolation.allCases, id: \.self) { option in
                    Button { session.isolation = option; state.saveCodeSessions() } label: {
                        if option == session.isolation { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                    }
                    .disabled(isolationLocked)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: session.mode == .plan ? "text.bubble" : session.isolation == .worktree ? "square.on.square" : "pencil")
                    .font(.system(size: 11, weight: .medium))
                Text(session.mode.label).font(DS.Fonts.caption).lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("«Modifica»: l'assistente lavora sui file (con punto di ripristino). «Chiedi prima»: propone un piano senza toccare nulla. La copia isolata richiede un repository Git pulito.")
    }

    private func send(_ text: String) {
        let session = session ?? state.newCodeSession(in: project)
        guard !session.applied else { return }
        state.sendCode(text, in: session)
        input = ""
    }
}

/// La sessione di coding come una chat: le richieste, le risposte e, raccolti in un riquadro che si apre, i passaggi del
/// lavoro (letture, comandi, file cambiati), come nelle app di Codex e Claude Code.
struct CodeTranscript: View {
    @Environment(AppState.self) private var state
    let session: CodeSession

    struct Block: Identifiable {
        enum Kind { case event(CodeEvent), work([CodeEvent]) }
        let id: UUID
        let kind: Kind
    }

    /// I passaggi consecutivi (ragionamento, strumenti, comandi, file) diventano un riquadro solo.
    static func blocks(_ events: [CodeEvent]) -> [Block] {
        var blocks: [Block] = []
        var work: [CodeEvent] = []
        func flush() {
            guard let first = work.first else { return }
            blocks.append(Block(id: first.id, kind: .work(work)))
            work = []
        }
        for event in events {
            switch event.kind {
            case .thinking, .tool, .command, .file: work.append(event)
            // «Fatto» senza altro non dice nulla: il riepilogo dei file lo sostituisce.
            case .result where event.text == "Fatto" && event.detail.isEmpty && event.status != .failed: continue
            default:
                flush()
                blocks.append(Block(id: event.id, kind: .event(event)))
            }
        }
        flush()
        return blocks
    }

    var body: some View {
        let blocks = Self.blocks(session.events)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.md) {
                    ForEach(blocks) { block in
                        switch block.kind {
                        case .event(let event): CodeEventRow(event: event, session: session)
                        case .work(let events): CodeWorkGroup(events: events, session: session, live: session.running && block.id == blocks.last?.id)
                        }
                    }
                    if session.running {
                        HStack(spacing: DS.Space.sm) {
                            ProgressView().controlSize(.small)
                            Text("\(state.codeWorkerName(session.selection)) sta lavorando…").font(DS.Fonts.caption).foregroundStyle(.secondary)
                        }
                        .id("lavoro")
                    }
                    Color.clear.frame(height: 1).id("fine")
                }
                .padding(DS.Space.md)
            }
            .onChange(of: session.events.count) { withAnimation(DS.Motion.quick) { proxy.scrollTo("fine", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("fine", anchor: .bottom) }
        }
    }
}

/// Un riquadro con i passaggi di lavoro: aperto mentre l'agente lavora, chiuso a lavoro finito (si riapre con un clic).
struct CodeWorkGroup: View {
    let events: [CodeEvent]
    let session: CodeSession
    let live: Bool
    @State private var open: Bool?

    private var expanded: Bool { open ?? live }

    private var summary: String {
        let files = Set(events.filter { $0.kind == .file }.compactMap(\.path)).count
        let commands = events.filter { $0.kind == .command }.count
        let reads = events.filter { $0.kind == .tool }.count
        var parts: [String] = []
        if reads > 0 { parts.append(reads == 1 ? String(localized: "1 lettura") : String(localized: "\(reads) letture")) }
        if commands > 0 { parts.append(commands == 1 ? String(localized: "1 comando") : String(localized: "\(commands) comandi")) }
        if files > 0 { parts.append(files == 1 ? String(localized: "1 file cambiato") : String(localized: "\(files) file cambiati")) }
        if parts.isEmpty { return events.contains { $0.kind == .thinking } ? String(localized: "Ragionamento") : String(localized: "\(events.count) passaggi") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(DS.Motion.quick) { open = !expanded } } label: {
                HStack(spacing: 7) {
                    if live, events.contains(where: { $0.status == .running }) || events.last?.kind == .thinking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.tertiary)
                    }
                    Text(summary).font(DS.Fonts.captionStrong).foregroundStyle(.secondary)
                    if events.contains(where: { $0.status == .failed }) {
                        Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange)
                            .help("Qualche passaggio non è riuscito")
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(events) { event in CodeEventRow(event: event, session: session) }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1.5).padding(.leading, 3) }
                .transition(.opacity)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Revisione leggibile prima di applicare una copia isolata al progetto.
struct CodeReviewView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let project: ProjectModel
    let session: CodeSession
    @State private var review: CodeReviewResult?
    @State private var selected: String?

    private var file: CodeReviewFile? { review?.files.first { $0.path == selected } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.split.2x1").foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Revisione modifiche").font(DS.Fonts.section)
                    Text(session.isolation == .worktree ? String(localized: "Copia isolata rispetto al commit iniziale") : String(localized: "Cartella originale dall'ultima richiesta"))
                        .font(DS.Fonts.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let review {
                    Text("\(review.files.count) file  +\(review.added) −\(review.removed)")
                        .font(DS.Fonts.captionStrong).foregroundStyle(.secondary)
                }
                Button("Chiudi") { dismiss() }
            }
            .padding(16)
            Divider()
            if let review {
                if let error = review.error {
                    ContentUnavailableView("Revisione non disponibile", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if review.files.isEmpty {
                    ContentUnavailableView("Nessuna modifica", systemImage: "checkmark.circle", description: Text("Non ci sono differenze da rivedere."))
                } else {
                    HSplitView {
                        List(selection: $selected) {
                            ForEach(review.files) { file in
                                HStack(spacing: 8) {
                                    Text(file.status).font(.system(.caption, design: .monospaced)).foregroundStyle(file.status == "D" ? .red : .green)
                                    Text(file.path).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("+\(file.added) −\(file.removed)").font(DS.Fonts.micro).foregroundStyle(.secondary)
                                }
                                .tag(file.path)
                            }
                        }
                        .frame(minWidth: 230, idealWidth: 290)
                        if let file {
                            ScrollView([.vertical, .horizontal]) {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(file.patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                                        Text(String(line))
                                            .font(.system(size: 11, design: .monospaced))
                                            .textSelection(.enabled)
                                            .foregroundStyle(line.hasPrefix("+") ? .green : line.hasPrefix("-") ? .red : .primary)
                                            .padding(.horizontal, 12)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(line.hasPrefix("+") ? Color.green.opacity(0.09) : line.hasPrefix("-") ? Color.red.opacity(0.09) : .clear)
                                    }
                                }
                                .padding(.vertical, 10)
                            }
                            .frame(minWidth: 460)
                        } else {
                            ContentUnavailableView("Seleziona un file", systemImage: "doc.text.magnifyingglass")
                                .frame(minWidth: 460)
                        }
                    }
                    if review.truncated {
                        Text("Alcuni diff sono troppo grandi per essere mostrati. Apri i file prima di applicare le modifiche.")
                            .font(DS.Fonts.caption).foregroundStyle(.orange).padding(10)
                    }
                }
            } else {
                ProgressView("Preparo il diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if session.isolation == .worktree, let review, review.error == nil {
                Divider()
                HStack {
                    Text(session.applied ? String(localized: "Modifiche già applicate. La copia resta disponibile per consultazione.") : String(localized: "Il progetto originale verrà modificato solo quando applichi."))
                        .font(DS.Fonts.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Applica al progetto") {
                        if let revision = review.revision { state.applyCodeWorktree(session, reviewedRevision: revision); dismiss() }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.applied || session.running || review.files.isEmpty || review.truncated || review.revision == nil)
                }
                .padding(14)
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .task {
            let base = session.isolation == .worktree
                ? session.baseRevision
                : session.events.last(where: { $0.kind == .user && $0.snapshot != nil })?.snapshot
            guard let base else {
                review = CodeReviewResult(files: [], error: String(localized: "Invia una richiesta prima di aprire la revisione."))
                return
            }
            let loaded = await CodeReview.inspect(project: project.folder,
                                                  workingFolder: session.workingFolder ?? project.folder,
                                                  isolation: session.isolation, base: base)
            review = loaded
            selected = loaded.files.first?.path
        }
    }
}

struct CodeEventRow: View {
    @Environment(AppState.self) private var state
    let event: CodeEvent
    let session: CodeSession
    @State private var expanded = false

    var body: some View {
        switch event.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                Text(event.text)
                    .font(DS.Fonts.message)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
                if event.snapshot != nil, !session.running {
                    Button { state.restoreCode(session, to: event) } label: {
                        Label("Ripristina a prima di questo messaggio", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.link)
                    .font(DS.Fonts.micro)
                    .help("Riporta i file com'erano prima di questa richiesta (i file nuovi vanno nel Cestino)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .text:
            RichText(text: event.text)
                .modifier(CopyOnHover(text: event.text))
        case .thinking:
            DisclosureGroup(isExpanded: $expanded) {
                Text(event.text).font(DS.Fonts.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } label: {
                Label("Ragionamento", systemImage: "brain").font(DS.Fonts.caption).foregroundStyle(.secondary)
            }
        case .command:
            VStack(alignment: .leading, spacing: 4) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        statusIcon
                        Text("$ " + event.text).font(.system(.caption, design: .monospaced)).lineLimit(expanded ? nil : 1)
                        Spacer(minLength: 0)
                        if !event.detail.isEmpty { Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded, !event.detail.isEmpty {
                    ScrollView {
                        Text(event.detail).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .padding(6)
                    .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                }
            }
            .padding(8)
            .glassCard(radius: 16)
        case .file:
            HStack(spacing: 6) {
                statusIcon
                Text(event.text).font(DS.Fonts.caption).foregroundStyle(.secondary)
                if let path = event.path {
                    Button(relative(path)) { open(path) }
                        .buttonStyle(.link)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Apri nell'editor")
                }
                Spacer(minLength: 0)
            }
        case .todo:
            VStack(alignment: .leading, spacing: 4) {
                Label("Cose da fare", systemImage: "checklist").font(DS.Fonts.captionStrong)
                ForEach(Array(event.todos.enumerated()), id: \.offset) { _, todo in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: todo.done ? "checkmark.circle.fill" : "circle").foregroundStyle(todo.done ? .green : .secondary).font(.caption)
                        Text(todo.text).font(DS.Fonts.caption).strikethrough(todo.done).foregroundStyle(todo.done ? .secondary : .primary)
                    }
                }
            }
            .padding(10)
            .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        case .tool:
            HStack(spacing: 6) { statusIcon; Text(event.text).font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(1) }
        case .error:
            VStack(alignment: .leading, spacing: 4) {
                Label(event.text, systemImage: "exclamationmark.triangle.fill").font(DS.Fonts.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if !event.detail.isEmpty {
                    Text(event.detail).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .result:
            resultCard
        }
    }

    /// Fine di una richiesta: i file cambiati (si aprono con un clic) e cosa fare dopo: anteprima, revisione, ripristino.
    private var resultCard: some View {
        let files = event.detail.split(separator: "\n").map { line -> (symbol: String, path: String) in
            let parts = line.split(separator: " ", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : ("•", String(line))
        }
        let project = state.projects.first { $0.id == session.projectID }
        let web = project.flatMap { DevCommand.detect(in: state.workingCodeProject($0).folder) }?.kind
        return VStack(alignment: .leading, spacing: 8) {
            Label(event.text, systemImage: event.status == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(DS.Fonts.captionStrong)
                .foregroundStyle(event.status == .failed ? .orange : .green)
            if !files.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(files.prefix(12).enumerated()), id: \.offset) { _, file in
                        Button { open(file.path) } label: {
                            HStack(spacing: 4) {
                                Text(file.symbol == "+" ? String(localized: "Nuovo") : file.symbol == "−" ? String(localized: "Tolto") : String(localized: "Modificato"))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(file.symbol == "+" ? .green : file.symbol == "−" ? .red : .blue)
                                Text(file.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .frame(maxWidth: 230)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(file.symbol == "−")
                        .help(file.symbol == "−" ? file.path : String(localized: "Apri \(file.path) nell'editor"))
                    }
                    if files.count > 12 { Text("e altri \(files.count - 12)").font(DS.Fonts.micro).foregroundStyle(.secondary) }
                }
            }
            if !session.running, let project, event.status != .failed, !files.isEmpty {
                HStack(spacing: 8) {
                    if web == .staticPage || web == .server {
                        Button { state.openPreview(project) } label: { Label("Anteprima", systemImage: "safari") }
                    }
                    Button { state.codeReviewSessionID = session.id } label: { Label("Rivedi", systemImage: "square.split.2x1") }
                    if let user = session.events.last(where: { $0.kind == .user && $0.date <= event.date && $0.snapshot != nil }) {
                        Button { state.restoreCode(session, to: user) } label: { Label("Annulla", systemImage: "arrow.uturn.backward") }
                            .help("Riporta i file com'erano prima di «\(user.text.prefix(40))» (i file nuovi vanno nel Cestino)")
                    }
                }
                .buttonStyle(.borderless)
                .font(DS.Fonts.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(event.status == .failed ? 0 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private var statusIcon: some View {
        switch event.status {
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.green)
        case .failed: Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.orange)
        }
    }

    private func relative(_ path: String) -> String {
        guard let project = state.projects.first(where: { $0.id == session.projectID }) else { return path }
        guard path.hasPrefix("/") else { return path }
        let root = (session.workingFolder ?? project.folder).standardizedFileURL.resolvingSymlinksInPath().path
        let full = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return full.hasPrefix(root + "/") ? String(full.dropFirst(root.count + 1)) : path
    }

    private func open(_ path: String) {
        guard let project = state.projects.first(where: { $0.id == session.projectID }) else { return }
        state.openProjectFile(project, path: relative(path))
    }
}
