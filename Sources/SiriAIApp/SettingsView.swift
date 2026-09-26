import AVFoundation
import ServiceManagement
import SiriCore
import SwiftUI

/// Impostazioni: finestra separata (⌘,) con le schede in alto, come nelle app Apple.
struct SettingsView: View {
    @Environment(AppState.self) private var state

    enum Tab: String, CaseIterable, Identifiable {
        case generale = "Generale", spazi = "Spazi", modelli = "Modelli", skill = "Skill", voce = "Voce", agenti = "Sub-agent",
             app = "App", memoria = "Memoria", privacy = "Privacy"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .generale: "gearshape"
            case .spazi: "square.stack.3d.up"
            case .modelli: "cpu"
            case .skill: "wand.and.stars"
            case .voce: "waveform"
            case .agenti: "person.3"
            case .app: "square.grid.2x2"
            case .memoria: "brain"
            case .privacy: "hand.raised"
            }
        }
    }

    @State private var tab = Tab.generale
    var body: some View {
        TabView(selection: $tab) {
            ForEach(Tab.allCases) { item in
                page(item)
                    .tabItem { Label(LocalizedStringKey(item.rawValue), systemImage: item.symbol) }
                    .tag(item)
            }
        }
        .frame(width: 760)
        .frame(minHeight: 560, idealHeight: 640)
        .onChange(of: state.settingsTab, initial: true) { _, requested in
            if let requested, let match = Tab.allCases.first(where: { $0.rawValue.lowercased() == requested.lowercased() || "\($0)" == requested }) {
                tab = match
            }
            state.settingsTab = nil
        }
    }

    @ViewBuilder
    private func page(_ item: Tab) -> some View {
        switch item {
        case .generale: Form { GeneralSettings() }.formStyle(.grouped)
        case .modelli: Form { ModelsSettings() }.formStyle(.grouped)
        case .voce: Form { VoiceSettings() }.formStyle(.grouped)
        case .agenti: Form { AgentSettings() }.formStyle(.grouped)
        case .privacy: Form { PrivacySettings() }.formStyle(.grouped)
        case .skill: SkillsSettings()
        case .spazi: ScrollView { SpacesSettings().padding(DS.Space.xl) }
        case .app: ScrollView { VStack(alignment: .leading, spacing: DS.Space.xl) { PermissionsPanel(); SourcesList(highlight: nil) }.padding(DS.Space.xl) }
        case .memoria: ScrollView { MemorySettings().padding(DS.Space.xl) }
        }
    }
}

/// Gruppo di impostazioni: una sezione del modulo raggruppato di sistema.
private struct SettingsGroup<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        Section {
            content
        } header: {
            Text(title)
        } footer: {
            if let footnote { Text(footnote).font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

// MARK: - Generale

private struct GeneralSettings: View {
    @Environment(AppState.self) private var state
    @State private var city = ""
    @State private var loginMessage: String?

    var body: some View {
        @Bindable var state = state
        SettingsGroup(title: String(localized: "Meteo nella Home"),
                      footnote: String(localized: "Il cielo della Home segue il meteo vero. Le previsioni arrivano da Open-Meteo, un servizio gratuito: riceve solo il nome della città o la posizione del Mac arrotondata a circa 1 km.")) {
            HStack {
                TextField("Città", text: $city, prompt: Text("Roma"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .onSubmit { applyCity() }
                Button("Usa") { applyCity() }
                    .disabled(city.trimmingCharacters(in: .whitespaces).isEmpty || city == state.weather.city)
            }
            Toggle("Usa la posizione del Mac al posto della città", isOn: Binding(get: { state.weather.usesLocation }, set: { state.weather.usesLocation = $0 }))
                .toggleStyle(.switch)
            if let snapshot = state.weather.snapshot {
                Label("\(snapshot.place): \(WeatherSnapshot.degrees(snapshot.temperature)), \(snapshot.condition.label.lowercased()) · aggiornato \(Dates.friendly(snapshot.fetched))",
                      systemImage: snapshot.symbol)
                    .font(DS.Fonts.caption).foregroundStyle(.secondary)
            }
            if let error = state.weather.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(DS.Fonts.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { city = state.weather.city }
        SettingsGroup(title: String(localized: "Ricerca sul web"), footnote: String(localized: "Per notizie, prezzi, meteo, risultati o quando il modello non conosce la risposta, Siri AI+ cerca con il browser e legge le prime pagine. Le domande escono dal Mac solo in questo caso.")) {
            Toggle("Cerca sul web quando serve", isOn: $state.webEnabled).toggleStyle(.switch)
        }
        SettingsGroup(title: String(localized: "Conversazione"), footnote: String(localized: "Quando la conversazione riempie la finestra del modello, Siri AI+ la riassume e continua con il riassunto.")) {
            Text("Compattazione automatica al \(Int(state.compactionThreshold * 100))% del contesto").font(DS.Fonts.body)
            Slider(value: Binding(get: { state.compactionThreshold }, set: { state.compactionThreshold = $0; state.memoryRevision += 1 }), in: 0.6...0.9, step: 0.05)
                .frame(maxWidth: 360)
        }
        SettingsGroup(title: String(localized: "Scorciatoie")) {
            LabeledContent("Chat rapida, in ogni app", value: "⌥⌘K")
            LabeledContent("Modalità vocale", value: "⌥⌘V")
            LabeledContent("Mostra o nascondi Siri AI+ a destra", value: "⌥⌘S")
            LabeledContent("Impostazioni", value: "⌘,")
        }
        SettingsGroup(title: String(localized: "Companion sul Mac"), footnote: String(localized: "Chiudere la finestra lascia disponibili la chat rapida e i Genius. Il comando Esci li ferma fino alla prossima apertura.")) {
            Toggle("Avvia Siri AI+ all'accesso", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        loginMessage = SMAppService.mainApp.status == .requiresApproval
                            ? String(localized: "Completa l'autorizzazione in Impostazioni di Sistema › Generali › Elementi login.") : nil
                    } catch { loginMessage = error.localizedDescription }
                }))
                .toggleStyle(.switch)
            if let loginMessage { Text(loginMessage).font(DS.Fonts.caption).foregroundStyle(.secondary) }
        }
    }
}

extension GeneralSettings {
    fileprivate func applyCity() {
        let name = city.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        state.weather.city = name
    }
}

// MARK: - Modelli

private struct ModelsSettings: View {
    @Environment(AppState.self) private var state
    @State private var confirmClaudeLogout = false
    var body: some View {
        let models = state.models
        @Bindable var state = state
        SettingsGroup(title: String(localized: "Modello per le risposte"),
                      footnote: String(localized: "Con Apple Intelligence il Mac capisce la richiesta e sceglie gli strumenti. Gli altri modelli, se l'opzione è attiva, usano da soli gli stessi strumenti dell'app (calendario, email, file, web, connettori): quello che crea o invia resta sempre una scheda da confermare. Ogni chat ricorda il suo modello: per ChatGPT e Claude scegli versione e ragionamento dal menu sotto il campo di scrittura.")) {
            Picker("Risponde", selection: Binding(get: { state.selection.provider }, set: { choice in
                state.request(choice)
            })) {
                ForEach(ResponseProvider.allCases) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            .pickerStyle(.radioGroup)
            Label("Finestra di contesto: \(state.contextBudget.label). Siri AI+ adatta a questo spazio quante pagine web, quanto testo dei file e quanta conversazione passare al modello.",
                  systemImage: "rectangle.stack")
                .font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Gli altri modelli usano gli strumenti dell'app", isOn: $state.externalTools)
                .toggleStyle(.switch)
                .help("Gemma, ds4, ChatGPT e Claude leggono calendario, email, file e web da soli e preparano le schede da confermare")
            if !state.selection.provider.isLocal {
                if state.cloudPrivacy && (state.selection.provider == .chatgpt || state.selection.provider == .claude) {
                    Label("Le conversazioni vanno a \(state.selection.provider.company) anonimizzate sul Mac: i dati veri non escono.", systemImage: "lock.shield.fill")
                        .font(DS.Fonts.caption).foregroundStyle(.green)
                } else {
                    Label("Le conversazioni vengono inviate a \(state.selection.provider.company): la privacy non è più garantita dal modello locale.", systemImage: "exclamationmark.shield.fill")
                        .font(DS.Fonts.caption).foregroundStyle(.orange)
                }
            }
        }

        SettingsGroup(title: String(localized: "Anonimizzazione verso ChatGPT e Claude"),
                      footnote: String(localized: "Prima di ogni invio a ChatGPT o Claude, Siri AI+ sostituisce sul Mac i dati personali con segnaposto come [FULLNAME_1] o [IBAN_1]: quello che scrivi, la cronologia, la memoria, le istruzioni del progetto, i file, le email e i risultati degli strumenti. Importi, date, orari, città, aziende e siti restano in chiaro, perché all'AI servono per fare conti, confronti e ricerche; puoi nasconderli qui sotto. Il dizionario resta sul Mac, con la chat, e la risposta torna leggibile; gli strumenti usano i dati veri sul Mac. Motore rizzo-pii di Rizzo AI Academy (licenza MIT), convertito per girare sul Mac: circa 35 ms ogni 120 parole.")) {
            Toggle("Anonimizza prima di inviare a ChatGPT e Claude", isOn: $state.cloudPrivacy).toggleStyle(.switch)
            status(String(localized: "Motore rizzo-pii"), ok: PIIEngine.isInstalled,
                   detail: PIIEngine.isInstalled ? String(localized: "sul Mac · solo i dati personali · dizionario per chat") : String(localized: "non installato (Support/rizzo-pii/install.sh)"))
            if state.cloudPrivacy {
                Label("Sempre nascosti: " + PIICategory.sensitive.filter { $0 != "BUILDINGNUM" }.map(PIICategory.name).joined(separator: ", ") + ".",
                      systemImage: "eye.slash")
                    .font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Nascondi anche (di solito servono all'AI per lavorare)") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(PIICategory.workingData, id: \.self) { label in
                            Toggle(PIICategory.name(label).prefix(1).uppercased() + PIICategory.name(label).dropFirst(), isOn: Binding(
                                get: { state.cloudPrivacyExtra.contains(label) },
                                set: { hide in if hide { state.cloudPrivacyExtra.insert(label) } else { state.cloudPrivacyExtra.remove(label) } }))
                                .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(DS.Fonts.caption)
            }
            if state.cloudPrivacy && !PIIEngine.isInstalled {
                Label("Finché il motore non c'è, niente parte verso ChatGPT e Claude: risponde Apple Intelligence sul Mac.", systemImage: "lock.shield")
                    .font(DS.Fonts.caption).foregroundStyle(.orange)
            }
            if !state.cloudPrivacy {
                Label("Spenta: ChatGPT e Claude ricevono i dati in chiaro.", systemImage: "exclamationmark.shield.fill")
                    .font(DS.Fonts.caption).foregroundStyle(.orange)
            }
        }

        SettingsGroup(title: String(localized: "Apple Intelligence")) {
            if AppleResponseModel.hasPrivateCloudEntitlement {
                Toggle("Usa Private Cloud Compute quando disponibile", isOn: $state.wantsPrivateCloud)
                    .toggleStyle(.switch)
            }
            HStack {
                Image(systemName: "apple.logo")
                Text(state.availabilityProblem ?? state.appleResponseModel.label).font(DS.Fonts.body)
                Spacer()
                Image(systemName: state.availabilityProblem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(state.availabilityProblem == nil ? .green : .orange)
            }
            if state.availabilityProblem == nil {
                Text(state.appleResponseModel == .privateCloud
                     ? String(localized: "Le risposte usano Private Cloud Compute di Apple. Se il servizio o la quota non è disponibile, l'app continua con il modello sul Mac.")
                     : AppleResponseModel.hasPrivateCloudEntitlement && !state.wantsPrivateCloud
                        ? String(localized: "Private Cloud Compute è disattivato: le risposte restano sul Mac.")
                     : AppleResponseModel.hasPrivateCloudEntitlement
                        ? String(localized: "Private Cloud Compute non è disponibile ora o la quota è esaurita. Le risposte restano sul Mac.")
                        : String(localized: "Private Cloud Compute richiede l'autorizzazione Apple per questa app. Le risposte restano sul Mac."))
                    .font(DS.Fonts.caption).foregroundStyle(.secondary)
                Text("Sul Mac: \(AppleResponseModel.onDeviceSummary). Per problemi, logica e scelte ragiona prima di rispondere (catena di pensieri); i testi più lunghi della sua finestra li leggono sub-agent a pezzi; a ogni risposta riceve gli scambi recenti che ci stanno, i più vecchi pertinenti e il riassunto del resto.")
                    .font(DS.Fonts.caption).foregroundStyle(.secondary)
            }
        }

        SettingsGroup(title: String(localized: "Gemma 4 (Google, locale da Hugging Face)"),
                      footnote: String(localized: "Il modello viene scaricato da Hugging Face sul Mac (\(GemmaVariant.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))) e gira con llama.cpp sulla GPU. Consigliata per questo Mac (\(DeviceProfile.memoryGB) GB): \(DeviceProfile.recommendedGemma.label).")) {
            status("llama.cpp", ok: models.llamaInstalled, detail: models.llamaInstalled ? (models.gemmaRunning ? String(localized: "Gemma in esecuzione") : "installato") : String(localized: "non installato"))
            if !models.llamaInstalled {
                Button(models.brewAvailable ? String(localized: "Installa llama.cpp") : String(localized: "Scarica llama.cpp…")) { models.installLlama() }.disabled(models.isBusy("llama"))
            }
            Divider()
            ForEach(GemmaVariant.all) { variant in
                GemmaRow(variant: variant)
            }
            job(models, keys: ["llama", "gemma-start"])
        }

        SettingsGroup(title: String(localized: "ds4 (antirez, locale)"),
                      footnote: String(localized: "Motore per modelli come DeepSeek V4 Flash. Su Mac serve Apple Silicon con almeno 96 GB di memoria (questo Mac: \(DeviceProfile.memoryGB) GB). Il download del modello pesa decine di GB.")) {
            if DeviceProfile.supportsDS4 {
                status("ds4", ok: models.ds4Running, detail: models.ds4Installed ? (models.ds4Running ? String(localized: "server in esecuzione") : "installato") : String(localized: "non installato"))
                HStack {
                    if !models.ds4Installed { Button("Installa ds4 e scarica il modello") { models.installDS4() }.disabled(models.isBusy("ds4")) }
                    else if !models.ds4Running { Button("Avvia il server ds4") { models.startDS4() }.disabled(models.isBusy("ds4-start")) }
                }
                job(models, keys: ["ds4", "ds4-start"])
            } else {
                Label("Non disponibile su questo Mac: serve più memoria.", systemImage: "xmark.octagon").font(DS.Fonts.body).foregroundStyle(.secondary)
            }
        }

        SettingsGroup(title: String(localized: "ChatGPT (abbonamento)"),
                      footnote: String(localized: "Usa il tuo abbonamento ChatGPT tramite la CLI ufficiale Codex di OpenAI: l'accesso avviene nel browser con il tuo account. I modelli sono quelli del tuo account (\(models.codexModels.isEmpty ? String(localized: "l'elenco arriva dopo il primo uso di Codex") : models.codexModels.map(\.label).joined(separator: ", "))).")) {
            status(String(localized: "Codex CLI"), ok: models.codexInstalled && models.codexLoggedIn,
                   detail: !models.codexInstalled ? String(localized: "non installata") : (models.codexLoggedIn ? String(localized: "accesso effettuato") : String(localized: "accesso da fare")))
            HStack {
                if !models.codexInstalled { Button("Installa Codex CLI") { models.installCodex() }.disabled(models.isBusy("codex")) }
                else if !models.codexLoggedIn { Button("Accedi con ChatGPT…") { models.loginCodex() }.disabled(models.isBusy("codex-login")) }
                else { Button("Esci") { models.logoutCodex() } }
            }
            job(models, keys: ["codex", "codex-login"])
        }
        SettingsGroup(title: String(localized: "Claude (abbonamento)"),
                      footnote: String(localized: "Usa il tuo abbonamento Claude (Pro o Max) tramite la CLI ufficiale Claude Code di Anthropic: l'accesso avviene nel browser con il tuo account. Nelle chat e nella Programmazione scegli Fable, Opus, Sonnet o Haiku e quanto ragiona.")) {
            status(String(localized: "Claude Code"), ok: models.claudeInstalled && models.claudeLoggedIn,
                   detail: !models.claudeInstalled ? String(localized: "non installato")
                    : models.claudeLoggedIn ? ([String(localized: "accesso effettuato"), models.claude.email, models.claude.plan?.capitalized].compactMap { $0 }.joined(separator: " · "))
                    : String(localized: "accesso da fare"))
            HStack {
                if !models.claudeInstalled { Button("Installa Claude Code") { models.installClaude() }.disabled(models.isBusy("claude")) }
                else if !models.claudeLoggedIn {
                    Button("Accedi con Claude…") { models.loginClaude() }
                    Button("Aggiorna stato") { Task { await models.refresh() } }
                }
                else { Button("Esci") { confirmClaudeLogout = true } }
            }
            .confirmationDialog("Uscire dall'account Claude?", isPresented: $confirmClaudeLogout) {
                Button("Esci", role: .destructive) { models.logoutClaude() }
            } message: {
                Text("Esci anche da Claude Code nel Terminale: per usarlo di nuovo dovrai rifare l'accesso.")
            }
            job(models, keys: ["claude", "claude-login"])
        }
        .task { await models.refresh() }

    }

    private func status(_ name: String, ok: Bool, detail: String) -> some View {
        HStack {
            Circle().fill(ok ? Color.green : Color.gray.opacity(0.5)).frame(width: 8, height: 8)
            Text(name).font(DS.Fonts.bodyStrong)
            Text(detail).font(DS.Fonts.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private func job(_ models: ModelManager, keys: [String]) -> some View {
        ForEach(keys, id: \.self) { key in
            if let line = models.jobs[key] {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let error = models.errors[key] {
                Text(error).font(DS.Fonts.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
    }
}

// MARK: - Voce

private struct VoiceSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let voice = state.voice
        SettingsGroup(title: String(localized: "Voce di Siri AI+"),
                      footnote: String(localized: "Voci di sistema Apple. Per voci più naturali scarica le versioni «Premium» o «Migliorata» in Impostazioni di Sistema › Accessibilità › Contenuto letto ad alta voce › Voce di sistema.")) {
            Picker("Voce", selection: Binding(get: { voice.voiceIdentifier }, set: { voice.voiceIdentifier = $0 })) {
                Text("Automatica (la migliore installata)").tag("")
                ForEach(VoiceMode.italianVoices, id: \.identifier) { Text(VoiceMode.label($0)).tag($0.identifier) }
            }
            HStack {
                Text("Velocità").font(DS.Fonts.body)
                Slider(value: Binding(get: { voice.rate }, set: { voice.rate = $0 }), in: 0.3...0.7)
                Button("Prova") { voice.preview() }
            }
        }
        SettingsGroup(title: String(localized: "Modalità vocale"), footnote: String(localized: "Parli, fai una pausa e Siri AI+ risponde a voce, poi torna ad ascoltarti. Riconoscimento e voce restano sul Mac.")) {
            Button { voice.start(with: state) } label: { Label("Avvia la modalità vocale", systemImage: "waveform") }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Sub-agent

private struct AgentSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        SettingsGroup(title: String(localized: "Questo Mac")) {
            LabeledContent("Chip", value: DeviceProfile.chip)
            LabeledContent("Memoria", value: String(localized: "\(DeviceProfile.memoryGB) GB"))
            LabeledContent("Core", value: "\(DeviceProfile.cores)")
        }
        SettingsGroup(title: String(localized: "Sub-agent in parallelo"),
                      footnote: String(localized: "Per i compiti complessi Siri AI+ prepara un piano e lo fa eseguire da sub-agent, ognuno con la sua finestra di contesto: più ne lavorano insieme, più il piano è veloce, ma serve più memoria. Automatico: \(DeviceProfile.recommendedSubAgents) su questo Mac.")) {
            Picker("Quanti", selection: Binding(get: { state.subAgentSetting }, set: { state.subAgentSetting = $0 })) {
                Text("Automatico (\(DeviceProfile.recommendedSubAgents))").tag(0)
                ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
            }
            .frame(maxWidth: 260)
        }
        SettingsGroup(title: String(localized: "Sub-agent a ogni richiesta"),
                      footnote: String(localized: "Lavorano con Apple Intelligence sul Mac, in sessioni loro: gratis, privati, qualunque modello risponda nella chat.")) {
            Label("Smistatore: legge la richiesta e sceglie solo gli strumenti che servono (calendario, email, file, web, connettori…), così al modello che risponde non arrivano le descrizioni di tutti gli altri e la sua finestra di contesto resta per la conversazione e i dati. Dice anche se il compito va diviso in passi.",
                  systemImage: "arrow.triangle.branch")
            Label("Piano con i sub-agent: parte da solo per i compiti complessi con ogni modello; con Apple Intelligence parte sempre (un passo per le richieste semplici, più passi in parallelo per quelle complesse). I passaggi sono in «Come ho lavorato».",
                  systemImage: "list.bullet.clipboard")
            Label("Compattazione: quando la conversazione esce dalla finestra del modello, un sub-agent la riassume (se è lunga altri sub-agent la leggono a pezzi in parallelo) e al modello arrivano il riassunto e gli ultimi scambi.",
                  systemImage: "rectangle.compress.vertical")
        }
        .font(DS.Fonts.caption)
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        SettingsGroup(title: String(localized: "Dove vanno i dati")) {
            Label("Il pianificatore Apple, Gemma e ds4 lavorano sul Mac.", systemImage: "lock.shield")
            Label("La ricerca sul web invia solo la domanda cercata.", systemImage: "globe")
            Label("I connettori inviano ai loro servizi solo le chiamate che confermi.", systemImage: "puzzlepiece.extension")
            if state.cloudPrivacy {
                Label("ChatGPT e Claude ricevono i testi con i dati personali anonimizzati sul Mac da rizzo-pii: nomi, recapiti, codici e conti veri restano qui.", systemImage: "lock.shield.fill")
            }
            if state.selection.provider == .apple && state.appleResponseModel == .privateCloud {
                Label("Private Cloud Compute è attivo: Apple riceve i dati necessari per generare la risposta.", systemImage: "cloud")
            } else if state.selection.provider.isLocal {
                Label("Le risposte vengono generate sul Mac.", systemImage: "checkmark.seal")
            } else {
                Label("\(state.selection.provider.label) è attivo: le risposte passano da \(state.selection.provider.company).", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            }
        }
        .font(DS.Fonts.body)
        SettingsGroup(title: String(localized: "Registro")) {
            Button("Apri Attività recenti") { state.section = .activity; NSApp.activate() }
        }
    }
}

/// Una versione di Gemma 4: dimensione, memoria consigliata, scarica / usa / elimina.
private struct GemmaRow: View {
    @Environment(AppState.self) private var state
    let variant: GemmaVariant
    @State private var confirmDelete = false
    var body: some View {
        let models = state.models
        let _ = models.revision
        let tooBig = variant.minMemoryGB > DeviceProfile.memoryGB
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(variant.label).font(DS.Fonts.bodyStrong)
                    if variant == DeviceProfile.recommendedGemma {
                        Text("consigliata").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Color.accentColor, in: Capsule())
                    }
                    if state.selection.provider == .gemma, state.resolved(state.selection).model == variant.id, variant.isDownloaded {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("In uso")
                    }
                }
                Text(String(format: "%.1f GB · consigliati %d GB di memoria", variant.sizeGB, max(8, variant.minMemoryGB)) + (tooBig ? String(localized: " · troppo grande per questo Mac") : ""))
                    .font(DS.Fonts.caption).foregroundStyle(tooBig ? .orange : .secondary)
                if let error = models.errors[variant.id] { Text(error).font(DS.Fonts.caption).foregroundStyle(.red) }
            }
            Spacer()
            if let progress = models.downloads[variant.id] {
                ProgressView(value: progress).frame(width: 110)
                Text("\(Int(progress * 100))%").font(.system(size: 11, design: .monospaced)).frame(width: 36)
                Button("Annulla") { models.cancelDownload(variant) }.controlSize(.small)
            } else if variant.isDownloaded {
                Button("Usa") { state.choose(ModelSelection(.gemma, model: variant.id)) }
                    .controlSize(.small)
                    .disabled(state.selection.provider == .gemma && state.resolved(state.selection).model == variant.id)
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).iconHelp(String(localized: "Elimina il file dal Mac"))
                    .confirmationDialog("Eliminare \(variant.label) dal Mac?", isPresented: $confirmDelete) {
                        Button("Elimina (\(String(format: "%.1f", variant.sizeGB)) GB)", role: .destructive) { models.delete(variant) }
                    } message: { Text("Il file verrà cancellato: per usarla di nuovo andrà riscaricata.") }
            } else {
                Button("Scarica") { models.download(variant) }.controlSize(.small)
                Link(destination: variant.pageURL) { Image(systemName: "arrow.up.right.square") }.help("Pagina su Hugging Face")
            }
        }
    }
}


// MARK: - Skill

/// Procedure riusabili (SKILL.md): elenco, modifica, nuove, cestino.
private struct SkillsSettings: View {
    @Environment(AppState.self) private var state
    @State private var selection = String?.none
    @State private var text = ""
    @State private var confirmDelete = false
    private var skills: [Skill] { _ = state.skillsRevision; return SkillStore.all(project: state.currentProject?.folder) }
    private var selected: Skill? { skills.first { $0.id == selection } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(skills) { skill in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name).font(DS.Fonts.bodyStrong)
                            Text(skill.inProject ? String(localized: "Progetto · \(skill.description)") : skill.description)
                                .font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .tag(skill.id as String?)
                    }
                }
                .overlay {
                    if skills.isEmpty {
                        ContentUnavailableView("Nessuna skill", systemImage: "wand.and.stars",
                                               description: Text("Salva un piano riuscito con «Salva come skill», oppure creane una nuova."))
                    }
                }
                Divider()
                HStack {
                    Button { newSkill() } label: { Image(systemName: "plus") }.iconHelp(String(localized: "Nuova skill"))
                    Button { confirmDelete = true } label: { Image(systemName: "minus") }
                        .iconHelp(String(localized: "Sposta la skill nel Cestino")).disabled(selected == nil)
                    Spacer()
                    Button { NSWorkspace.shared.open(SkillStore.folder) } label: { Image(systemName: "folder") }.iconHelp(String(localized: "Mostra nel Finder"))
                }
                .buttonStyle(.borderless)
                .padding(DS.Space.sm)
            }
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                if let skill = selected {
                    Text(skill.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(DS.Fonts.micro).foregroundStyle(.secondary).lineLimit(1)
                    TextEditor(text: $text)
                        .font(DS.Fonts.mono)
                        .scrollContentBackground(.hidden)
                        .padding(DS.Space.sm)
                        .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                    HStack {
                        Text("Si attiva quando la richiesta contiene il nome o una delle parole in «cues».").font(DS.Fonts.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Salva") { save(skill) }.keyboardShortcut("s").buttonStyle(.borderedProminent).disabled(text == skill.text)
                    }
                } else {
                    ContentUnavailableView("Scegli una skill", systemImage: "wand.and.stars",
                                           description: Text("Le skill sono procedure in Markdown che l'assistente segue quando la richiesta le riguarda."))
                }
            }
            .padding(DS.Space.lg)
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selection, initial: true) { text = selected?.text ?? "" }
        .confirmationDialog("Spostare «\(selected?.name ?? "")» nel Cestino?", isPresented: $confirmDelete) {
            Button("Sposta nel Cestino", role: .destructive) {
                if let skill = selected { try? SkillStore.delete(skill); selection = nil; state.skillsRevision += 1 }
            }
        }
    }

    private func newSkill() {
        if let skill = try? SkillStore.save(name: String(localized: "Nuova skill"), description: String(localized: "Cosa fa questa procedura"), cues: [String(localized: "parola chiave")],
                                            body: "## Procedura\n1. Primo passo\n2. Secondo passo") {
            state.skillsRevision += 1
            selection = skill.id
        }
    }

    private func save(_ skill: Skill) {
        do {
            try text.write(to: skill.url, atomically: true, encoding: .utf8)
            state.skillsRevision += 1
            state.showToast(String(localized: "Skill salvata"), symbol: "wand.and.stars")
        } catch {
            state.showToast(String(localized: "Non salvata: \(error.localizedDescription)"), symbol: "exclamationmark.triangle.fill")
        }
    }
}
