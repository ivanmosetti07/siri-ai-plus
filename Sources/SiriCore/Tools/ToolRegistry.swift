import Foundation

/// Uno strumento come lo vedono i modelli con tool calling (Gemma, ds4, ChatGPT, Claude): nome, descrizione e schema JSON.
public struct ToolSpec: Sendable, Equatable {
    public enum Kind: String, Sendable { case read, draft }
    public let name: String
    public let description: String
    public let parameters: JSONValue
    /// `draft`: prepara una scheda che l'utente conferma; `read`: legge e restituisce dati.
    public let kind: Kind

    public init(name: String, description: String, parameters: JSONValue, kind: Kind) {
        self.name = name; self.description = description; self.parameters = parameters; self.kind = kind
    }

    /// Formato OpenAI (`tools` di /v1/chat/completions).
    public var openAI: JSONValue {
        .object(["type": .string("function"), "function": .object([
            "name": .string(name), "description": .string(description), "parameters": parameters,
        ])])
    }

    /// Formato MCP (`tools/list`).
    public var mcp: JSONValue {
        .object(["name": .string(name), "description": .string(description), "inputSchema": parameters])
    }
}

/// Esito di uno strumento chiamato da un modello esterno: testo per il modello e, se serve, una scheda per l'utente.
public struct ToolCallResult: Sendable {
    public var text: String
    public var outcome: Outcome?
    public var ok: Bool

    public init(text: String, outcome: Outcome? = nil, ok: Bool = true) { self.text = text; self.outcome = outcome; self.ok = ok }
}

/// Registro unico degli strumenti per i modelli esterni. Le azioni sono le stesse del pianificatore di Apple Intelligence,
/// ma i modelli grandi scrivono direttamente i contenuti (testo dell'email, del file, della nota).
public enum ToolRegistry {
    static func object(_ properties: [String: (String, String)], required: [String] = []) -> JSONValue {
        var props: [String: JSONValue] = [:]
        for (key, value) in properties {
            if value.0 == "array" {
                props[key] = .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(value.1)])
            } else {
                props[key] = .object(["type": .string(value.0), "description": .string(value.1)])
            }
        }
        return .object(["type": .string("object"), "properties": .object(props), "required": .array(required.map(JSONValue.string))])
    }

    static var date: String { Language.t("Data come yyyy-MM-dd o yyyy-MM-dd HH:mm", "Date as yyyy-MM-dd or yyyy-MM-dd HH:mm") }

    /// Strumenti disponibili nel contesto: app collegate, progetto aperto, web, connettori. Descrizioni nella lingua della
    /// richiesta: i modelli scelgono meglio lo strumento quando lo leggono nella lingua in cui ragionano.
    @MainActor
    public static func tools(for work: WorkContext, enabled: Set<SourceKind>) -> [ToolSpec] {
        let t = Language.t
        var tools: [ToolSpec] = []
        func add(_ name: String, _ description: String, _ parameters: JSONValue, _ kind: ToolSpec.Kind) {
            tools.append(ToolSpec(name: name, description: description, parameters: parameters, kind: kind))
        }
        if enabled.contains(.calendar) || enabled.contains(.reminders) {
            add("agenda", t("Legge eventi del calendario e promemoria in un intervallo di date (dello spazio in uso). Con «cerca» trova un evento per nome («dentista»): senza date guarda dal mese scorso ai prossimi sei mesi.",
                            "Reads calendar events and reminders in a date range (of the current space). With «cerca» it finds an event by name («dentist»): without dates it looks from last month to the next six months."),
                object(["dal": ("string", date), "al": ("string", date),
                        "cerca": ("string", t("Parole del titolo dell'evento da trovare (facoltativo)", "Words of the event title to find (optional)"))]), .read)
            add("calendari", t("Elenca i calendari e le liste di promemoria disponibili.", "Lists the available calendars and reminder lists."), object([:]), .read)
        }
        if enabled.contains(.calendar) {
            add("crea_evento", t("Prepara un evento da confermare. Per eventi di tutto il giorno usa solo la data.", "Prepares an event to confirm. For all-day events use only the date."),
                object(["titolo": ("string", t("Titolo", "Title")), "inizio": ("string", date), "fine": ("string", date),
                        "luogo": ("string", t("Luogo", "Location")), "calendario": ("string", t("Nome del calendario (facoltativo)", "Calendar name (optional)"))],
                       required: ["titolo", "inizio"]), .draft)
        }
        // Documento, foglio o presentazione aperti al centro: l'app applica solo ciò che la richiesta chiede (⌘Z annulla).
        if let kind = work.artifactKind {
            let english = ["documento": "document", "foglio": "spreadsheet", "presentazione": "presentation"][kind] ?? kind
            let title = work.artifactTitle.map { " («\($0)»)" } ?? ""
            add("modifica_aperto", t("Modifica il \(kind) aperto al centro\(title): testo, sezioni, titolo, formattazione, slide, righe, colonne, celle, grafici. Il resto resta identico. Solo quando l'utente chiede di cambiarlo.",
                                     "Edits the \(english) open in the center\(title): text, sections, title, formatting, slides, rows, columns, cells, charts. Everything else stays the same. Only when the user asks to change it."),
                object(["richiesta": ("string", t("La modifica con le parole dell'utente, per esempio «elimina la sezione Rischi» o «cancella tutto e scrivi…»",
                                                  "The change in the user's words, for example «delete the Risks section» or «clear everything and write…»"))],
                       required: ["richiesta"]), .draft)
        }
        // Cambiamenti a ciò che esiste già: l'app trova l'elemento dalla richiesta e prepara la scheda da confermare.
        let request = ("string", t("La richiesta dell'utente con le sue parole, per esempio «sposta la riunione con Marco di domani alle 16»",
                                   "The user's request in their words, for example «move tomorrow's meeting with Mark to 4 pm»"))
        if enabled.contains(.calendar) {
            add("modifica_evento", t("Sposta, anticipa, rimanda, rinomina o cambia luogo o durata di un evento che esiste già.",
                                     "Moves, brings forward, postpones, renames or changes the place or length of an existing event."),
                object(["richiesta": request], required: ["richiesta"]), .draft)
            add("elimina_evento", t("Elimina un evento che esiste già (l'utente conferma).", "Deletes an existing event (the user confirms)."),
                object(["richiesta": request], required: ["richiesta"]), .draft)
        }
        if enabled.contains(.reminders) {
            add("modifica_promemoria", t("Cambia scadenza, testo, lista o priorità di un promemoria che esiste già.",
                                         "Changes the due date, text, list or priority of an existing reminder."),
                object(["richiesta": request], required: ["richiesta"]), .draft)
            add("completa_promemoria", t("Segna come fatto un promemoria che esiste già («ho pagato la bolletta»).", "Marks an existing reminder as done («I paid the bill»)."),
                object(["richiesta": request], required: ["richiesta"]), .draft)
            add("elimina_promemoria", t("Elimina un promemoria che esiste già (l'utente conferma).", "Deletes an existing reminder (the user confirms)."),
                object(["richiesta": request], required: ["richiesta"]), .draft)
        }
        if enabled.contains(.notes) {
            add("aggiungi_a_nota", t("Aggiunge testo in fondo a una nota che esiste già («aggiungi il latte alla nota della spesa»).",
                                     "Appends text to an existing note («add milk to the shopping note»)."),
                object(["richiesta": request], required: ["richiesta"]), .draft)
        }
        if enabled.contains(.mail) {
            add("rispondi_email", t("Prepara la risposta a un'email ricevuta, da aprire in Mail nella stessa conversazione.",
                                    "Prepares the reply to a received email, to open in Mail in the same thread."),
                object(["richiesta": request, "testo": ("string", t("Cosa rispondere, con le parole dell'utente", "What to reply, in the user's words")),
                        "corpo": ("string", t("Testo completo della risposta se lo scrivi tu: saluto, messaggio e ", "Full text of the reply if you write it: greeting, message and ")
                                            + Assistant.signatureRule)],
                       required: ["richiesta"]), .draft)
            add("inoltra_email", t("Prepara l'inoltro di un'email ricevuta (con gli allegati) a un'altra persona.",
                                   "Prepares forwarding a received email (with its attachments) to someone else."),
                object(["richiesta": request], required: ["richiesta"]), .draft)
        }
        if enabled.contains(.reminders) {
            add("crea_promemoria", t("Prepara uno o più promemoria da confermare.", "Prepares one or more reminders to confirm."),
                object(["titoli": ("array", t("Un titolo per promemoria", "One title per reminder")), "scadenza": ("string", date),
                        "lista": ("string", t("Lista (facoltativa)", "List (optional)"))], required: ["titoli"]), .draft)
        }
        if enabled.contains(.mail) {
            add("leggi_email", t("Legge le ultime email in arrivo, o quelle con un testo nell'oggetto o nel mittente.",
                                 "Reads the latest incoming emails, or those with a text in the subject or sender."),
                object(["cerca": ("string", t("Testo da cercare nell'oggetto o nel mittente (facoltativo)", "Text to look for in the subject or sender (optional)")),
                        "non_lette": ("boolean", t("Solo non lette", "Unread only"))]), .read)
            add("scrivi_email", t("Prepara una bozza di email che l'utente rivede e invia da Mail.", "Prepares an email draft that the user reviews and sends from Mail."),
                object(["destinatari": ("array", t("Nomi o indirizzi", "Names or addresses")), "oggetto": ("string", t("Oggetto", "Subject")),
                        "testo": ("string", t("Testo completo, con saluto e ", "Full text, with a greeting and ") + Assistant.signatureRule)],
                       required: ["oggetto", "testo"]), .draft)
        }
        if enabled.contains(.notes) {
            add("leggi_note", t("Cerca nelle Note (o mostra le recenti).", "Searches Notes (or shows the recent ones)."),
                object(["cerca": ("string", t("Testo da cercare", "Text to look for"))]), .read)
            add("crea_nota", t("Prepara una nuova nota da confermare.", "Prepares a new note to confirm."),
                object(["titolo": ("string", t("Titolo", "Title")), "testo": ("string", t("Contenuto", "Content"))], required: ["titolo", "testo"]), .draft)
        }
        if enabled.contains(.messages) {
            add("leggi_messaggi", t("Legge i messaggi recenti (iMessage/SMS), anche di una persona.", "Reads recent messages (iMessage/SMS), also from one person."),
                object(["cerca": ("string", t("Nome o testo", "Name or text"))]), .read)
            add("invia_messaggio", t("Prepara un iMessage: parte solo dopo la conferma esplicita dell'utente.", "Prepares an iMessage: it's sent only after the user's explicit confirmation."),
                object(["destinatario": ("string", t("Nome o numero", "Name or number")), "testo": ("string", t("Testo", "Text"))],
                       required: ["destinatario", "testo"]), .draft)
        }
        if enabled.contains(.files) {
            add("cerca_file_mac", t("Cerca file sul Mac con Spotlight (nome e contenuto).", "Searches files on the Mac with Spotlight (name and content)."),
                object(["cerca": ("string", t("Parole del nome o del contenuto", "Words of the name or content"))], required: ["cerca"]), .read)
        }
        if work.projectRoot != nil {
            // La cartella del progetto collegato è il contesto principale della chat: i file si trovano seguendo le sue istruzioni.
            add("elenca_file", t("Elenca file e cartelle del progetto collegato alla chat (la sua cartella è il contesto principale).",
                                 "Lists files and folders of the project linked to the chat (its folder is the main context)."),
                object(["percorso": ("string", t("Cartella relativa (vuoto = radice)", "Relative folder (empty = root)"))]), .read)
            add("leggi_file", t("Legge un file del progetto (con le regole della sua cartella, se ci sono).", "Reads a project file (with its folder's rules, if any)."),
                object(["percorso": ("string", t("Percorso relativo", "Relative path"))], required: ["percorso"]), .read)
            add("cerca_nei_file", t("Cerca un testo nei nomi e nel contenuto dei file del progetto.", "Searches a text in the names and content of the project files."),
                object(["cerca": ("string", t("Testo", "Text"))], required: ["cerca"]), .read)
            if work.allowFileWrite {
                add("scrivi_file", t("Prepara la creazione di un file nuovo o la riscrittura completa di un file del progetto, da confermare.",
                                     "Prepares creating a new file or fully rewriting a project file, to confirm."),
                    object(["percorso": ("string", t("Percorso relativo con estensione", "Relative path with extension")),
                            "contenuto": ("string", t("Contenuto completo del file", "Full content of the file"))], required: ["percorso", "contenuto"]), .draft)
                add("modifica_file", t("Prepara una modifica a un file esistente del progetto, da confermare: sostituisce un passaggio esatto, o aggiunge in fondo se vecchio_testo è vuoto. Per i file lunghi è meglio di scrivi_file.",
                                       "Prepares a change to an existing project file, to confirm: replaces an exact passage, or appends if vecchio_testo is empty. For long files it's better than scrivi_file."),
                    object(["percorso": ("string", t("Percorso relativo del file", "Relative path of the file")),
                            "vecchio_testo": ("string", t("Passaggio da sostituire, copiato esattamente dal file (vuoto = aggiungi in fondo)", "Passage to replace, copied exactly from the file (empty = append)")),
                            "nuovo_testo": ("string", t("Testo nuovo", "New text"))], required: ["percorso", "nuovo_testo"]), .draft)
                add("sposta_file", t("Prepara lo spostamento o la rinomina di un file o di una cartella del progetto, da confermare.",
                                     "Prepares moving or renaming a project file or folder, to confirm."),
                    object(["da": ("string", t("Percorso attuale", "Current path")), "a": ("string", t("Nuovo percorso o cartella di destinazione", "New path or destination folder"))],
                           required: ["da", "a"]), .draft)
                add("crea_cartella", t("Prepara la creazione di una cartella nel progetto, da confermare.", "Prepares creating a folder in the project, to confirm."),
                    object(["percorso": ("string", t("Percorso relativo della cartella", "Relative path of the folder"))], required: ["percorso"]), .draft)
                add("elimina_file", t("Prepara lo spostamento nel Cestino di un file o di una cartella del progetto, da confermare.",
                                      "Prepares moving a project file or folder to the Trash, to confirm."),
                    object(["percorso": ("string", t("Percorso relativo", "Relative path"))], required: ["percorso"]), .draft)
            }
        }
        if work.webEnabled {
            add("cerca_web", t("Cerca sul web e legge le prime pagine (fonti numerate): per notizie, prezzi, risultati e fatti che cambiano.",
                               "Searches the web and reads the top pages (numbered sources): for news, prices, results and facts that change."),
                object(["cerca": ("string", t("Cosa cercare, in poche parole", "What to search for, in a few words"))], required: ["cerca"]), .read)
            add("leggi_pagina", t("Scarica e legge una pagina web.", "Downloads and reads a web page."),
                object(["url": ("string", t("Indirizzo", "Address"))], required: ["url"]), .read)
        }
        add("cerca_conversazioni", t("Cerca nelle conversazioni passate con l'utente (decisioni, cose dette).", "Searches past conversations with the user (decisions, things said)."),
            object(["cerca": ("string", t("Parole da cercare", "Words to look for"))], required: ["cerca"]), .read)
        add("ricorda", t("Salva un fatto o una preferenza dell'utente nella memoria (solo se lo chiede o lo dichiara).",
                         "Saves a fact or preference of the user in memory (only if they ask or state it)."),
            object(["fatto": ("string", t("Il fatto da ricordare", "The fact to remember"))], required: ["fatto"]), .draft)
        add("crea_documento", t("Crea un documento (Pages) con titolo e testo in Markdown (## per le sezioni).", "Creates a document (Pages) with a title and Markdown text (## for sections)."),
            object(["titolo": ("string", t("Titolo", "Title")), "testo": ("string", t("Contenuto in Markdown", "Content in Markdown"))], required: ["titolo", "testo"]), .draft)
        add("crea_foglio", t("Crea un foglio di calcolo (Numbers) con i dati: una riga per voce e colonne di numeri; l'app aggiunge totali e grafico.",
                             "Creates a spreadsheet (Numbers) with the data: one row per item and columns of numbers; the app adds totals and a chart."),
            object(["titolo": ("string", t("Titolo", "Title")),
                    "colonne": ("array", t("Nomi delle colonne dei numeri, per esempio [\"Importo\"]", "Names of the number columns, for example [\"Amount\"]")),
                    "righe": ("array", t("Una riga per voce: «etichetta: numero; numero», per esempio «Affitto: 850»", "One row per item: «label: number; number», for example «Rent: 850»"))],
                   required: ["titolo", "righe"]), .draft)
        add("crea_presentazione", t("Crea una presentazione (Keynote) con titolo e slide.", "Creates a presentation (Keynote) with a title and slides."),
            object(["titolo": ("string", t("Titolo", "Title")), "sottotitolo": ("string", t("Sottotitolo (facoltativo)", "Subtitle (optional)")),
                    "slide": ("array", t("Una slide per elemento: «Titolo: punto; punto; punto»", "One slide per item: «Title: point; point; point»"))],
                   required: ["titolo", "slide"]), .draft)
        add("genera_immagine", t("Crea un'immagine sul Mac da una descrizione.", "Creates an image on the Mac from a description."),
            object(["descrizione": ("string", t("Cosa disegnare, in poche parole", "What to draw, in a few words")),
                    "stile": ("string", t("animazione, illustrazione o schizzo (facoltativo)", "animation, illustration or sketch (optional)"))],
                   required: ["descrizione"]), .draft)
        // Connettori: ogni strumento con il suo schema (quanti se ne danno al modello lo decide `externalToolList`).
        // Quelli che leggono soltanto partono subito e il risultato torna al modello; gli altri diventano schede da confermare.
        for tool in work.mcpTools {
            let access = tool.isReadOnly ? "" : t(" (modifica il servizio: l'utente conferma nella scheda)", " (changes the service: the user confirms in a card)")
            add(mcpName(tool), "[\(tool.serverName)] " + String(tool.description.prefix(300)) + access,
                tool.inputSchema.object == nil ? object([:]) : tool.inputSchema, tool.isReadOnly ? .read : .draft)
        }
        return tools
    }

    /// Lo strumento dei modelli esterni che corrisponde a un'azione di Apple Intelligence (per confrontarli nei banchi).
    /// nil per `rispondi` (nessuno strumento); i connettori si contano chiamata per chiamata.
    static func toolName(forAction action: Assistant.Action) -> String? {
        switch action {
        case .rispondi: nil
        case .agenda, .eventi, .promemoria: "agenda"
        case .crea_lista_promemoria: "crea_promemoria"
        case .mail_leggi: "leggi_email"
        case .note: "leggi_note"
        case .modifica_nota: "aggiungi_a_nota"
        case .messaggi: "leggi_messaggi"
        case .file: "cerca_file_mac"
        case .file_elenca: "elenca_file"
        case .file_leggi: "leggi_file"
        case .file_cerca: "cerca_nei_file"
        case .file_scrivi: "scrivi_file"
        case .file_sposta: "sposta_file"
        case .file_cartella: "crea_cartella"
        case .file_elimina: "elimina_file"
        case .modifica_artefatto: "modifica_aperto"
        case .strumento_esterno: "mcp"
        default: action.rawValue
        }
    }

    /// Nome valido per le API (lettere, numeri, _ e -). Al massimo 50 caratteri: Claude Code aggiunge «mcp__siriai__» davanti
    /// e le API ne accettano 64. Un nome troppo lungo si accorcia con un suffisso che resta diverso da quello degli altri.
    public static func mcpName(_ tool: MCPToolInfo) -> String {
        let raw = "mcp__\(tool.serverName)__\(tool.name)"
        let cleaned = raw.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? String($0) : "_" }.joined()
        guard cleaned.count > 50 else { return cleaned }
        // FNV-1a del nome intero: stabile tra un avvio e l'altro (l'hash di Swift non lo è).
        var hash: UInt32 = 2_166_136_261
        for byte in raw.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(cleaned.prefix(43)) + "_" + String(String(hash, radix: 36).prefix(6))
    }
}

extension Assistant {
    /// Esegue uno strumento chiesto da un modello esterno. Le letture restituiscono dati;
    /// ciò che scrive o invia diventa una scheda da confermare (mai eseguito da solo).
    public func runTool(_ name: String, arguments: JSONValue, enabled: Set<SourceKind>,
                        allowedMCP: (MCPToolInfo) -> Bool = { _ in false },
                        status: @escaping @MainActor (String) -> Void) async -> ToolCallResult {
        func text(_ key: String) -> String? {
            guard let value = arguments[key] else { return nil }
            switch value {
            case .string(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
            case .number(let n): return Int(exactly: n).map(String.init) ?? String(n)
            case .bool(let b): return b ? "sì" : "no"
            default: return value.compactString
            }
        }
        /// Righe o slide: un elenco, o un testo con una voce per riga (le virgole restano dentro la voce).
        func entries(_ key: String) -> [String] {
            if let array = arguments[key]?.array { return array.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            guard let raw = text(key) else { return [] }
            let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-•*"))) }
            return lines.filter { !$0.isEmpty }
        }
        func list(_ key: String) -> [String] {
            if let array = arguments[key]?.array { return array.compactMap(\.string).filter { !$0.isEmpty } }
            return text(key).map { $0.components(separatedBy: CharacterSet(charactersIn: ",;")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? []
        }
        func read(_ action: Action, _ fields: [String: String], prompt: String) async -> ToolCallResult {
            lastError = nil
            lastObservation = nil
            readingForTool = true
            defer { readingForTool = false }
            let outcome = await execute(Plan(action: action, fields: fields), prompt: prompt, rawPrompt: prompt, enabled: enabled, picked: [], status: status)
            if let error = lastError { return ToolCallResult(text: "Errore: \(error)", ok: false) }
            if let data = lastObservation { return ToolCallResult(text: String(data.prefix(budget.scaled(3000))), outcome: outcome) }
            if case .message(let message) = outcome { return ToolCallResult(text: message, ok: false) }
            if case .unavailable(let source, _) = outcome { return ToolCallResult(text: "\(source.label) non è collegato o non è autorizzato.", ok: false) }
            return ToolCallResult(text: "Fatto.", outcome: outcome)
        }
        let started = Date.now
        let result: ToolCallResult = await {
            switch name {
            case "agenda":
                // Con «cerca» solo gli eventi con quel nome (senza date l'app guarda dal mese scorso ai prossimi sei mesi).
                let fields = ["dal": text("dal") ?? "", "al": text("al") ?? "", "cerca": text("cerca") ?? ""].filter { !$0.value.isEmpty }
                return await read(fields["cerca"] == nil ? .agenda : .eventi, fields, prompt: text("cerca") ?? "agenda")
            case "calendari": return await read(.calendari, [:], prompt: "calendari e liste")
            case "leggi_email": return await read(.mail_leggi, ["cerca": text("cerca") ?? ""].filter { !$0.value.isEmpty }, prompt: text("non_lette") == "sì" ? "email non lette" : (text("cerca") ?? "email recenti"))
            case "leggi_note": return await read(.note, ["cerca": text("cerca") ?? ""].filter { !$0.value.isEmpty }, prompt: text("cerca") ?? "note recenti")
            case "leggi_messaggi": return await read(.messaggi, ["cerca": text("cerca") ?? ""].filter { !$0.value.isEmpty }, prompt: text("cerca") ?? "messaggi recenti")
            case "cerca_file_mac": return await read(.file, ["cerca": text("cerca") ?? ""], prompt: text("cerca") ?? "")
            case "elenca_file":
                var result = await read(.file_elenca, ["percorso": text("percorso") ?? ""], prompt: "elenca i file")
                if result.ok, let folder = text("percorso"), let rules = newFolderInstructions(for: folder, limit: 3000) { result.text += "\n\n" + rules }
                return result
            case "leggi_file":
                var result = await read(.file_leggi, ["percorso": text("percorso") ?? ""], prompt: "leggi \(text("percorso") ?? "")")
                // Prima volta in una cartella con le sue istruzioni: il modello le riceve insieme al file.
                if result.ok, let path = text("percorso"), let found = work.files?.find(path) ?? text("percorso"),
                   let rules = newFolderInstructions(for: found, limit: 3000) { result.text += "\n\n" + rules }
                return result
            case "cerca_nei_file": return await read(.file_cerca, ["cerca": text("cerca") ?? ""], prompt: text("cerca") ?? "")
            case "cerca_web": return await read(.cerca_web, ["cerca": text("cerca") ?? ""], prompt: text("cerca") ?? "")
            case "leggi_pagina": return await read(.leggi_pagina, ["argomento": text("url") ?? ""], prompt: text("url") ?? "")
            case "cerca_conversazioni": return await read(.cerca_conversazioni, ["cerca": text("cerca") ?? ""], prompt: text("cerca") ?? "")
            case "ricorda":
                guard let fact = text("fatto") else { return ToolCallResult(text: "Manca il fatto da ricordare.", ok: false) }
                return await read(.ricorda, ["argomento": fact], prompt: fact)
            case "crea_evento":
                guard enabled.contains(.calendar) else { return ToolCallResult(text: "Il Calendario non è collegato.", ok: false) }
                guard let title = text("titolo"), let planned = Dates.parse(text("inizio")) else { return ToolCallResult(text: "Servono titolo e data d'inizio.", ok: false) }
                // Il giorno detto nella richiesta («giovedì») vale più di quello calcolato dal modello: inizio e fine insieme.
                let shift = Self.weekCorrection(for: planned.date, request: trace?.request ?? "")
                func said(_ date: Date) -> Date { Calendar.current.date(byAdding: .day, value: shift, to: date) ?? date }
                let start = (date: said(planned.date), hasTime: planned.hasTime)
                let begin = start.hasTime ? start.date : Calendar.current.startOfDay(for: start.date)
                var end = Dates.parse(text("fine")).map { said($0.date) } ?? begin.addingTimeInterval(start.hasTime ? 3600 : 86_399)
                if end <= begin { end = begin.addingTimeInterval(3600) }
                let calendar = text("calendario").flatMap { name in EventKitService.writableCalendars().first { $0.localizedCaseInsensitiveContains(name) } } ?? EventKitService.defaultCalendar
                let draft = EventDraft(title: title, start: begin, end: end, isAllDay: !start.hasTime, calendar: calendar, location: text("luogo") ?? "")
                return ToolCallResult(text: "Bozza dell'evento pronta: l'utente la conferma nella scheda.", outcome: .eventDraft(draft))
            case "crea_promemoria":
                guard enabled.contains(.reminders) else { return ToolCallResult(text: "Promemoria non è collegato.", ok: false) }
                let titles = list("titoli")
                guard !titles.isEmpty else { return ToolCallResult(text: "Servono i titoli dei promemoria.", ok: false) }
                let due = Self.dayAsSaid(Dates.parse(text("scadenza")), request: trace?.request)
                let drafts = titles.map { ReminderDraft(title: $0, due: due?.date, dueHasTime: due?.hasTime ?? false) }
                let listName = text("lista").flatMap { n in EventKitService.reminderLists().first { $0.localizedCaseInsensitiveContains(n) } } ?? EventKitService.defaultReminderList
                return ToolCallResult(text: "\(drafts.count) promemoria pronti: l'utente li conferma nella scheda.", outcome: .reminderDrafts(drafts, list: listName))
            case "scrivi_email":
                guard let subject = text("oggetto"), let body = text("testo") else { return ToolCallResult(text: "Servono oggetto e testo.", ok: false) }
                let recipients = list("destinatari").map { Contacts.resolve($0).flatMap { $0.contains("@") ? $0 : nil } ?? $0 }
                return ToolCallResult(text: "Bozza email pronta: l'utente la rivede e la invia da Mail.", outcome: .mailDraft(MailDraft(recipients: recipients, subject: subject, body: body)))
            case "crea_nota":
                guard let title = text("titolo"), let body = text("testo") else { return ToolCallResult(text: "Servono titolo e testo.", ok: false) }
                return ToolCallResult(text: "Nota pronta: l'utente la conferma nella scheda.", outcome: .noteDraft(NoteDraft(title: title, body: body)))
            case "invia_messaggio":
                guard let recipient = text("destinatario"), let body = text("testo") else { return ToolCallResult(text: "Servono destinatario e testo.", ok: false) }
                return ToolCallResult(text: "Messaggio pronto: parte solo se l'utente conferma.",
                                      outcome: .messageDraft(MessageDraft(recipient: recipient, handle: Contacts.resolve(recipient) ?? "", text: body)))
            case "scrivi_file":
                guard let files = work.files, work.allowFileWrite else { return ToolCallResult(text: "Nel progetto posso solo leggere.", ok: false) }
                guard let path = text("percorso"), let content = arguments["contenuto"]?.string else { return ToolCallResult(text: "Servono percorso e contenuto.", ok: false) }
                let existing = files.find(path)
                let previous = existing.flatMap { try? files.read($0, maxChars: 400_000) }
                let draft = FileWriteDraft(path: existing ?? path, content: content, exists: existing != nil, previous: previous.map { String($0.prefix(20_000)) },
                                           change: existing == nil ? nil : "Riscrive il file")
                var result = ToolCallResult(text: "Modifica del file pronta: l'utente la conferma nella scheda.", outcome: .fileWrite(draft))
                if let rules = newFolderInstructions(for: existing ?? path, limit: 3000) {
                    result.text += "\n\nRegole della cartella in cui scrivi: se la scheda non le rispetta, dillo all'utente e preparane una versione corretta.\n" + rules
                }
                return result
            case "modifica_file":
                guard let files = work.files, work.allowFileWrite else { return ToolCallResult(text: "Nel progetto posso solo leggere.", ok: false) }
                guard let path = text("percorso"), let found = files.find(path) else {
                    return ToolCallResult(text: "Il file non esiste nel progetto: per crearlo usa scrivi_file.", ok: false)
                }
                guard ProjectFiles.textExtensions.contains((found as NSString).pathExtension.lowercased()),
                      let original = try? String(contentsOf: files.resolve(found), encoding: .utf8) else {
                    return ToolCallResult(text: "«\(found)» non è un file di testo modificabile.", ok: false)
                }
                let old = arguments["vecchio_testo"]?.string ?? ""
                let new = arguments["nuovo_testo"]?.string ?? ""
                var updated = original
                let change: String
                if old.isEmpty {
                    updated += (original.hasSuffix("\n") || original.isEmpty ? "" : "\n") + new + (new.hasSuffix("\n") ? "" : "\n")
                    change = "Aggiunge in fondo: «\(new.prefix(160))»"
                } else {
                    let count = original.components(separatedBy: old).count - 1
                    guard count > 0 else { return ToolCallResult(text: "vecchio_testo non si trova in \(found): rileggi il file e copia il passaggio esatto.", ok: false) }
                    guard count == 1 else { return ToolCallResult(text: "vecchio_testo compare \(count) volte in \(found): allarga il passaggio per renderlo unico.", ok: false) }
                    updated = original.replacingOccurrences(of: old, with: new)
                    change = "Sostituisce «\(old.prefix(160))» con «\(new.prefix(160))»"
                }
                var result = ToolCallResult(text: "Modifica di \(found) pronta: l'utente la conferma nella scheda.",
                                            outcome: .fileWrite(FileWriteDraft(path: found, content: updated, exists: true, previous: String(original.prefix(20_000)), change: change)))
                if let rules = newFolderInstructions(for: found, limit: 3000) { result.text += "\n\n" + rules }
                return result
            case "sposta_file", "crea_cartella":
                guard let files = work.files, work.allowFileWrite else { return ToolCallResult(text: "Nel progetto posso solo leggere.", ok: false) }
                let plan = name == "sposta_file"
                    ? Plan(action: .file_sposta, fields: ["percorso": text("da") ?? "", "destinazione": text("a") ?? ""])
                    : Plan(action: .file_cartella, fields: ["percorso": text("percorso") ?? ""])
                let outcome = fileOperation(plan, files: files)
                if case .message(let message) = outcome { return ToolCallResult(text: message, ok: false) }
                return ToolCallResult(text: "Operazione pronta: l'utente la conferma nella scheda.", outcome: outcome)
            case "crea_foglio":
                guard let title = text("titolo") else { return ToolCallResult(text: Language.t("Serve il titolo del foglio.", "The spreadsheet needs a title."), ok: false) }
                let rows = entries("righe").compactMap(Self.sheetRow)
                // Senza righe leggibili il foglio lo prepara l'app dal titolo (come con Apple Intelligence).
                guard !rows.isEmpty else {
                    let outcome = await execute(Plan(action: .crea_foglio, fields: ["argomento": title]), prompt: title, rawPrompt: title, enabled: enabled, picked: [], status: status)
                    if case .sheet = outcome { return ToolCallResult(text: Language.t("Foglio creato e aperto per l'utente.", "Spreadsheet created and opened for the user."), outcome: outcome) }
                    return ToolCallResult(text: Language.t("Servono le righe del foglio («etichetta: numero»).", "The spreadsheet needs its rows («label: number»)."), ok: false)
                }
                let width = rows.map(\.values.count).max() ?? 1
                var columns = list("colonne")
                if columns.count < width { columns += (columns.count..<width).map { Language.t("Valore \($0 + 1)", "Value \($0 + 1)") } }
                return ToolCallResult(text: Language.t("Foglio creato e aperto per l'utente.", "Spreadsheet created and opened for the user."),
                                      outcome: .sheet(SheetDraft(title: title, columns: Array(columns.prefix(width)), rows: rows)))
            case "crea_presentazione":
                guard let title = text("titolo") else { return ToolCallResult(text: Language.t("Serve il titolo della presentazione.", "The presentation needs a title."), ok: false) }
                let slides = entries("slide").compactMap(Self.slide)
                guard !slides.isEmpty else {
                    let outcome = await execute(Plan(action: .crea_presentazione, fields: ["argomento": title]), prompt: title, rawPrompt: title, enabled: enabled, picked: [], status: status)
                    if case .deck = outcome { return ToolCallResult(text: Language.t("Presentazione creata e aperta per l'utente.", "Presentation created and opened for the user."), outcome: outcome) }
                    return ToolCallResult(text: Language.t("Servono le slide («Titolo: punto; punto»).", "The presentation needs its slides («Title: point; point»)."), ok: false)
                }
                return ToolCallResult(text: Language.t("Presentazione creata e aperta per l'utente.", "Presentation created and opened for the user."),
                                      outcome: .deck(DeckDraft(title: title, subtitle: text("sottotitolo") ?? "", slides: slides)))
            case "genera_immagine":
                guard let description = text("descrizione") ?? text("argomento") else {
                    return ToolCallResult(text: Language.t("Serve la descrizione dell'immagine.", "The image needs a description."), ok: false)
                }
                return ToolCallResult(text: Language.t("Immagine in preparazione: l'utente la vede nella chat.", "Image being created: the user sees it in the chat."),
                                      outcome: .image(prompt: description, style: text("stile").map(Self.imageStyle)))
            case "elimina_file":
                guard let files = work.files, work.allowFileWrite else { return ToolCallResult(text: Language.t("Nel progetto posso solo leggere.", "In this project I can only read."), ok: false) }
                let outcome = fileOperation(Plan(action: .file_elimina, fields: ["percorso": text("percorso") ?? ""]), files: files)
                if case .message(let message) = outcome { return ToolCallResult(text: message, ok: false) }
                return ToolCallResult(text: Language.t("Spostamento nel Cestino pronto: l'utente lo conferma nella scheda.", "Moving to the Trash is ready: the user confirms it in the card."), outcome: outcome)
            case "crea_documento":
                guard let title = text("titolo"), let body = text("testo") else { return ToolCallResult(text: "Servono titolo e testo.", ok: false) }
                return ToolCallResult(text: "Documento creato e aperto per l'utente.", outcome: .document(Self.document(title: title, markdown: body)))
            case "modifica_aperto":
                guard work.artifactKind != nil else { return ToolCallResult(text: "Non c'è niente di aperto al centro.", ok: false) }
                let request = text("richiesta") ?? lastRequest
                lastError = nil
                let outcome = await execute(Plan(action: .modifica_artefatto, fields: [:]), prompt: request, rawPrompt: request, enabled: enabled, picked: [], status: status)
                if let error = lastError { return ToolCallResult(text: "Errore: \(error)", ok: false) }
                if case .artifactEdit(let edit) = outcome {
                    return ToolCallResult(text: edit.isEmpty ? (edit.summary.isEmpty ? "Non c'era niente da cambiare." : edit.summary) : "Fatto: \(edit.summary)", outcome: outcome)
                }
                if case .message(let message) = outcome { return ToolCallResult(text: message) }
                return ToolCallResult(text: "Fatto.", outcome: outcome)
            case "modifica_evento", "elimina_evento", "modifica_promemoria", "completa_promemoria", "elimina_promemoria", "aggiungi_a_nota", "rispondi_email", "inoltra_email":
                let action: Action = switch name {
                case "modifica_evento": .modifica_evento
                case "elimina_evento": .elimina_evento
                case "modifica_promemoria": .modifica_promemoria
                case "completa_promemoria": .completa_promemoria
                case "elimina_promemoria": .elimina_promemoria
                case "aggiungi_a_nota": .modifica_nota
                case "rispondi_email": .rispondi_email
                default: .inoltra_email
                }
                let request = text("richiesta") ?? lastRequest
                var fields: [String: String] = [:]
                if let answer = text("testo") { fields["testo"] = answer }
                if let body = text("corpo") { fields["corpo"] = body }
                lastError = nil
                let outcome = await execute(Plan(action: action, fields: fields), prompt: request, rawPrompt: request, enabled: enabled, picked: [], status: status)
                if let error = lastError { return ToolCallResult(text: "Errore: \(error)", ok: false) }
                switch outcome {
                case .message(let message): return ToolCallResult(text: message)
                case .unavailable(let source, _): return ToolCallResult(text: "\(source.label) non è collegato o non è autorizzato.", ok: false)
                case .combined(let items):
                    // "Non trovo la nota: te ne preparo una nuova" → il messaggio al modello, la scheda all'utente.
                    let notes = items.dropLast().compactMap { if case .message(let text) = $0 { text } else { nil } }.joined(separator: " ")
                    return ToolCallResult(text: (notes.isEmpty ? "" : notes + " ") + "Scheda pronta: l'utente la controlla e la conferma.", outcome: items.last)
                default: return ToolCallResult(text: "Scheda pronta: l'utente controlla e conferma la modifica.", outcome: outcome)
                }
            default:
                guard name.hasPrefix("mcp__"), let tool = work.mcpTools.first(where: { ToolRegistry.mcpName($0) == name }) else {
                    return ToolCallResult(text: "Strumento sconosciuto: \(name).", ok: false)
                }
                let draft = MCPCallDraft(tool: tool, arguments: arguments.object == nil ? .object([:]) : arguments, request: lastRequest)
                // Gli strumenti già consentiti dall'utente li esegue l'app; gli altri aspettano la conferma nella scheda.
                return ToolCallResult(text: allowedMCP(tool) ? "" : "Chiamata a \(tool.serverName) preparata: l'utente deve confermarla nella scheda.", outcome: .mcpCall(draft))
            }
        }()
        let summary: String = if let outcome = result.outcome, !Self.isObservation(outcome) { "scheda da confermare" } else { String(result.text.prefix(120)) }
        trace?.steps.append(TraceStep(action: name.hasPrefix("mcp__") ? "mcp: " + (name.components(separatedBy: "__").last ?? name) : name,
                                      detail: String(arguments.compactString.prefix(120)), result: summary,
                                      milliseconds: Int(Date.now.timeIntervalSince(started) * 1000), ok: result.ok))
        FixtureWorld.active?.recordTool(name, arguments: arguments, result: result)
        return result
    }

    /// «Affitto: 850» o «Q1: 1.200,50; 980» → una riga del foglio. nil se non ci sono numeri.
    nonisolated static func sheetRow(_ entry: String) -> SheetDraft.Row? {
        let parts = entry.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        let values = parts[1].split(whereSeparator: { $0 == ";" || $0 == "|" }).compactMap { number(String($0)) }
        return values.isEmpty ? nil : SheetDraft.Row(label: parts[0], values: values)
    }

    /// Un numero scritto all'italiana o all'inglese, con o senza valuta: «1.200,50 €», «1,200.50», «850».
    nonisolated static func number(_ text: String) -> Double? {
        var cleaned = text.filter { $0.isNumber || $0 == "," || $0 == "." || $0 == "-" }
        guard !cleaned.isEmpty else { return nil }
        if cleaned.contains(","), cleaned.contains(".") {
            cleaned = cleaned.lastIndex(of: ",")! > cleaned.lastIndex(of: ".")!
                ? cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                : cleaned.replacingOccurrences(of: ",", with: "")
        } else if cleaned.contains(",") {
            // «1,5» è un decimale; «1,200» (tre cifre dopo) sono migliaia.
            let after = cleaned.split(separator: ",").last.map(String.init) ?? ""
            cleaned = after.count == 3 && !cleaned.hasPrefix("0,")
                ? cleaned.replacingOccurrences(of: ",", with: "") : cleaned.replacingOccurrences(of: ",", with: ".")
        } else if cleaned.filter({ $0 == "." }).count > 1 {
            cleaned = cleaned.replacingOccurrences(of: ".", with: "")
        }
        return Double(cleaned)
    }

    /// «Titolo: punto; punto» → una slide (senza punti, solo il titolo).
    nonisolated static func slide(_ entry: String) -> DeckDraft.Slide? {
        let parts = entry.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let title = parts.first, !title.isEmpty else { return nil }
        let bullets = parts.count > 1 ? parts[1].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
        return DeckDraft.Slide(title: title, bullets: bullets)
    }

    /// Lo stile dell'immagine come lo conosce l'app (anche detto in inglese).
    nonisolated static func imageStyle(_ style: String) -> String {
        let lower = style.lowercased()
        if lower.contains("sketch") || lower.contains("schizz") { return "schizzo" }
        if lower.contains("illustra") { return "illustrazione" }
        return "animazione"
    }

    /// Nuova richiesta risposta da un modello esterno con gli strumenti.
    public func beginExternal(_ prompt: String, model: String) {
        beginRequest(prompt)
        trace?.model = model
        lastRequest = prompt
    }

    /// Lo stesso contesto della strada di Apple Intelligence: forma della risposta e calcoli esatti fatti dall'app (date, orari, conti).
    public func prepareExternal(_ prompt: String) async {
        // Chat di un progetto: l'albero della cartella è pronto per scegliere i file da dare al modello.
        await prepareProject()
        // Ciò che l'utente ha davanti nelle app: entra nel preambolo e guida gli strumenti («rispondigli», «spostalo»).
        prepareScreen(for: prompt)
        let style = ResponseStyle.detect(prompt)
        responseStyle = Self.isTextTask(prompt) && style != .creative ? .factual : style
        turnFacts = Self.ruleFacts(for: prompt)
        if turnFacts.isEmpty, !Self.isTextTask(prompt) { turnFacts = await arithmeticFacts(for: prompt) }
        if !turnFacts.isEmpty {
            Agent.log("CALCOLI: \(turnFacts)")
            traceCalculations(turnFacts)
        }
    }

    public func finishExternal() { trace?.finished = .now }

    /// Markdown con sezioni "## …" → documento con titolo, sottotitolo e sezioni.
    static func document(title: String, markdown: String) -> DocumentDraft {
        var sections: [DocumentDraft.Section] = []
        var intro: [String] = []
        var currentTitle: String?
        var currentBody: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let heading = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                if trimmed.hasPrefix("# "), sections.isEmpty, currentTitle == nil { continue }
                if let currentTitle { sections.append(.init(title: currentTitle, body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) }
                currentTitle = heading
                currentBody = []
            } else if currentTitle == nil {
                intro.append(line)
            } else {
                currentBody.append(line)
            }
        }
        if let currentTitle { sections.append(.init(title: currentTitle, body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) }
        let subtitle = intro.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if sections.isEmpty { sections = [.init(title: title, body: markdown)] }
        return DocumentDraft(title: title, subtitle: String(subtitle.prefix(200)), sections: sections)
    }
}
