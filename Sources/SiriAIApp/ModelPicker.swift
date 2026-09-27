import SiriCore
import SwiftUI

/// Scelta del modello, come nelle app di ChatGPT e Claude: un pannello con i modelli divisi tra quelli sul Mac (privati)
/// e quelli in cloud; per il modello scelto versione e ragionamento si cambiano lì, senza sottomenu.
/// Lo usano il campo di scrittura della chat, le chat affiancate e la Programmazione.
struct ModelPicker: View {
    @Environment(AppState.self) private var state
    let current: ModelSelection
    var compact = false
    /// Nella chat: l'interruttore degli strumenti per i modelli diversi da Apple Intelligence.
    var showsTools = false
    let choose: (ModelSelection) -> Void
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let chosen = state.resolved(current)
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                ModelGlyph(provider: chosen.provider, size: 17)
                Text(state.shortLabel(for: chosen))
                    .font(DS.Fonts.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: compact ? 130 : 200, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                if let effort = state.effortBadge(for: chosen) {
                    Text(effort)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .fixedSize()
                }
                if showsTools, chosen.provider != .apple, state.externalTools {
                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.leading, 4)
            .padding(.trailing, 7)
            .frame(height: 26)
            .background(Color.primary.opacity(open ? 0.09 : hovering ? 0.05 : 0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .top) {
            ModelPickerPanel(current: chosen, showsTools: showsTools) { choice, keepOpen in
                if !keepOpen { open = false }
                choose(choice)
            } close: { open = false }
            .environment(state)
        }
        .help(Language.t("Modello: \(state.label(for: chosen))", "Model: \(state.label(for: chosen))"))
        .accessibilityLabel(Language.t("Modello: \(state.label(for: chosen))", "Model: \(state.label(for: chosen))"))
    }
}

/// Icona del modello, sempre con gli stessi colori (Apple grigio, Gemma blu, ChatGPT verde, Claude arancione).
struct ModelGlyph: View {
    let provider: ResponseProvider
    var size: CGFloat = 26

    static func colors(_ provider: ResponseProvider) -> [Color] {
        switch provider {
        case .apple: [Color(hex: 0x8E8E93), Color(hex: 0x48484A)]
        case .gemma: Hue.blue
        case .ds4: Hue.teal
        case .chatgpt: [Color(hex: 0x2BC78A), Color(hex: 0x0E8F5B)]
        case .claude: [Color(hex: 0xEB9A70), Color(hex: 0xC8643B)]
        }
    }

    var body: some View {
        Image(systemName: AppState.symbol(for: provider))
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: Self.colors(provider), startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Il pannello dei modelli.
struct ModelPickerPanel: View {
    @Environment(AppState.self) private var state
    let current: ModelSelection
    let showsTools: Bool
    /// La scelta e se il pannello resta aperto (versione e ragionamento dello stesso modello sì, un modello nuovo no:
    /// per ChatGPT e Claude può comparire la richiesta di conferma sulla privacy).
    let choose: (ModelSelection, Bool) -> Void
    let close: () -> Void

    private var local: [ResponseProvider] { [.apple, .gemma] + (state.models.ds4Installed ? [.ds4] : []) }
    private let cloud: [ResponseProvider] = [.chatgpt, .claude]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    group(Language.t("Sul Mac · privati", "On your Mac · private"), providers: local)
                    group(Language.t("Cloud · con il tuo abbonamento", "Cloud · with your subscription"), providers: cloud)
                }
                .padding(14)
            }
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if showsTools {
                    Toggle(isOn: Binding(get: { state.externalTools }, set: { state.externalTools = $0 })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Language.t("Strumenti dell'app anche per gli altri modelli", "App tools for other models too")).font(DS.Fonts.callout)
                            Text(Language.t("Calendario, email, file, web e connettori: ciò che crea o invia resta da confermare.", "Calendar, email, files, web, and connectors: you still approve anything they create or send."))
                                .font(DS.Fonts.micro).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                Button {
                    close()
                    state.openSettings("modelli")
                } label: { Label(Language.t("Gestisci modelli…", "Manage models…"), systemImage: "slider.horizontal.3") }
                .buttonStyle(.link)
                .font(DS.Fonts.callout)
            }
            .padding(14)
        }
        .frame(width: 360)
    }

    private func group(_ title: String, providers: [ResponseProvider]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            ForEach(providers) { provider in row(provider) }
        }
    }

    @ViewBuilder
    private func row(_ provider: ResponseProvider) -> some View {
        let selected = current.provider == provider
        let problem = state.pickerProblem(for: provider)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if problem != nil {
                    close()
                    state.openSettings("modelli")
                } else if !selected {
                    choose(ModelSelection(provider), false)
                }
            } label: {
                HStack(spacing: 10) {
                    ModelGlyph(provider: provider, size: 28)
                        .opacity(problem == nil ? 1 : 0.45)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.name).font(DS.Fonts.bodyStrong)
                        Text(problem ?? state.pickerSubtitle(for: provider, selection: selected ? current : nil))
                            .font(DS.Fonts.micro)
                            .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).font(.system(size: 15))
                    } else if problem != nil {
                        Text(Language.t("Configura", "Set up")).font(DS.Fonts.micro).foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if selected, problem == nil { details(provider) }
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.name)\(selected ? Language.t(", scelto", ", selected") : "")")
    }

    /// Versioni e ragionamento del modello scelto.
    @ViewBuilder
    private func details(_ provider: ResponseProvider) -> some View {
        let options = state.modelOptions(for: provider)
        let version = options.first { $0.id == current.model }
        if options.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text(provider == .gemma ? Language.t("Versione scaricata", "Downloaded version") : Language.t("Versione", "Version")).font(DS.Fonts.micro).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(options) { option in
                        let on = option.id == current.model
                        Button { choose(ModelSelection(provider, model: option.id, effort: current.effort), true) } label: {
                            Text(option.label)
                                .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.07)), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .padding(.leading, 38)
        }
        if let version, !version.efforts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(provider == .gemma ? Language.t("Ragionamento prima di rispondere", "Thinking before answering") : Language.t("Quanto ragiona", "Reasoning effort")).font(DS.Fonts.micro).foregroundStyle(.secondary)
                Picker(Language.t("Ragionamento", "Reasoning"), selection: Binding(
                    get: { current.effort ?? version.defaultEffort ?? version.efforts[0] },
                    set: { choose(ModelSelection(provider, model: version.id, effort: $0), true) })) {
                    ForEach(version.efforts, id: \.self) { effort in
                        Text(ModelCatalog.effortLabel(effort)).tag(effort)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                Text(effortHint(provider)).font(DS.Fonts.micro).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 38)
        }
    }

    private func effortHint(_ provider: ResponseProvider) -> String {
        provider == .gemma
            ? Language.t("Acceso: risposte più accurate su problemi e codice, ma più lente.", "On: more accurate answers for problems and code, but slower.")
            : Language.t("Più ragionamento: risposte migliori su problemi difficili, ma più lente e con più consumo dell'abbonamento.", "More reasoning helps with difficult problems, but takes longer and uses more of your subscription.")
    }
}

extension AppState {
    /// Nome breve per il pulsante: «GPT-6-Sol», «Claude Opus», «Gemma 4 E4B», «Apple Intelligence».
    func shortLabel(for selection: ModelSelection) -> String {
        let choice = resolved(selection)
        let option = modelOptions(for: choice.provider).first { $0.id == choice.model }
        switch choice.provider {
        case .apple, .ds4: return choice.provider.name
        case .gemma: return GemmaVariant.variant(choice.model ?? "")?.label ?? choice.provider.name
        case .chatgpt: return option?.label ?? choice.model ?? choice.provider.name
        case .claude: return String(localized: "Claude ") + (option?.label ?? choice.model?.capitalized ?? "")
        }
    }

    /// Il ragionamento accanto al nome, solo quando c'è una scelta («Alto», «Ragiona» per Gemma).
    func effortBadge(for selection: ModelSelection) -> String? {
        let choice = resolved(selection)
        if choice.provider == .gemma { return choice.effort == "on" ? Language.t("Ragiona", "Thinking") : nil }
        return choice.effort.map(ModelCatalog.effortLabel)
    }

    /// Cosa sapere di un modello nel pannello: dove gira, quanto contesto, privacy.
    func pickerSubtitle(for provider: ResponseProvider, selection: ModelSelection?) -> String {
        let context = ContextBudget.of(provider).label
        switch provider {
        case .apple: return Language.t("\(AppleResponseModel.onDeviceSummary) · gratis, niente esce dal Mac", "\(AppleResponseModel.onDeviceSummary) · free, stays on your Mac")
        case .gemma:
            let name = selection.flatMap { GemmaVariant.variant(resolved($0).model ?? "")?.label } ?? GemmaVariant.variant(gemmaModel)?.label ?? String(localized: "Gemma 4")
            return Language.t("\(name) · \(context) · sul Mac", "\(name) · \(context) · on your Mac")
        case .ds4: return Language.t("\(context) · sul Mac", "\(context) · on your Mac")
        case .chatgpt, .claude:
            let privacy = cloudPrivacy ? Language.t("dati personali anonimizzati sul Mac", "personal data anonymized on your Mac")
                                       : Language.t("dati in chiaro verso \(provider.company)", "clear data sent to \(provider.company)")
            return "\(provider == .chatgpt ? "Codex" : "Claude Code") · \(context) · \(privacy)"
        }
    }

    /// Perché un modello non si può ancora scegliere (nil se è pronto).
    func pickerProblem(for provider: ResponseProvider) -> String? {
        switch provider {
        case .apple: return availabilityProblem
        case .gemma: return models.downloadedVariants.isEmpty ? Language.t("Da scaricare in Impostazioni › Modelli", "Download in Settings › Models") : nil
        case .ds4: return models.ds4Installed ? nil : Language.t("Da installare in Impostazioni › Modelli", "Install in Settings › Models")
        case .chatgpt:
            if !models.codexInstalled { return Language.t("Serve Codex: installalo in Impostazioni › Modelli", "Codex is needed: install it in Settings › Models") }
            return models.codexLoggedIn ? nil : Language.t("Accedi con il tuo account ChatGPT in Impostazioni", "Sign in to your ChatGPT account in Settings")
        case .claude:
            if !models.claudeInstalled { return Language.t("Serve Claude Code: installalo in Impostazioni › Modelli", "Claude Code is needed: install it in Settings › Models") }
            return models.claudeLoggedIn ? nil : Language.t("Accedi con il tuo account Claude in Impostazioni", "Sign in to your Claude account in Settings")
        }
    }
}

/// Per i Genius come nella chat: ChatGPT e Claude si usano solo dopo l'avviso sulla privacy.
private struct CloudConsent: ViewModifier {
    @Binding var pending: ModelSelection?
    let apply: (ModelSelection) -> Void

    func body(content: Content) -> some View {
        content.alert("La privacy è a rischio", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { cloud in
            Button("Usa \(cloud.provider.name)", role: .destructive) { apply(cloud) }
            Button("Annulla", role: .cancel) {}
        } message: { cloud in
            Text("Con \(cloud.provider.name) le risposte non sono più generate sul Mac: la richiesta, la conversazione recente e i dati usati per rispondere (calendario, file, pagine, connettori) vengono inviati a \(cloud.provider.company). Continuare?")
        }
    }
}

extension View {
    func cloudConsent(_ pending: Binding<ModelSelection?>, apply: @escaping (ModelSelection) -> Void) -> some View {
        modifier(CloudConsent(pending: pending, apply: apply))
    }
}

extension ModelSelection {
    /// Serve l'avviso sulla privacy passando da `previous` a questo modello (un cloud diverso da quello già scelto).
    func needsCloudConsent(after previous: ModelSelection?) -> Bool {
        !provider.isLocal && previous?.provider != provider
    }
}
