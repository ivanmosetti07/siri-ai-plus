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

    static let date = "Data come yyyy-MM-dd o yyyy-MM-dd HH:mm"

    /// Strumenti disponibili nel contesto: app collegate, progetto aperto, web, connettori.
    @MainActor
    public static func tools(for work: WorkContext, enabled: Set<SourceKind>) -> [ToolSpec] {
        var tools: [ToolSpec] = []
        if enabled.contains(.calendar) || enabled.contains(.reminders) {
            tools.append(ToolSpec(name: "agenda", description: "Legge eventi del calendario e promemoria in un intervallo di date (dello spazio in uso).",
                                  parameters: object(["dal": ("string", date), "al": ("string", date)]), kind: .read))
            tools.append(ToolSpec(name: "calendari", description: "Elenca i calendari e le liste di promemoria disponibili.", parameters: object([:]), kind: .read))
        }
        if enabled.contains(.calendar) {
            tools.append(ToolSpec(name: "crea_evento", description: "Prepara un evento da confermare. Per eventi di tutto il giorno usa solo la data.",
                                  parameters: object(["titolo": ("string", "Titolo"), "inizio": ("string", date), "fine": ("string", date),
                                                      "luogo": ("string", "Luogo"), "calendario": ("string", "Nome del calendario (facoltativo)")],
                                                     required: ["titolo", "inizio"]), kind: .draft))
        }
        // Documento, foglio o presentazione aperti al centro: l'app applica solo ciò che la richiesta chiede (⌘Z annulla).
        if let kind = work.artifactKind {
            tools.append(ToolSpec(name: "modifica_aperto", description: "Modifica il \(kind) aperto al centro\(work.artifactTitle.map { " («\($0)»)" } ?? ""): testo, sezioni, titolo, formattazione, slide, righe, colonne, celle, grafici. Il resto resta identico.",
                                  parameters: object(["richiesta": ("string", "La modifica con le parole dell'utente, per esempio «elimina la sezione Rischi» o «cancella tutto e scrivi…»")],
                                                     required: ["richiesta"]), kind: .draft))
        }
        // Cambiamenti a ciò che esiste già: l'app trova l'elemento dalla richiesta e prepara la scheda da confermare.
        let request = ("string", "La richiesta dell'utente con le sue parole, per esempio «sposta la riunione con Marco di domani alle 16»")
        if enabled.contains(.calendar) {
            tools.append(ToolSpec(name: "modifica_evento", description: "Sposta, anticipa, rimanda, rinomina o cambia luogo o durata di un evento che esiste già.",
                                  parameters: object(["richiesta": request], required: ["richiesta"]), kind: .draft))
            tools.append(ToolSpec(name: "elimina_evento", description: "Elimina un evento che esiste già (l'utente conferma).",
                                  parameters: object(["richiesta": request], required: ["richiesta"]), kind: .draft))
        }
        if enabled.contains(.reminders) {
            tools.append(ToolSpec(name: "modifica_promemoria", description: "Cambia scadenza, testo, lista o priorità di un promemoria che esiste già.",
                                  parameters: object(["richiesta": request], required: ["richiesta"]), kind: .draft))
            tools.append(ToolSpec(name: "elimina_promemoria", description: "Elimina un promemoria che esiste già (l'utente conferma).",
                                  parameters: object(["richiesta": request], required: ["richiesta"]), kind: .draft))
        }
        if enabled.contains(.notes) {
            tools.append(ToolSpec(name: "aggiungi_a_nota", description: "Aggiunge testo in fondo a una nota che esiste già («aggiungi il latte alla nota della spesa»).",
                                  parameters: object(["richiesta": request], required: ["richiesta"]), kind: .draft))
        }
        if enabled.contains(.mail) {
            tools.append(ToolSpec(name: "rispondi_email", description: "Prepara la risposta a un'email ricevuta, da aprire in Mail nella stessa conversazione.",
                                  parameters: object(["richiesta": request, "testo": ("string", "Cosa rispondere, con le parole dell'utente"),
                                                      "corpo": ("string", "Testo completo della risposta se lo scrivi tu: saluto, messaggio, firma Ivan")],
                                                     required: ["richiesta"]), kind: .draft))
            tools.append(ToolSpec(name: "inoltra_email", description: "Prepara l'inoltro di un'email ricevuta (con gli allegati) a un'altra persona.",
                                  parameters: object(["richiesta": request], required: ["richiesta"]), kind: .draft))
        }
        if enabled.contains(.reminders) {
            tools.append(ToolSpec(name: "crea_promemoria", description: "Prepara uno o più promemoria da confermare.",
                                  parameters: object(["titoli": ("array", "Un titolo per promemoria"), "scadenza": ("string", date),
                                                      "lista": ("string", "Lista (facoltativa)")], required: ["titoli"]), kind: .draft))
        }
        if enabled.contains(.mail) {
            tools.append(ToolSpec(name: "leggi_email", description: "Legge le ultime email in arrivo, o quelle con un testo nell'oggetto o nel mittente.",
                                  parameters: object(["cerca": ("string", "Testo da cercare (facoltativo)"), "non_lette": ("boolean", "Solo non lette")]), kind: .read))
            tools.append(ToolSpec(name: "scrivi_email", description: "Prepara una bozza di email che l'utente rivede e invia da Mail.",
                                  parameters: object(["destinatari": ("array", "Nomi o indirizzi"), "oggetto": ("string", "Oggetto"), "testo": ("string", "Corpo completo")],
                                                     required: ["oggetto", "testo"]), kind: .draft))
        }
        if enabled.contains(.notes) {
            tools.append(ToolSpec(name: "leggi_note", description: "Cerca nelle Note (o mostra le recenti).", parameters: object(["cerca": ("string", "Testo da cercare")]), kind: .read))
            tools.append(ToolSpec(name: "crea_nota", description: "Prepara una nuova nota da confermare.",
                                  parameters: object(["titolo": ("string", "Titolo"), "testo": ("string", "Contenuto")], required: ["titolo", "testo"]), kind: .draft))
        }
        if enabled.contains(.messages) {
            tools.append(ToolSpec(name: "leggi_messaggi", description: "Legge i messaggi recenti (iMessage/SMS), anche di una persona.",
                                  parameters: object(["cerca": ("string", "Nome o testo")]), kind: .read))
            tools.append(ToolSpec(name: "invia_messaggio", description: "Prepara un iMessage: parte solo dopo la conferma esplicita dell'utente.",
                                  parameters: object(["destinatario": ("string", "Nome o numero"), "testo": ("string", "Testo")], required: ["destinatario", "testo"]), kind: .draft))
        }
        if enabled.contains(.files) {
            tools.append(ToolSpec(name: "cerca_file_mac", description: "Cerca file sul Mac con Spotlight.", parameters: object(["cerca": ("string", "Nome o testo")], required: ["cerca"]), kind: .read))
        }
        if work.projectRoot != nil {
            // La cartella del progetto collegato è il contesto principale della chat: i file si trovano seguendo le sue istruzioni.
            tools.append(ToolSpec(name: "elenca_file", description: "Elenca file e cartelle del progetto collegato alla chat (la sua cartella è il contesto principale).",
                                  parameters: object(["percorso": ("string", "Cartella relativa (vuoto = radice)")]), kind: .read))
            tools.append(ToolSpec(name: "leggi_file", description: "Legge un file del progetto (con le regole della sua cartella, se ci sono).",
                                  parameters: object(["percorso": ("string", "Percorso relativo")], required: ["percorso"]), kind: .read))
            tools.append(ToolSpec(name: "cerca_nei_file", description: "Cerca un testo nei nomi e nel contenuto dei file del progetto.", parameters: object(["cerca": ("string", "Testo")], required: ["cerca"]), kind: .read))
            if work.allowFileWrite {
                tools.append(ToolSpec(name: "scrivi_file", description: "Prepara la creazione di un file nuovo o la riscrittura completa di un file del progetto, da confermare.",
                                      parameters: object(["percorso": ("string", "Percorso relativo con estensione"), "contenuto": ("string", "Contenuto completo del file")],
                                                         required: ["percorso", "contenuto"]), kind: .draft))
                tools.append(ToolSpec(name: "modifica_file", description: "Prepara una modifica a un file esistente del progetto, da confermare: sostituisce un passaggio esatto, o aggiunge in fondo se vecchio_testo è vuoto. Per i file lunghi è meglio di scrivi_file.",
                                      parameters: object(["percorso": ("string", "Percorso relativo del file"), "vecchio_testo": ("string", "Passaggio da sostituire, copiato esattamente dal file (vuoto = aggiungi in fondo)"),
                                                          "nuovo_testo": ("string", "Testo nuovo")], required: ["percorso", "nuovo_testo"]), kind: .draft))
                tools.append(ToolSpec(name: "sposta_file", description: "Prepara lo spostamento o la rinomina di un file o di una cartella del progetto, da confermare.",
                                      parameters: object(["da": ("string", "Percorso attuale"), "a": ("string", "Nuovo percorso o cartella di destinazione")], required: ["da", "a"]), kind: .draft))
                tools.append(ToolSpec(name: "crea_cartella", description: "Prepara la creazione di una cartella nel progetto, da confermare.",
                                      parameters: object(["percorso": ("string", "Percorso relativo della cartella")], required: ["percorso"]), kind: .draft))
            }
        }
        if work.webEnabled {
            tools.append(ToolSpec(name: "cerca_web", description: "Cerca sul web e legge le prime pagine (fonti numerate).", parameters: object(["cerca": ("string", "Cosa cercare")], required: ["cerca"]), kind: .read))
            tools.append(ToolSpec(name: "leggi_pagina", description: "Scarica e legge una pagina web.", parameters: object(["url": ("string", "Indirizzo")], required: ["url"]), kind: .read))
        }
        tools.append(ToolSpec(name: "cerca_conversazioni", description: "Cerca nelle conversazioni passate con l'utente (decisioni, cose dette).",
                              parameters: object(["cerca": ("string", "Parole da cercare")], required: ["cerca"]), kind: .read))
        tools.append(ToolSpec(name: "ricorda", description: "Salva un fatto o una preferenza dell'utente nella memoria (solo se lo chiede o lo dichiara).",
                              parameters: object(["fatto": ("string", "Il fatto da ricordare")], required: ["fatto"]), kind: .draft))
        tools.append(ToolSpec(name: "crea_documento", description: "Crea un documento (Pages) con titolo e testo in Markdown (## per le sezioni).",
                              parameters: object(["titolo": ("string", "Titolo"), "testo": ("string", "Contenuto in Markdown")], required: ["titolo", "testo"]), kind: .draft))
        // Connettori: ogni strumento con il suo schema.
        for tool in work.mcpTools.prefix(40) {
            tools.append(ToolSpec(name: mcpName(tool), description: "[\(tool.serverName)] " + String(tool.description.prefix(300)),
                                  parameters: tool.inputSchema.object == nil ? object([:]) : tool.inputSchema, kind: .draft))
        }
        return tools
    }

    /// Nome valido per le API (lettere, numeri, _ e -, al massimo 64 caratteri).
    public static func mcpName(_ tool: MCPToolInfo) -> String {
        let raw = "mcp__\(tool.serverName)__\(tool.name)"
        let cleaned = raw.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? String($0) : "_" }.joined()
        return String(cleaned.prefix(64))
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
            case "agenda": return await read(.agenda, ["dal": text("dal") ?? "", "al": text("al") ?? ""].filter { !$0.value.isEmpty }, prompt: "agenda")
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
                guard let title = text("titolo"), let start = Dates.parse(text("inizio")) else { return ToolCallResult(text: "Servono titolo e data d'inizio.", ok: false) }
                let begin = start.hasTime ? start.date : Calendar.current.startOfDay(for: start.date)
                var end = Dates.parse(text("fine"))?.date ?? begin.addingTimeInterval(start.hasTime ? 3600 : 86_399)
                if end <= begin { end = begin.addingTimeInterval(3600) }
                let calendar = text("calendario").flatMap { name in EventKitService.writableCalendars().first { $0.localizedCaseInsensitiveContains(name) } } ?? EventKitService.defaultCalendar
                let draft = EventDraft(title: title, start: begin, end: end, isAllDay: !start.hasTime, calendar: calendar, location: text("luogo") ?? "")
                return ToolCallResult(text: "Bozza dell'evento pronta: l'utente la conferma nella scheda.", outcome: .eventDraft(draft))
            case "crea_promemoria":
                guard enabled.contains(.reminders) else { return ToolCallResult(text: "Promemoria non è collegato.", ok: false) }
                let titles = list("titoli")
                guard !titles.isEmpty else { return ToolCallResult(text: "Servono i titoli dei promemoria.", ok: false) }
                let due = Dates.parse(text("scadenza"))
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
            case "modifica_evento", "elimina_evento", "modifica_promemoria", "elimina_promemoria", "aggiungi_a_nota", "rispondi_email", "inoltra_email":
                let action: Action = switch name {
                case "modifica_evento": .modifica_evento
                case "elimina_evento": .elimina_evento
                case "modifica_promemoria": .modifica_promemoria
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
        return result
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
