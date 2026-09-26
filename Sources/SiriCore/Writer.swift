import Foundation
import FoundationModels

/// Chi scrive i testi dentro le azioni (risposte email, paragrafi riscritti, note, messaggi, documenti, slide, file)
/// quando l'utente ha scelto un altro modello. Riceve istruzioni e richiesta; `partial` riceve il testo mentre cresce.
public typealias TextWriter = @MainActor (_ instructions: String, _ request: String, _ partial: @escaping @MainActor (String) -> Void) async throws -> String

extension ExternalEngine {
    /// Scrittore con il modello scelto (Gemma e ds4 in locale, ChatGPT e Claude con le loro CLI). Per Apple Intelligence: nil.
    public static func writer(for selection: ModelSelection) -> TextWriter? {
        guard selection.provider != .apple else { return nil }
        return { instructions, request, partial in
            let stream: AsyncThrowingStream<String, Error> = switch selection.provider {
            case .gemma: streamOpenAICompatible(base: gemmaURL, model: "gemma", system: instructions, history: [], prompt: request,
                                                thinking: selection.effort == "on")
            case .ds4: streamOpenAICompatible(base: ds4URL, model: "ds4", system: instructions, history: [], prompt: request)
            case .chatgpt: streamChatGPT(system: instructions, history: [], prompt: request, model: selection.model, effort: selection.effort)
            case .claude: streamClaude(system: instructions, history: [], prompt: request, model: selection.model, effort: selection.effort)
            case .apple: AsyncThrowingStream { $0.finish() }
            }
            var final = ""
            for try await text in stream {
                final = text
                partial(text)
            }
            return final
        }
    }

    public static func writer(for provider: ResponseProvider) -> TextWriter? { writer(for: ModelSelection(provider)) }
}

extension Assistant {
    /// Istruzioni comuni per chi scrive (le stesse del `writer` di Apple Intelligence).
    static func writingInstructions(_ role: String) -> String {
        Language.isEnglish ? """
        \(role) Write in English, unless the request or the text asks for another language, with concrete and plausible content, without placeholders in brackets.
        It is now \(Dates.format(.now)). Next days:
        \(Dates.upcomingDays(14))
        """ : """
        \(role) Scrivi in italiano, salvo che la richiesta o il testo chiedano un'altra lingua, con contenuti concreti e plausibili, senza segnaposto tra parentesi.
        Adesso è \(Dates.format(.now)). Prossimi giorni:
        \(Dates.upcomingDays(14))
        """
    }

    /// Testo libero scritto dal modello scelto; se non c'è o non risponde, lo scrive Apple Intelligence (`apple`).
    func compose(_ role: String, _ request: String, partial: @escaping @MainActor (String) -> Void = { _ in },
                 apple: () async throws -> String) async throws -> String {
        if let text = await externalText(role, request, partial: partial) { return Self.cleanWritten(text) }
        return try await apple()
    }

    /// Risposta strutturata dal modello scelto: un oggetto JSON con i campi descritti (gli stessi dello schema di Apple).
    /// nil se non c'è un modello scelto o se la risposta non è un JSON valido: allora scrive Apple Intelligence.
    func composeJSON(_ role: String, _ request: String, fields: String,
                     partial: @escaping @MainActor (String) -> Void = { _ in }) async -> [String: Any]? {
        let format = Language.t("\n\nRispondi SOLO con un oggetto JSON valido, senza testo prima o dopo e senza ```. Campi:\n",
                                "\n\nAnswer ONLY with a valid JSON object, with no text before or after and no ```. Fields:\n") + fields
        guard let text = await externalText(role + format, request, partial: partial) else { return nil }
        guard let object = Self.jsonObject(in: text) else {
            Agent.log("SCRITTURA: risposta di \(textWriterName ?? "modello esterno") non in JSON, scrive Apple Intelligence")
            return nil
        }
        return object
    }

    func externalText(_ role: String, _ request: String, partial: @escaping @MainActor (String) -> Void) async -> String? {
        guard let textWriter else { return nil }
        let started = Date.now
        let name = textWriterName ?? "il modello scelto"
        do {
            let text = try await textWriter(Self.writingInstructions(role), request, partial).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw CancellationError() }
            trace?.steps.append(TraceStep(action: "scrittura", detail: name, result: "\(text.count) caratteri",
                                          milliseconds: Int(Date.now.timeIntervalSince(started) * 1000), ok: true))
            return text
        } catch {
            if Task.isCancelled { return nil }
            Agent.log("SCRITTURA con \(name) non riuscita: \(error.localizedDescription). Scrive Apple Intelligence.")
            trace?.steps.append(TraceStep(action: "scrittura", detail: name, result: "non riuscita, scrive Apple Intelligence",
                                          milliseconds: Int(Date.now.timeIntervalSince(started) * 1000), ok: false))
            return nil
        }
    }

    /// Via i recinti di codice e le virgolette intorno a tutto il testo.
    static func cleanWritten(_ text: String) -> String {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```") {
            clean = clean.replacingOccurrences(of: #"^```[a-zA-Z]*\s*\n?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n?```\s*$"#, with: "", options: .regularExpression)
        }
        return unquoted(clean.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Il primo oggetto JSON nel testo (anche dentro ```json … ```).
    static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let data = Data(text[start...end].utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Letture comode dai dizionari JSON.
extension Dictionary where Key == String, Value == Any {
    func text(_ key: String) -> String? {
        if let value = self[key] as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value }
        if let value = self[key] as? NSNumber { return value.stringValue }
        return nil
    }

    func texts(_ key: String) -> [String] {
        if let values = self[key] as? [Any] { return values.compactMap { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }.filter { !$0.isEmpty } }
        return text(key).map { [$0] } ?? []
    }

    func objects(_ key: String) -> [[String: Any]] { (self[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }

    func numbers(_ key: String) -> [Double] {
        (self[key] as? [Any])?.compactMap { value -> Double? in
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String { return Calculations.number(string) }
            return nil
        } ?? []
    }
}
