import AppIntents

/// Azioni disponibili in Comandi Rapidi su macOS. Le azioni che creano o inviano qualcosa
/// restano schede da confermare nella finestra dell'app.
struct OpenSiriAIIntent: AppIntent {
    static let title: LocalizedStringResource = "Apri Siri AI+"
    static let description = IntentDescription("Mostra la chat rapida di Siri AI+ sul Mac.")
    static let supportedModes: IntentModes = .foreground

    @MainActor func perform() async throws -> some IntentResult {
        if let state = AppState.shared {
            await state.start()
            CompanionController.shared.install(state: state)
            CompanionController.shared.showQuick()
        }
        return .result()
    }
}

struct AskSiriAIIntent: AppIntent {
    static let title: LocalizedStringResource = "Chiedi a Siri AI+"
    static let description = IntentDescription("Invia una domanda alla chat rapida dello Spazio personale o di lavoro.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Richiesta") var prompt: String

    @MainActor func perform() async throws -> some IntentResult {
        if let state = AppState.shared {
            await state.start()
            CompanionController.shared.install(state: state)
            CompanionController.shared.showQuick()
            let space = state.space == .codice ? Space.lavoro : state.space
            state.send(prompt, in: state.quickConversation(for: space))
        }
        return .result()
    }
}
