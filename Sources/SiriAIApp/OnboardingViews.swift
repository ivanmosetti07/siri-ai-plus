import SiriCore
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            switch state.phase {
            case .onboarding: OnboardingView().transition(.opacity)
            case .permissions: PermissionsView().transition(.opacity)
            case .app: ShellView().transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: state.phase)
    }
}

/// Sfondo delle schermate iniziali: l'aurora di Siri AI+.
struct AmbientBackground: View {
    var body: some View {
        // La stessa aurora dell'app, fin dal primo avvio.
        AtmosphereBackdrop(space: .lavoro)
            .ignoresSafeArea()
    }
}

// MARK: - 01 Benvenuto

struct OnboardingView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            AmbientBackground()
            VStack(spacing: 30) {
                OrbView(state: .idle, size: 104)
                VStack(spacing: 8) {
                    Text("Siri AI+").font(DS.Fonts.display)
                    Text("Il tuo Mac, in una conversazione.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 16) {
                    Feature(symbol: "lock.shield", title: String(localized: "Apple Intelligence con privacy"),
                            text: String(localized: "Il Mac sceglie le azioni; le risposte usano Private Cloud Compute quando è autorizzato e disponibile, altrimenti il modello locale."))
                    Feature(symbol: "hand.raised", title: String(localized: "Nessuna azione senza il tuo consenso"),
                            text: String(localized: "Prima di creare, inviare o eliminare qualcosa ti mostro cosa farò."))
                    Feature(symbol: "square.stack.3d.up", title: String(localized: "Un solo posto per il tuo lavoro"),
                            text: String(localized: "Calendario, promemoria, email e documenti in un'unica conversazione."))
                }
                .frame(maxWidth: 380)
                Button {
                    state.finishOnboarding()
                } label: {
                    Text("Continua").frame(minWidth: 180)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(40)
        }
    }

    struct Feature: View {
        let symbol: String
        let title: String
        let text: String

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.Fonts.bodyStrong)
                    Text(text).font(DS.Fonts.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - 02 Permessi

struct PermissionsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            AmbientBackground()
            VStack(spacing: DS.Space.xl) {
                VStack(spacing: 6) {
                    Text("Collega le tue fonti").font(DS.Fonts.title)
                    Text("Scegli cosa può usare Siri AI+. Puoi cambiarlo quando vuoi da Attività e privacy.")
                        .font(DS.Fonts.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                SourcesList()
                    .frame(maxWidth: 560)
                HStack {
                    Button("Indietro") { state.restartOnboarding() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        state.finishPermissions()
                    } label: {
                        Text("Inizia").frame(minWidth: 120)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: 560)
                .controlSize(.large)
            }
            .padding(40)
        }
    }
}

/// Elenco delle fonti con permessi granulari: usato in Permessi, nel foglio Fonti e in Privacy.
struct SourcesList: View {
    @Environment(AppState.self) private var state
    var highlight: SourceKind?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(SourceKind.allCases.enumerated()), id: \.element) { index, source in
                if index > 0 { Divider().padding(.leading, 56) }
                SourceRow(source: source)
                    .background(highlight == source ? Color.accentColor.opacity(0.07) : .clear)
            }
        }
        .glassCard(radius: 24)
    }
}

struct SourceRow: View {
    @Environment(AppState.self) private var state
    let source: SourceKind

    private var enabled: Binding<Bool> {
        Binding(get: { state.prefs[source]?.enabled == true }, set: { state.setEnabled(source, $0) })
    }

    private var allowWrite: Binding<Bool> {
        Binding(get: { state.prefs[source]?.allowWrite != false }, set: { state.setAllowWrite(source, $0) })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Tile(source, size: 28, dimmed: source.support == .comingSoon)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(source.label).font(DS.Fonts.bodyStrong)
                    if source.support == .comingSoon {
                        Text("In arrivo")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(caption).font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if state.systemDenied(source) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Accesso negato nelle impostazioni di sistema.").font(DS.Fonts.caption)
                        Button("Apri Impostazioni") { state.openPrivacySettings(for: source) }
                            .buttonStyle(.link).font(DS.Fonts.caption)
                    }
                    .padding(.top, 2)
                } else if enabled.wrappedValue && source.support == .full {
                    Picker("Livello di accesso", selection: allowWrite) {
                        Text("Solo lettura").tag(false)
                        Text("Lettura e modifica").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 240)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            Toggle("Collega \(source.label)", isOn: enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(source.support == .comingSoon)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var caption: String {
        switch source.support {
        case .full: String(localized: "\(source.readCapability). \(source.writeCapability) dopo la tua conferma.")
        case .composeOnly: String(localized: "Prepara bozze che invii tu da Mail.")
        case .comingSoon: String(localized: "\(source.readCapability): collegamento in preparazione.")
        }
    }
}

/// Foglio "Fonti collegate", aperto dalla barra laterale o dalle schede.
struct SourcesSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fonti collegate").font(DS.Fonts.section)
                    Text("Scegli cosa può usare Siri AI+ e con quale livello di accesso.").font(DS.Fonts.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "button.done", defaultValue: "Fine")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView { SourcesList(highlight: state.sourcesSheet) }
        }
        .padding(DS.Space.xl)
        .frame(width: 560, height: 560)
    }
}
