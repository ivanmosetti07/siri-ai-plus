import Foundation
import FoundationModels

// MARK: - Il modello giusto per ogni sub-agent (ChatGPT e Claude)
//
// Apple Intelligence, sul Mac e senza consumare l'abbonamento, valuta in una sola chiamata la difficoltà di ogni passo
// del piano; ogni difficoltà ha la sua versione del modello scelto nella chat: le ricerche e le letture vanno al modello
// leggero (Haiku, GPT-6-Luna), il lavoro ordinario a quello di tutti i giorni (Sonnet, GPT-6-Sol), le analisi difficili
// al più capace (Opus o Fable, GPT-6-Astra). La risposta finale resta al modello della chat.

/// Quanto è impegnativo un passo del piano.
public enum StepDifficulty: String, Codable, Sendable, CaseIterable {
    case facile, media, difficile

    public var label: String {
        switch self {
        case .facile: Language.t("facile", "easy")
        case .media: Language.t("medio", "medium")
        case .difficile: Language.t("difficile", "hard")
        }
    }
}

public enum SubAgentRouting {
    /// Solo ChatGPT e Claude hanno più versioni da alternare nella stessa risposta.
    public static func routes(_ provider: ResponseProvider) -> Bool { provider == .chatgpt || provider == .claude }

    /// La versione per un passo di quella difficoltà, nella famiglia del modello della chat.
    public static func selection(for difficulty: StepDifficulty, chat: ModelSelection,
                                 gpt: [ModelOption] = ModelCatalog.chatGPT()) -> ModelSelection {
        switch chat.provider {
        case .claude: claude(difficulty, chat: chat)
        case .chatgpt: chatGPT(difficulty, chat: chat, models: gpt)
        default: chat
        }
    }

    static func claude(_ difficulty: StepDifficulty, chat: ModelSelection) -> ModelSelection {
        switch difficulty {
        case .facile:
            return ModelSelection(.claude, model: "haiku")
        case .media:
            return ModelSelection(.claude, model: "sonnet", effort: "medium")
        case .difficile:
            // Il più capace: quello della chat se è già Opus o Fable (con il suo ragionamento), altrimenti Opus.
            if let model = chat.model, ["opus", "fable"].contains(model) {
                return ModelSelection(.claude, model: model, effort: stronger(chat.effort, than: "high"))
            }
            return ModelSelection(.claude, model: "opus", effort: "high")
        }
    }

    /// Le versioni della stessa generazione del modello della chat («gpt-6-…»), nell'ordine di Codex:
    /// la prima è la più capace (Astra), l'ultima la più leggera (Luna), in mezzo quella di tutti i giorni (Sol).
    static func chatGPT(_ difficulty: StepDifficulty, chat: ModelSelection, models: [ModelOption]) -> ModelSelection {
        guard !models.isEmpty else { return chat }
        let current = chat.model ?? ModelCatalog.codexDefaults().model ?? models[0].id
        let generation = Self.generation(current)
        var family = models.filter { Self.generation($0.id) == generation }
        if family.isEmpty { family = models.filter { Self.generation($0.id) == Self.generation(models[0].id) } }
        guard let strongest = family.first, let lightest = family.last else { return chat }
        let everyday = family.count >= 3 ? family[family.count / 2] : strongest
        let (option, wanted): (ModelOption, String?) = switch difficulty {
        case .facile: (lightest, "low")
        case .media: (everyday, "medium")
        case .difficile: (strongest, stronger(chat.effort, than: "high"))
        }
        return ModelSelection(.chatgpt, model: option.id, effort: ModelCatalog.effort(wanted, for: option))
    }

    /// «gpt-6-sol» → «gpt-6»; «gpt-5.5» → «gpt-5.5».
    static func generation(_ slug: String) -> String {
        let parts = slug.split(separator: "-")
        guard parts.count >= 3 else { return slug }
        return parts.dropLast().joined(separator: "-")
    }

    /// Il ragionamento più alto fra quello scelto nella chat e un minimo.
    static func stronger(_ chosen: String?, than minimum: String) -> String {
        let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        guard let chosen, let a = order.firstIndex(of: chosen), let b = order.firstIndex(of: minimum) else { return minimum }
        return a >= b ? chosen : minimum
    }

    /// Nome breve da mostrare nel piano: «Haiku», «GPT-6-Luna · basso».
    public static func label(_ selection: ModelSelection, gpt: [ModelOption] = ModelCatalog.chatGPT()) -> String {
        let name: String = switch selection.provider {
        case .claude: ModelCatalog.claude.first { $0.id == selection.model }?.label ?? "Claude"
        case .chatgpt: gpt.first { $0.id == selection.model }?.label ?? selection.model ?? "ChatGPT"
        default: selection.provider.name
        }
        return selection.effort.map { "\(name) · \(ModelCatalog.effortLabel($0).lowercased())" } ?? name
    }

    /// Senza Apple Intelligence: dalle parole del passo. Chi raccoglie dati è facile, chi giudica o decide è difficile.
    public static func heuristic(_ step: TaskPlan.Step) -> StepDifficulty {
        let lower = (step.title + " " + step.instruction).lowercased()
        let english = Language.isEnglish
        let judging = (["strategia", "rischi", "decidi", "valuta", "ottimizza", "progetta", "architettura", "codice", "calcola", "stima",
                        "previsione", "priorità", "raccomanda", "negozia", "contratt", "legale", "fiscale", "diagnosi"]
                       + (english ? ["strategy", "risk", "decide", "evaluate", "assess", "optimi", "design", "architecture", "code", "calculate",
                                     "estimate", "forecast", "priorit", "recommend", "negotiate", "contract", "legal", "tax", "diagnos"] : []))
            .filter { lower.contains($0) }.count
        // Scrivere un testo (anche un messaggio) chiede più di una ricerca.
        let writing = (["scrivi", "redigi", "bozza", "componi", "prepara un", "prepara una", "crea un", "crea una"]
                       + (english ? ["write", "draft", "compose", "prepare a", "prepare an", "create a", "create an"] : [])).contains(where: lower.contains)
        if Assistant.stepNeedsTools(step.instruction) && judging == 0 && !writing { return .facile }
        if judging >= 2 || (judging == 1 && step.instruction.count > 160) { return .difficile }
        return .media
    }

    /// Correzioni al giudizio di Apple Intelligence: chi solo raccoglie (cerca, legge, elenca con gli strumenti) non ha bisogno
    /// del modello più capace; chi analizza, confronta o valuta non va al modello più leggero.
    static func capped(_ difficulty: StepDifficulty, for step: TaskPlan.Step) -> StepDifficulty {
        let lower = step.instruction.lowercased()
        let judging = (["analizza", "valuta", "confronta", "strategia", "rischi", "decidi", "calcola", "sintetizza", "elabora"]
                       + (Language.isEnglish ? ["analy", "evaluate", "assess", "compare", "strategy", "risk", "decide", "calculate", "synthesi", "work out"] : []))
            .contains(where: lower.contains)
        if difficulty == .facile, judging { return .media }
        guard difficulty == .difficile, Assistant.stepNeedsTools(step.instruction) else { return difficulty }
        return judging ? difficulty : .media
    }
}

extension Assistant {
    /// Apple Intelligence valuta la difficoltà di ogni passo in una chiamata sola (sul Mac: niente abbonamento, circa un secondo).
    /// Se non è disponibile o non risponde entro 8 secondi decidono le parole del passo.
    public func stepDifficulties(for plan: TaskPlan) async -> [StepDifficulty] {
        let fallback = plan.steps.map(SubAgentRouting.heuristic)
        guard Agent.availabilityProblem == nil, !plan.steps.isEmpty else { return fallback }
        let count = plan.steps.count
        let english = Language.isEnglish
        let schema = makeSchema("DifficoltaPassi", [
            .required("difficolta", .array(.choice(StepDifficulty.allCases.map(\.rawValue)), min: count, max: count),
                      english ? "The difficulty of each step, in the same order as the steps" : "La difficoltà di ogni passo, nello stesso ordine dei passi"),
        ])
        let role = english ? """
        You judge how demanding each step of a task is, to choose the model that carries it out. \
        facile: searching the web, reading a file or a page, listing or summarizing data without having to judge it. \
        media: putting together or comparing information, writing an ordinary text, following instructions with a few steps. \
        difficile: analysis with judgment (risks, strategy, choices), long reasoning or reasoning with numbers, code, important texts to polish.
        """ : """
        Valuti quanto è impegnativo ogni passo di un compito, per scegliere il modello che lo svolge. \
        facile: cercare sul web, leggere un file o una pagina, elencare o riassumere dati senza doverli giudicare. \
        media: mettere insieme o confrontare informazioni, scrivere un testo ordinario, seguire istruzioni con qualche passaggio. \
        difficile: analisi con giudizio (rischi, strategia, scelte), ragionamenti lunghi o con numeri, codice, testi importanti da curare.
        """
        let steps = plan.steps.enumerated().map { "\($0.offset + 1). \($0.element.title): \($0.element.instruction.prefix(280))" }.joined(separator: "\n")
        let request = (english ? "Task: " : "Compito: ") + plan.goal.prefix(400) + (english ? "\nSteps:\n" : "\nPassi:\n") + steps
        let judge = Task { @MainActor () -> [StepDifficulty]? in
            guard let content = try? await self.writer(role).respond(to: request, schema: schema).content else { return nil }
            return content.strings("difficolta").compactMap(StepDifficulty.init(rawValue:))
        }
        // In secondo piano macOS rallenta il modello: dopo 8 secondi si lascia perdere.
        let timer = Task {
            try? await Task.sleep(for: .seconds(8))
            judge.cancel()
        }
        let values = await judge.value
        timer.cancel()
        guard let values, values.count == count else {
            Agent.log("DIFFICOLTÀ DEI PASSI: decido dalle parole (Apple Intelligence non ha risposto)")
            return fallback
        }
        return zip(values, plan.steps).map { SubAgentRouting.capped($0, for: $1) }
    }
}
