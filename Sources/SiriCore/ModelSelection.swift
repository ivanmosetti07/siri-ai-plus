import Foundation

// MARK: - Modello scelto per una chat o per una sessione di coding
//
// Oltre a chi risponde (Apple Intelligence, Gemma, ChatGPT, Claude…) si sceglie la versione del modello («GPT-6-Sol»,
// «Opus») e quanto deve ragionare, solo dove il modello lo permette.

/// Chi risponde, con quale versione e con quanto ragionamento.
public struct ModelSelection: Codable, Sendable, Hashable {
    public var provider: ResponseProvider
    /// Versione: id della versione di Gemma («e4b»), modello di ChatGPT («gpt-6-sol»), alias di Claude («opus»).
    /// nil = quella predefinita.
    public var model: String?
    /// Livello di ragionamento («low»…«max»), solo per i modelli che lo prevedono. nil = quello predefinito del modello.
    public var effort: String?
    /// «Auto»: il modello si sceglie a ogni richiesta (vedi `AutoModel`); `provider` resta il ripiego.
    /// Un campo e non un nuovo `ResponseProvider`: le versioni precedenti dell'app leggono la scelta come Apple Intelligence
    /// invece di scartare Genius e sessioni di codice che la contengono.
    public var auto: Bool?

    public init(_ provider: ResponseProvider, model: String? = nil, effort: String? = nil, auto: Bool? = nil) {
        self.provider = provider
        self.model = model
        self.effort = effort
        self.auto = auto
    }

    /// La scelta «Auto» (con Apple Intelligence come ripiego).
    public static let automatic = ModelSelection(.apple, auto: true)
    public var isAuto: Bool { auto == true }
}

/// Una versione di un modello nel menu, con i livelli di ragionamento che accetta (vuoto: nessuna scelta).
public struct ModelOption: Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let efforts: [String]
    public let defaultEffort: String?

    public init(id: String, label: String, efforts: [String] = [], defaultEffort: String? = nil) {
        self.id = id; self.label = label; self.efforts = efforts; self.defaultEffort = defaultEffort
    }
}

public enum ModelCatalog {
    /// Nome di un livello di ragionamento, nella lingua in uso.
    public static func effortLabel(_ effort: String) -> String {
        if Language.isEnglish {
            return switch effort {
            case "none": "None"
            case "minimal": "Minimal"
            case "low": "Low"
            case "medium": "Medium"
            case "high": "High"
            case "xhigh": "Very high"
            case "max": "Maximum"
            case "ultra": "Ultra"
            case "off": "Off"
            case "on": "On"
            default: effort.capitalized
            }
        }
        return switch effort {
        case "none": "Nessuno"
        case "minimal": "Minimo"
        case "low": "Basso"
        case "medium": "Medio"
        case "high": "Alto"
        case "xhigh": "Molto alto"
        case "max": "Massimo"
        case "ultra": "Ultra"
        case "off": "Spento"
        case "on": "Acceso"
        default: effort.capitalized
        }
    }

    /// Gemma 4 ragiona solo se glielo si chiede (`enable_thinking` del suo modello di chat): acceso o spento.
    public static let gemmaEfforts = ["off", "on"]

    /// Il livello richiesto se il modello lo accetta, altrimenti il suo predefinito (nil se non ne ha).
    public static func effort(_ wanted: String?, for option: ModelOption?) -> String? {
        guard let option, !option.efforts.isEmpty else { return nil }
        if let wanted, option.efforts.contains(wanted) { return wanted }
        return option.defaultEffort ?? option.efforts.first
    }

    // MARK: ChatGPT (CLI Codex)

    static var codexHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    }

    /// Modelli dell'account ChatGPT: l'elenco che la CLI Codex scarica da OpenAI (~/.codex/models_cache.json),
    /// solo quelli visibili nel suo menu e nel suo ordine.
    public static func chatGPT() -> [ModelOption] {
        guard let data = try? Data(contentsOf: codexHome.appending(path: "models_cache.json")) else { return [] }
        return chatGPT(from: data)
    }

    static func chatGPT(from data: Data) -> [ModelOption] {
        guard let json = try? JSONValue.parse(data), let models = json["models"]?.array else { return [] }
        return models
            .filter { ($0["visibility"]?.string ?? "list") == "list" && $0["slug"]?.string != nil }
            .sorted { ($0["priority"]?.number ?? 99) < ($1["priority"]?.number ?? 99) }
            .compactMap { model in
                guard let slug = model["slug"]?.string else { return nil }
                let efforts = (model["supported_reasoning_levels"]?.array ?? []).compactMap { $0["effort"]?.string }
                return ModelOption(id: slug, label: model["display_name"]?.string ?? slug, efforts: efforts,
                                   defaultEffort: model["default_reasoning_level"]?.string)
            }
    }

    /// Modello e ragionamento della configurazione personale di Codex (~/.codex/config.toml): sono i predefiniti delle chat.
    public static func codexDefaults() -> (model: String?, effort: String?) {
        guard let text = try? String(contentsOf: codexHome.appending(path: "config.toml"), encoding: .utf8) else { return (nil, nil) }
        return codexDefaults(from: text)
    }

    /// Solo le chiavi in cima al file (prima della prima tabella `[…]`).
    static func codexDefaults(from text: String) -> (model: String?, effort: String?) {
        var model: String?
        var effort: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let value = parts[1].split(separator: "#").first.map { $0.trimmingCharacters(in: .whitespaces) }?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if parts[0] == "model" { model = value }
            if parts[0] == "model_reasoning_effort" { effort = value }
        }
        return (model, effort)
    }

    // MARK: Claude (CLI Claude Code)

    /// Alias della CLI: portano sempre all'ultima versione di ciascun modello.
    public static let claude: [ModelOption] = {
        let efforts = ["low", "medium", "high", "xhigh", "max"]
        return [
            ModelOption(id: "fable", label: "Fable", efforts: efforts, defaultEffort: "high"),
            ModelOption(id: "opus", label: "Opus", efforts: efforts, defaultEffort: "high"),
            ModelOption(id: "sonnet", label: "Sonnet", efforts: efforts, defaultEffort: "high"),
            ModelOption(id: "haiku", label: "Haiku"),
        ]
    }()

    /// Modello e ragionamento della configurazione personale di Claude Code (~/.claude/settings.json).
    public static func claudeDefaults() -> (model: String?, effort: String?) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
        guard let data = try? Data(contentsOf: url), let json = try? JSONValue.parse(data) else { return (nil, nil) }
        let model = json["model"]?.string.flatMap { name in claude.first { name.lowercased().contains($0.id) }?.id }
        return (model, json["effortLevel"]?.string)
    }
}

// MARK: - CLI di Claude

/// La CLI ufficiale di Claude (Claude Code): usa l'abbonamento Claude dell'utente, come Codex per ChatGPT.
public enum ClaudeCLI {
    /// L'installazione nativa sta in ~/.local/bin, che la shell di login dell'app non ha nel PATH (lo aggiunge solo ~/.zshrc).
    public static var path: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Il programma per la shell: il percorso trovato, altrimenti il nome (se è nel PATH della shell di login).
    public static var command: String { path.map(Shell.quote) ?? "claude" }

    /// Senza la configurazione personale (hook, plugin, permessi automatici, server MCP dell'utente) e senza le skill.
    static let isolation = "--setting-sources project,local --strict-mcp-config --disable-slash-commands"

    public struct Status: Sendable, Equatable {
        public var installed = false
        public var loggedIn = false
        public var email: String?
        /// Abbonamento («max», «pro»…).
        public var plan: String?

        public init() {}
    }

    public static func status() async -> Status {
        var status = Status()
        let result = await Shell.run("\(command) auth status --json", timeout: 20)
        guard !result.output.contains("command not found"), result.status != 127 else { return status }
        status.installed = path != nil || result.status == 0
        guard let start = result.output.firstIndex(of: "{"), let json = try? JSONValue.parse(Data(result.output[start...].utf8)) else { return status }
        status.installed = true
        status.loggedIn = json["loggedIn"] == .bool(true)
        status.email = json["email"]?.string
        status.plan = json["subscriptionType"]?.string
        return status
    }

    /// Messaggio per l'utente da un'uscita della CLI che non ha prodotto testo.
    static func problem(in output: String) -> EngineError {
        let lower = output.lowercased()
        if output.contains("command not found") { return .unavailable("Claude Code non è installato: installalo in Impostazioni › Modelli.") }
        if lower.contains("not logged in") || lower.contains("/login") || lower.contains("invalid api key") || lower.contains("oauth") || output.contains("401") {
            return .unavailable("Accedi con il tuo account Claude in Impostazioni › Modelli.")
        }
        if lower.contains("usage limit") || lower.contains("rate limit") || lower.contains("limit reached") {
            return .unavailable("Hai raggiunto il limite di utilizzo del tuo abbonamento Claude: riprova più tardi o scegli un altro modello.")
        }
        return .failed("Claude non ha risposto: \(output.suffix(300))")
    }
}
