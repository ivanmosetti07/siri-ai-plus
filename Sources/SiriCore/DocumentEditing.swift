import AppKit
import Foundation
import FoundationModels
import NaturalLanguage

// MARK: - Documento aperto visto dal motore

/// Il documento aperto al centro: paragrafi con il loro stile. Il testo con gli attributi (font, immagini, link) resta
/// nell'app, che applica le operazioni senza toccare i paragrafi che non cambiano.
public struct DocumentOutline: Sendable, Equatable {
    public enum Style: String, Sendable, CaseIterable {
        case titolo, sottotitolo, intestazione, sottointestazione, testo, didascalia

        public var isHeading: Bool { self == .intestazione || self == .sottointestazione }
        public var isTitle: Bool { self == .titolo || self == .sottotitolo }
        /// Livello per le sezioni: il titolo chiude tutto, l'intestazione le sotto-intestazioni.
        var level: Int {
            switch self {
            case .titolo, .sottotitolo: 0
            case .intestazione: 1
            case .sottointestazione: 2
            case .testo, .didascalia: 3
            }
        }

        /// Nome dello stile per il modello, nella lingua della richiesta ("heading" in inglese).
        var modelName: String {
            guard Language.isEnglish else { return rawValue }
            switch self {
            case .titolo: return "title"
            case .sottotitolo: return "subtitle"
            case .intestazione: return "heading"
            case .sottointestazione: return "subheading"
            case .testo: return "body"
            case .didascalia: return "caption"
            }
        }

        /// Stile dal nome scelto dal modello, in italiano o in inglese.
        init?(modelName name: String) {
            let english: [String: Style] = ["title": .titolo, "subtitle": .sottotitolo, "heading": .intestazione, "subheading": .sottointestazione,
                                            "body": .testo, "text": .testo, "caption": .didascalia]
            guard let style = Style(rawValue: name) ?? english[name.lowercased()] else { return nil }
            self = style
        }
    }

    public struct Paragraph: Sendable, Equatable {
        public var text: String
        public var style: Style
        public var format: TextFormat?

        public init(_ text: String, _ style: Style = .testo, format: TextFormat? = nil) {
            self.text = text; self.style = style; self.format = format
        }
    }

    public var paragraphs: [Paragraph]
    /// Paragrafi toccati dalla selezione nell'editor e testo selezionato (vuoti se non c'è selezione).
    public var selected: [Int]
    public var selectedText: String?
    /// Paragrafo in cui sta il cursore.
    public var cursor: Int?

    public init(paragraphs: [Paragraph], selected: [Int] = [], selectedText: String? = nil, cursor: Int? = nil) {
        self.paragraphs = paragraphs; self.selected = selected; self.selectedText = selectedText; self.cursor = cursor
    }

    /// Da testo semplice: "# " titolo, "## " intestazione; senza segni, prima riga titolo e righe brevi senza punto finale intestazioni.
    public init(plain: String) {
        let lines = plain.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let marked = lines.contains { $0.hasPrefix("#") }
        paragraphs = lines.enumerated().map { index, line in
            if line.hasPrefix("## ") { return Paragraph(String(line.dropFirst(3)), .intestazione) }
            if line.hasPrefix("# ") { return Paragraph(String(line.dropFirst(2)), .titolo) }
            if marked { return Paragraph(line, .testo) }
            if index == 0 { return Paragraph(line, .titolo) }
            let short = line.count < 60 && !line.hasSuffix(".") && !line.hasSuffix(":")
            return Paragraph(line, short ? .intestazione : .testo)
        }
        selected = []
        selectedText = nil
        cursor = nil
    }

    public var plainText: String { paragraphs.map(\.text).joined(separator: "\n") }

    /// Testo con i segni dello stile ("# titolo", "## intestazione", "**grassetto**"): per valutazioni e confronti.
    public func rendered() -> String {
        paragraphs.map { paragraph in
            var text = paragraph.text
            switch paragraph.format {
            case .grassetto?: text = "**\(text)**"
            case .corsivo?: text = "_\(text)_"
            case .sottolineato?: text = "<u>\(text)</u>"
            default: break
            }
            switch paragraph.style {
            case .titolo: return "# " + text
            case .intestazione: return "## " + text
            case .sottointestazione: return "### " + text
            default: return text
            }
        }.joined(separator: "\n")
    }

    public var titleIndex: Int? { paragraphs.firstIndex { $0.style == .titolo } }
    public var headingIndices: [Int] { paragraphs.indices.filter { paragraphs[$0].style.isHeading } }
    public var bodyIndices: [Int] { paragraphs.indices.filter { !paragraphs[$0].style.isHeading && !paragraphs[$0].style.isTitle } }

    /// Fine (esclusa) della sezione che comincia con l'intestazione `heading`: fino alla prossima intestazione di pari livello o superiore.
    public func sectionEnd(after heading: Int) -> Int {
        guard paragraphs.indices.contains(heading) else { return heading + 1 }
        let level = paragraphs[heading].style.level
        var index = heading + 1
        while index < paragraphs.count, paragraphs[index].style.level > level { index += 1 }
        return index
    }

    /// Intestazione che corrisponde meglio a un nome ("rischi", "la sezione sul budget").
    public func heading(matching name: String) -> Int? {
        var wanted = DocumentOutline.words(name)
        // In inglese "the", "about", "section"… non dicono quale sezione (se resta almeno una parola).
        if Language.isEnglish {
            let filler: Set = ["the", "and", "for", "about", "with", "from", "secti", "part", "parts", "chapt", "parag", "one", "ones", "that", "this"]
            if !wanted.subtracting(filler).isEmpty { wanted.subtract(filler) }
        }
        guard !wanted.isEmpty else { return nil }
        let scored = headingIndices.map { index -> (Int, Int) in
            let words = DocumentOutline.words(paragraphs[index].text)
            let key = paragraphs[index].text.lowercased()
            let contains = key.contains(name.lowercased()) || name.lowercased().contains(key) ? 3 : 0
            return (index, words.intersection(wanted).count * 2 + contains)
        }
        return scored.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
            .map { $0.count > 5 ? String($0.prefix(5)) : $0 })
    }

    /// Paragrafi numerati per il modello, entro un numero di caratteri: quelli lunghi sono accorciati con "…".
    func numbered(characters: Int) -> (text: String, truncated: Set<Int>) {
        let share = max(80, characters / max(1, paragraphs.count))
        var truncated = Set<Int>()
        let lines = paragraphs.enumerated().map { index, paragraph -> String in
            var text = paragraph.text
            if text.count > max(share, 160) {
                text = String(text.prefix(max(share, 160))) + "…"
                truncated.insert(index)
            }
            let marks = (selected.contains(index) ? Language.t(" [selezionato]", " [selected]") : "")
                + (cursor == index && selected.isEmpty ? Language.t(" [cursore]", " [cursor]") : "")
            return "[P\(index + 1)] (\(paragraph.style.modelName))\(marks) \(text)"
        }
        return (lines.joined(separator: "\n"), truncated)
    }
}

public enum TextFormat: String, Sendable, CaseIterable {
    case grassetto, corsivo, sottolineato, normale

    /// Formato dal nome scelto dal modello, in italiano o in inglese.
    init?(modelName name: String) {
        let english: [String: TextFormat] = ["bold": .grassetto, "italic": .corsivo, "italics": .corsivo, "underline": .sottolineato,
                                             "underlined": .sottolineato, "normal": .normale, "plain": .normale]
        guard let format = TextFormat(rawValue: name) ?? english[name.lowercased()] else { return nil }
        self = format
    }
}

/// Una modifica al documento. Gli indici si riferiscono ai paragrafi del documento prima della modifica.
public enum DocumentOperation: Sendable, Equatable {
    /// Nuovo testo del paragrafo, stesso stile.
    case replace(Int, String)
    /// Paragrafi nuovi dopo il paragrafo indicato (-1 = all'inizio).
    case insert(after: Int, [DocumentOutline.Paragraph])
    case delete([Int])
    case restyle([Int], DocumentOutline.Style)
    case format([Int], TextFormat)
    /// Tutto il contenuto sostituito (vuoto = documento svuotato).
    case replaceAll([DocumentOutline.Paragraph])
    /// Operazioni sulla selezione dell'editor (anche parti di un paragrafo).
    case replaceSelection(String)
    case deleteSelection
    case formatSelection(TextFormat)
}

public struct DocumentEditPlan: Sendable, Equatable {
    public var operations: [DocumentOperation]
    /// Cosa è cambiato, in una frase per la chat.
    public var summary: String

    public init(operations: [DocumentOperation], summary: String) { self.operations = operations; self.summary = summary }
}

extension DocumentOutline {
    /// Applica le operazioni (indici del documento di partenza). Serve per le prove; l'app fa lo stesso sul testo con gli attributi.
    public func applying(_ operations: [DocumentOperation]) -> DocumentOutline {
        if let all = operations.last(where: { if case .replaceAll = $0 { true } else { false } }), case .replaceAll(let paragraphs) = all {
            return DocumentOutline(paragraphs: paragraphs)
        }
        var replaced: [Int: String] = [:]
        var deleted = Set<Int>()
        var styles: [Int: Style] = [:]
        var formats: [Int: TextFormat] = [:]
        var inserted: [Int: [Paragraph]] = [:]
        for operation in operations {
            switch operation {
            case .replace(let index, let text): replaced[index] = text
            case .insert(let after, let items): inserted[after, default: []] += items
            case .delete(let indices): deleted.formUnion(indices)
            case .restyle(let indices, let style): for index in indices { styles[index] = style }
            case .format(let indices, let format): for index in indices { formats[index] = format }
            case .replaceSelection(let text):
                if let first = selected.first { replaced[first] = text; deleted.formUnion(selected.dropFirst()) }
            case .deleteSelection: deleted.formUnion(selected)
            case .formatSelection(let format): for index in selected { formats[index] = format }
            case .replaceAll: break
            }
        }
        var result: [Paragraph] = inserted[-1] ?? []
        for (index, paragraph) in paragraphs.enumerated() {
            if !deleted.contains(index) {
                var copy = paragraph
                if let text = replaced[index] { copy.text = text }
                if let style = styles[index] { copy.style = style }
                if let format = formats[index] { copy.format = format == .normale ? nil : format }
                result.append(copy)
            }
            result += inserted[index] ?? []
        }
        return DocumentOutline(paragraphs: result)
    }
}

// MARK: - Riconoscimento dei comandi

extension Assistant {
    /// Verbi che chiedono di cambiare ciò che è aperto al centro.
    static let editVerbs = ["cancella", "elimina", "svuota", "togli", "rimuovi", "pulisci", "scrivi", "scrivici", "aggiungi", "inserisci", "metti",
                            "sostituisci", "rimpiazza", "modifica", "cambia", "correggi", "riscrivi", "traduci", "rendi", "accorcia", "allunga",
                            "espandi", "sposta", "rinomina", "intitola", "formatta", "sottolinea", "evidenzia", "tieni", "lascia", "mantieni",
                            "raddoppia", "dimezza", "aumenta", "diminuisci", "ordina", "somma", "unisci", "dividi", "migliora", "semplifica",
                            "aggiorna", "imposta", "crea un grafico", "fai un grafico", "duplica", "inverti", "abbrevia", "centra", "allinea"]

    /// Parole che indicano un'altra app: con queste il comando non riguarda il documento aperto.
    static let otherTargets = ["evento", "eventi", "riunion", "appuntament", "calendario", "promemoria", "email", "e-mail", " mail", " posta",
                               "messaggio", "messaggi", "imessage", "sms", "contatto", "cartella", "sul mac", "nel progetto", "sito web", "agente",
                               " call ", "meeting", "videochiamat", "alla nota", "nella nota", "sulla nota", "nelle note", "alle note"]

    /// Verbi inglesi che chiedono di cambiare ciò che è aperto, all'inizio di una frase o di una sua parte ("…, then delete…").
    /// "Make" solo su qualcosa che c'è già ("make the intro shorter", non "make a reservation"); i grafici come "crea un grafico".
    static let englishEditVerbs = #"(?:delete|erase|clear|empty|wipe|remove|clean(?:\s+up)?|cut|drop|write|type|add|insert|put|append|prepend|"#
        + #"replace|substitute|swap|edit|modify|change|alter|adjust|tweak|fix|correct|rewrite|rephrase|reword|paraphrase|translate|shorten|"#
        + #"lengthen|expand|extend|condense|trim|move|rename|retitle|title|format|bold|italici[sz]e|underline|highlight|capitali[sz]e|"#
        + #"keep(?!\s+in\s+mind)|leave|double|triple|halve|increase|decrease|reduce|sort|sum(?!\s+up)|merge|combine|split|improve|simplify|"#
        + #"polish|proofread|update|set|duplicate|invert|reverse|abbreviate|cent(?:er|re)|align|(?:call|name)\s+(?:it|this)|"#
        + #"make\s+(?:the|this|that|these|those|them|it|its|all|everything|each|every|my|our|your)|"#
        + #"(?:create|make|add|insert|draw|build|generate|put)\s+(?:me\s+)?(?:a|an|the)\s+(?:[\w-]+\s+){0,3}(?:chart|graph))\b"#

    /// Dove comincia un comando inglese: all'inizio, dopo la punteggiatura o dopo "and", "then", "please", "I want to"…
    static let englishClauseStart = #"(?:^|[,;:.]\s*|\b(?:and|then|also|please|now|just|let'?s|(?:want|like|need)\s+(?:you\s+)?to)\s+)"#

    /// Parole inglesi che indicano un'altra app (come `otherTargets`): con queste il comando non riguarda ciò che è aperto.
    static let englishOtherTargets = #"\b(?:events?|meetings?|appointments?|calendar|reminders?|e-?mails?|mail|inbox|messages?|imessage|sms|"#
        + #"contact|folder|on\s+(?:the|my)\s+mac|in\s+the\s+project|website|web\s+site|agent|call(?!\s+(?:it|this)\b)|video\s*call|facetime|alarms?|"#
        + #"timers?|(?:shopping|grocery|groceries|to-?do|packing)\s+list|my\s+(?:schedule|agenda|day|week)|"#
        + #"(?:to|in|into|on)\s+(?:the|my|a)\s+(?!speaker\b)(?:[\w-]+\s+){0,2}notes?)\b"#

    /// Un documento, un foglio o una presentazione nuovi: non sono modifiche a ciò che è aperto.
    static let englishNewArtifact = #"\b(?:new|another|a\s+separate|a\s+different)\s+(?:document|doc|presentation|deck|slideshow|sheet|spreadsheet|file)\b"#

    /// Giorni e orari in inglese: "move the dinner to Saturday" riguarda il calendario.
    static let englishWhen = #"\b(?:today|tonight|tomorrow|yesterday|monday|tuesday|wednesday|thursday|friday|saturday|sunday|weekend|"#
        + #"next\s+week|this\s+week|morning|afternoon|evening|noon|midnight)\b|\b\d{1,2}(?::\d{2})?\s*(?:am|pm)\b|\b\d{1,2}:\d{2}\b|\bat\s+\d{1,2}\b"#

    /// Richiesta inglese in minuscolo, senza la cortesia della domanda ("can you delete slide 3?" → "delete slide 3").
    static func englishCommandText(_ prompt: String) -> String {
        var text = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let polite = text.range(of: #"^(?:please\s+)?(?:can|could|would|will)\s+you\s+(?:please\s+)?"#, options: .regularExpression) {
            text = String(text[polite.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ?!."))
        }
        return text
    }

    /// Comando inglese su ciò che è aperto: true o false se decidono le regole inglesi, nil se non c'è un verbo inglese
    /// (allora valgono quelle italiane).
    static func englishArtifactCommand(_ prompt: String) -> Bool? {
        let start = englishCommandText(prompt)
        func has(_ pattern: String) -> Bool { start.range(of: pattern, options: .regularExpression) != nil }
        if start.hasSuffix("?") || has(englishNewArtifact) || has(englishOtherTargets) { return false }
        guard has(englishClauseStart + englishEditVerbs) else { return nil }
        // "Move the dinner to Saturday": spostare con un giorno o un orario riguarda il calendario.
        if has(#"^(?:move|reschedule|postpone|push|delay|bring\s+forward|shift)\b"#),
           !DateExpressions.days(in: start).isEmpty || !DateExpressions.times(in: start).isEmpty || has(englishWhen) { return false }
        return true
    }

    /// Comando di modifica per il documento, il foglio o la presentazione aperti ("cancella tutto e scrivi…", "elimina la slide 3").
    static func isArtifactCommand(_ prompt: String) -> Bool {
        // In inglese prima le regole inglesi; un comando in italiano resta valido.
        if Language.isEnglish, let english = englishArtifactCommand(prompt) { return english }
        let lower = " " + prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) + " "
        let start = lower.trimmingCharacters(in: .whitespaces)
        // Domande e richieste di un documento nuovo non sono modifiche.
        if start.hasSuffix("?") { return false }
        if ["nuovo documento", "nuova presentazione", "nuovo foglio", "un altro documento", "un'altra presentazione", "un altro foglio"].contains(where: lower.contains) { return false }
        guard editVerbs.contains(where: { start.hasPrefix($0) || lower.contains(" \($0) ") || lower.contains(", \($0) ") }) else { return false }
        // "Sposta la cena a sabato": spostare con un giorno o un orario riguarda il calendario.
        if start.range(of: #"^(?:sposta|anticipa|posticipa|rimanda|rinvia)\b"#, options: .regularExpression) != nil,
           !DateExpressions.days(in: start).isEmpty || !DateExpressions.times(in: start).isEmpty { return false }
        return !otherTargets.contains(where: lower.contains)
    }

    /// Domanda inglese su ciò che è aperto ("what does the budget section say?", "summarize this document", "what's the November total?").
    static func isEnglishArtifactQuestion(_ prompt: String) -> Bool {
        let asking = prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        let lower = englishCommandText(prompt)
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        let asks = #"^(?:summari[sz]e|sum\s+up|recap|give\s+me\s+(?:a\s+|an\s+)?(?:summary|recap|overview)|explain|describe|analy[sz]e|evaluate|assess|"#
            + #"comment\s+on|review|what|what's|whats|which|who|whose|where|when|why|how|tell\s+me|find|list|count|show\s+me)\b"#
        // "Is there a section on risks?": le domande sì/no solo con il punto di domanda.
        let yesNo = #"^(?:is|are|does|do|did|was|were|has|have|can|could|should|would)\b"#
        let target = #"\b(?:document|doc|text|presentation|deck|slides?|sheet|spreadsheet|table|section|paragraph|this|these|here|it\s+about|"#
            + #"totals?|rows?|columns?|cells?|chart)\b"#
        guard has(asks) || asking && has(yesNo), has(target) else { return false }
        // "Summarize the intro and add it at the end": è una modifica.
        return asking || !has(englishClauseStart + englishEditVerbs) && !has(#"\b(?:at|to)\s+the\s+(?:end|bottom)\b"#)
    }

    /// Domanda su ciò che è aperto ("riassumi questo documento", "cosa dice la sezione budget?"): si risponde in chat.
    static func isArtifactQuestion(_ prompt: String) -> Bool {
        if Language.isEnglish, isEnglishArtifactQuestion(prompt) { return true }
        let lower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let asks = ["riassumi", "riassumimi", "spiega", "spiegami", "di cosa parla", "cosa dice", "cosa c'è scritto", "analizza", "valuta",
                    "commenta", "quante parole", "quante slide", "quante righe", "qual è", "quali sono", "trova", "dimmi"]
        let target = ["documento", "testo", "presentazione", "slide", "foglio", "tabella", "sezione", "paragrafo", "questo", "questa", "qui"]
        let changes = ["aggiungi", "scrivi nel", "inserisci", "metti", "nel documento un", "in fondo"]
        return asks.contains(where: lower.hasPrefix) && target.contains(where: lower.contains) && !changes.contains(where: lower.contains)
    }

    /// Imperativo: "scrivi…", "crea…", "cancella…". A un comando non si risponde cercando sul web.
    static func isCommand(_ prompt: String) -> Bool {
        let lower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.hasSuffix("?") else { return false }
        // In inglese: "delete…", "create…", "send…" (anche con "please" davanti).
        if Language.isEnglish, lower.range(of: #"^(?:please\s+)?(?:"# + englishEditVerbs + #"|(?:create|make|prepare|send|open|close|save|export|copy|paste|remind|schedule|book|draw|generate|build|draft|compose)\b)"#,
                                            options: .regularExpression) != nil { return true }
        return (editVerbs + ["crea", "creami", "fai", "fammi", "prepara", "preparami", "manda", "invia", "apri", "chiudi", "salva", "esporta",
                             "copia", "incolla", "ricordami", "fissa", "disegna", "genera"]).contains { lower.hasPrefix($0 + " ") || lower == $0 }
    }

    /// "Mi crei un documento dove c'è scritto hello world": il testo da mettere così com'è (nil = documento da scrivere su un argomento).
    public static func literalDocumentText(_ prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        let lower = trimmed.lowercased()
        if Language.isEnglish, let text = englishLiteralDocumentText(trimmed) { return text }
        guard ["documento", "pagina", "file di testo", "pages", "foglio di testo"].contains(where: lower.contains) else { return nil }
        if lower.range(of: #"\b(documento|pagina)\s+(vuot[oa]|bianc[oa])\b"#, options: .regularExpression) != nil { return "" }
        let markers = #"(?:dove c'è scritto|dove c’è scritto|in cui c'è scritto|con scritto|con su scritto|con la scritta|con il testo|con testo|che dice|con dentro(?: scritto)?|contenente(?: il testo)?|con questo testo|con la frase|con le parole)"#
        guard let match = Calculations.matches(markers + #"\s*:?\s*(.+)$"#, in: trimmed).first else { return nil }
        let text = unquoted(match[1])
        return text.isEmpty ? nil : text
    }

    /// "Create a document that says hello world", "a blank page": il testo da mettere così com'è, in inglese.
    static func englishLiteralDocumentText(_ trimmed: String) -> String? {
        let lower = trimmed.lowercased()
        guard lower.range(of: #"\b(?:document|doc|page|text\s+file|pages\s+file|word\s+file)\b"#, options: .regularExpression) != nil else { return nil }
        if lower.range(of: #"\b(?:empty|blank)\s+(?:document|doc|page)\b"#, options: .regularExpression) != nil { return "" }
        let markers = #"(?:that\s+says|which\s+says|saying|that\s+reads|which\s+reads|with\s+(?:the\s+)?text|with\s+(?:the\s+)?words|"#
            + #"with\s+the\s+(?:sentence|phrase)|containing\s+the\s+(?:text|words)|where\s+it\s+says|with\s+this\s+text|with\s+written)"#
        guard let match = Calculations.matches(markers + #"\s*:?\s*(.+)$"#, in: trimmed).first else { return nil }
        let text = unquoted(match[1])
        // "With the text of the speech": un argomento, non il testo da scrivere.
        guard !text.isEmpty, text.lowercased().range(of: #"^(?:of|from|about|on|for)\s"#, options: .regularExpression) == nil else { return nil }
        return text
    }

    /// Testo senza virgolette intorno.
    static func unquoted(_ text: String) -> String {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [("«", "»"), ("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")]
        for (open, close) in pairs where clean.count >= 2 && clean.first == open && clean.last == close {
            clean = String(clean.dropFirst().dropLast())
        }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Testo citato nella richiesta («…», "…", “…”), se c'è.
    static func quoted(_ text: String) -> String? {
        Calculations.matches(#"«([^»]+)»|“([^”]+)”|"([^"]+)""#, in: text).first.flatMap { $0.dropFirst().first { !$0.isEmpty } }
    }

    // MARK: Comandi sul documento che non hanno bisogno del modello

    /// I comandi più comuni, riconosciuti con regole: nessun errore di interpretazione e nessuna attesa.
    public static func quickDocumentEdit(_ instruction: String, outline: DocumentOutline) -> DocumentEditPlan? {
        let prompt = instruction.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        // In inglese prima le regole inglesi; poi quelle italiane (un comando in italiano resta valido).
        if Language.isEnglish, let plan = quickEnglishDocumentEdit(prompt, outline: outline) { return plan }
        let lower = prompt.lowercased()
        let quote = quoted(prompt)
        /// Testo dopo il primo dei segnali indicati (provati in ordine), o tra virgolette.
        func literal(after patterns: String...) -> String? {
            if let quote { return quote }
            for pattern in patterns {
                guard let match = Calculations.matches(pattern + #"\s*:?\s*(.+)$"#, in: prompt).first else { continue }
                let text = unquoted(match[1])
                if !text.isEmpty { return text }
            }
            return nil
        }
        let writeMarkers = #"(?:con scritto|con su scritto|con la scritta|che dice|scrivendo|scrivici|scrivi|metti(?:ci)?|inserisci|lascia(?:ci)?)"#

        // 1. Tenere solo il titolo / cancellare il corpo, eventualmente cambiando il titolo ("tieni solo il titolo con scritto Hello Ivan").
        let keepTitle = lower.range(of: #"(tien|ten|lasci|manten)\w*\s+(solo|soltanto|solamente)\s+(il\s+)?titolo"#, options: .regularExpression) != nil
        let clearBody = lower.range(of: #"^(cancella|elimina|togli|rimuovi|svuota|pulisci)\s+(tutto\s+)?(il\s+|l'\s*)?(corpo|resto|testo sotto|contenuto sotto)"#, options: .regularExpression) != nil
        if keepTitle || clearBody {
            let keep: Set<DocumentOutline.Style> = keepTitle ? [.titolo] : [.titolo, .sottotitolo]
            var operations: [DocumentOperation] = []
            let removed = outline.paragraphs.indices.filter { !keep.contains(outline.paragraphs[$0].style) }
            if !removed.isEmpty { operations.append(.delete(removed)) }
            var summary = keepTitle ? Language.t("Ho lasciato solo il titolo", "I kept only the title")
                : Language.t("Ho cancellato il testo sotto il titolo", "I deleted the text below the title")
            // "Tenendo solo il titolo con scritto X": X è il titolo. "Cancella il corpo e scrivi X": X è il testo nuovo.
            if keepTitle, let title = literal(after: #"(?:con scritto|con su scritto|con la scritta|che dice|cambiandolo in|chiamandolo|scrivendo)"#,
                                              #"titolo\s+(?:in|a|con|:)"#), !title.lowercased().hasPrefix("titolo") {
                if let index = outline.titleIndex { operations.append(.replace(index, title)) } else { operations.append(.insert(after: -1, [.init(title, .titolo)])) }
                summary += Language.t(" e l'ho cambiato in «\(title)»", " and changed it to “\(title)”")
            } else if clearBody, let text = literal(after: #"(?:,|\be\b|\bpoi\b)\s*"# + writeMarkers) {
                let after = outline.paragraphs.lastIndex { keep.contains($0.style) } ?? -1
                operations.append(.insert(after: after, [.init(text, .testo)]))
                summary += Language.t(" e ho scritto «\(text)»", " and wrote “\(text)”")
            }
            if outline.titleIndex == nil, keepTitle, operations.isEmpty { return nil }
            let removedText = removed.count == 1 ? Language.t("1 paragrafo tolto", "1 paragraph removed")
                : Language.t("\(removed.count) paragrafi tolti", "\(removed.count) paragraphs removed")
            return DocumentEditPlan(operations: operations, summary: summary + (removed.isEmpty ? "." : " (\(removedText))."))
        }

        // 2. Svuotare tutto, eventualmente scrivendo un testo nuovo ("cancella tutto e scrivi hello world").
        // Solo "tutto" o "il testo" da soli (o seguiti da "e scrivi…"): "cancella il testo del secondo paragrafo" è un'altra cosa.
        let clearAll = lower.range(of: #"^(cancella|svuota|pulisci|elimina|togli|rimuovi)\s+(tutto(\s+quanto)?|tutto il (testo|contenuto|documento)|il (testo|contenuto)|l'intero (testo|documento|contenuto))\s*($|,|\be\b|\bpoi\b)"#, options: .regularExpression) != nil
            || lower.range(of: #"^svuota\s+(il|questo)\s+documento\s*($|,|\be\b)"#, options: .regularExpression) != nil
        if clearAll, !["tranne", "eccetto", "meno il", "selezion"].contains(where: lower.contains) {
            if let text = literal(after: #"(?:,|\be\b|\bpoi\b)\s*"# + writeMarkers + #"(?:\s+solo)?"#) {
                return DocumentEditPlan(operations: [.replaceAll([.init(text, .testo)])], summary: Language.t("Ho cancellato tutto e scritto «\(text)».", "I deleted everything and wrote “\(text)”."))
            }
            return DocumentEditPlan(operations: [.replaceAll([])], summary: Language.t("Ho svuotato il documento.", "I cleared the document."))
        }
        // "Sostituisci tutto con X", "scrivi solo X", "lascia solo X".
        if let match = Calculations.matches(#"^(?:sostituisci|rimpiazza)\s+tutto(?:\s+il\s+(?:testo|contenuto))?\s+con\s+(.+)$"#, in: prompt).first
            ?? Calculations.matches(#"^(?:scrivi|metti|lascia)\s+solo\s+(.+)$"#, in: prompt).first {
            let text = unquoted(match[1])
            guard !text.isEmpty, !text.lowercased().hasPrefix("il titolo") else { return nil }
            return DocumentEditPlan(operations: [.replaceAll([.init(text, .testo)])], summary: Language.t("Ho sostituito tutto con «\(text)».", "I replaced everything with “\(text)”."))
        }

        // 3. Titolo nuovo ("cambia il titolo in «Piano 2027»", "intitolalo Hello").
        if let match = Calculations.matches(#"^(?:cambia|modifica|metti|imposta|rinomina|aggiorna|sostituisci)\s+(?:il\s+)?titolo(?:\s+del\s+documento)?\s*(?:in|con|a|come|:)?\s+(.+)$"#, in: prompt).first
            ?? Calculations.matches(#"^(?:intitola(?:lo)?|chiamalo|dagli come titolo|metti come titolo)\s*:?\s+(.+)$"#, in: prompt).first {
            let title = unquoted(match[1])
            // "Cambia il titolo della sezione Budget in…": non è il titolo del documento.
            guard !title.isEmpty, title.lowercased().range(of: #"^(della|del|dello|dei|delle|degli|di)\s"#, options: .regularExpression) == nil else { return nil }
            if let index = outline.titleIndex {
                return DocumentEditPlan(operations: [.replace(index, title)], summary: Language.t("Ho cambiato il titolo in «\(title)».", "I changed the title to “\(title)”."))
            }
            return DocumentEditPlan(operations: [.insert(after: -1, [.init(title, .titolo)])], summary: Language.t("Ho aggiunto il titolo «\(title)».", "I added the title “\(title)”."))
        }

        // 4. Via titolo o sottotitolo.
        if let match = Calculations.matches(#"^(?:cancella|elimina|togli|rimuovi)\s+(?:il\s+)?(sottotitolo|titolo)$"#, in: prompt).first {
            let style: DocumentOutline.Style = match[1].lowercased() == "titolo" ? .titolo : .sottotitolo
            let indices = outline.paragraphs.indices.filter { outline.paragraphs[$0].style == style }
            guard !indices.isEmpty else { return nil }
            return DocumentEditPlan(operations: [.delete(indices)],
                                    summary: Language.t("Ho tolto il \(match[1].lowercased()).", style == .titolo ? "I removed the title." : "I removed the subtitle."))
        }

        // 5. Via una sezione intera ("elimina la sezione Rischi").
        if let match = Calculations.matches(#"^(?:cancella|elimina|togli|rimuovi)\s+(?:tutta\s+)?(?:la\s+)?(?:sezione|parte|capitolo)\s+(?:su\s+|sui\s+|sul\s+|sulla\s+|sugli\s+|dei\s+|del\s+|della\s+|delle\s+|di\s+|intitolata\s+)?(.+)$"#, in: prompt).first,
           let heading = outline.heading(matching: unquoted(match[1])) {
            let end = outline.sectionEnd(after: heading)
            return DocumentEditPlan(operations: [.delete(Array(heading..<end))],
                                    summary: Language.t("Ho eliminato la sezione «\(outline.paragraphs[heading].text)» (\(end - heading) paragrafi).",
                                                        "I deleted the section “\(outline.paragraphs[heading].text)” (\(paragraphCount(end - heading)))."))
        }

        // 6. Via un paragrafo per posizione ("elimina il secondo paragrafo", "cancella l'ultimo paragrafo").
        let ordinals = ["primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6, "settimo": 7, "ottavo": 8, "nono": 9, "decimo": 10]
        if let match = Calculations.matches(#"^(?:cancella|elimina|togli|rimuovi)\s+(?:il\s+|l'\s*)?(primo|secondo|terzo|quarto|quinto|sesto|settimo|ottavo|nono|decimo|ultimo|penultimo|\d+)[°º]?\s+paragrafo$"#, in: prompt).first
            ?? Calculations.matches(#"^(?:cancella|elimina|togli|rimuovi)\s+(?:il\s+)?paragrafo\s+(\d+)$"#, in: prompt).first {
            let body = outline.bodyIndices
            let word = match[1].lowercased()
            let position: Int? = word == "ultimo" ? body.count : word == "penultimo" ? body.count - 1 : ordinals[word] ?? Int(word)
            guard let position, position >= 1, position <= body.count else { return nil }
            return DocumentEditPlan(operations: [.delete([body[position - 1]])], summary: Language.t("Ho eliminato il paragrafo \(position).", "I deleted paragraph \(position)."))
        }

        // 7. Selezione dell'editor: cancellare o formattare "questo".
        let selectionWords = #"(?:questo|questa|questa parte|questo pezzo|la selezione|il testo selezionato|quello selezionato|ciò che ho selezionato|il selezionato)"#
        if outline.selectedText?.isEmpty == false {
            if lower.range(of: #"^(cancella|elimina|togli|rimuovi)\s+"# + selectionWords + #"$"#, options: .regularExpression) != nil {
                return DocumentEditPlan(operations: [.deleteSelection], summary: Language.t("Ho cancellato il testo selezionato.", "I deleted the selected text."))
            }
        }

        // 8. Formattazione di titoli, intestazioni, tutto o selezione ("metti in grassetto i titoli delle sezioni").
        if let match = Calculations.matches(#"^(?:metti|rendi|fai|scrivi)\s+(?:in\s+)?(grassetto|corsivo)\s+(.+)$"#, in: prompt).first
            ?? Calculations.matches(#"^(sottolinea|evidenzia)\s+(.+)$"#, in: prompt).first {
            let format: TextFormat = match[1].lowercased() == "corsivo" ? .corsivo : match[1].lowercased() == "grassetto" ? .grassetto : .sottolineato
            let target = match[2].lowercased()
            if target.range(of: #"^(i titoli|le intestazioni|tutti i titoli|tutte le intestazioni|i titoli delle sezioni|le intestazioni delle sezioni|i sottotitoli delle sezioni)"#, options: .regularExpression) != nil {
                let indices = outline.headingIndices
                guard !indices.isEmpty else { return nil }
                return DocumentEditPlan(operations: [.format(indices, format)],
                                        summary: indices.count == 1 ? formatSummary(format, "l'intestazione", "the heading")
                                            : formatSummary(format, "\(indices.count) intestazioni", "\(indices.count) headings"))
            }
            if target.range(of: #"^il titolo( del documento)?$"#, options: .regularExpression) != nil, let index = outline.titleIndex {
                return DocumentEditPlan(operations: [.format([index], format)], summary: formatSummary(format, "il titolo", "the title"))
            }
            if target.range(of: #"^(tutto|tutto il testo|il documento|l'intero documento)$"#, options: .regularExpression) != nil {
                return DocumentEditPlan(operations: [.format(Array(outline.paragraphs.indices), format)], summary: formatSummary(format, "tutto il testo", "all the text"))
            }
            if target.range(of: "^" + selectionWords, options: .regularExpression) != nil, outline.selectedText?.isEmpty == false {
                return DocumentEditPlan(operations: [.formatSelection(format)], summary: formatSummary(format, "il testo selezionato", "the selected text"))
            }
        }

        // 9. Scrivere un testo così com'è ("scrivi hello world", "aggiungi «grazie a tutti» in fondo").
        if let match = Calculations.matches(#"^(?:scrivi|scrivici|aggiungi|inserisci|metti)\s+(?:(in fondo|alla fine|all'inizio|in cima|dopo il titolo|sotto il titolo)\s+)?:?\s*(.+?)(?:\s+(in fondo|alla fine|all'inizio|in cima|dopo il titolo|sotto il titolo))?$"#, in: prompt).first {
            var text = unquoted(match[2])
            let place = (match[1].isEmpty ? match[3] : match[1]).lowercased()
            // "Aggiungi una sezione su…", "scrivi un paragrafo sui rischi": contenuto da scrivere, non testo da copiare.
            let generative = #"^(una?|uno|dei|degli|delle|qualche|altri|altre|due|tre|il|la|lo|le|i|gli|l')\s+"#
            let composing = text.lowercased().range(of: generative, options: .regularExpression) != nil && quote == nil
            guard !composing, !text.isEmpty, quote != nil || text.split(separator: " ").count <= 15 else { return nil }
            if let quote { text = quote }
            let paragraph = DocumentOutline.Paragraph(text, .testo)
            switch place {
            case "all'inizio", "in cima", "dopo il titolo", "sotto il titolo":
                let after = outline.paragraphs.lastIndex { $0.style.isTitle } ?? -1
                return DocumentEditPlan(operations: [.insert(after: after, [paragraph])], summary: Language.t("Ho scritto «\(text)» all'inizio.", "I wrote “\(text)” at the beginning."))
            default:
                return DocumentEditPlan(operations: [.insert(after: outline.paragraphs.count - 1, [paragraph])], summary: Language.t("Ho scritto «\(text)» in fondo.", "I wrote “\(text)” at the end."))
            }
        }
        return nil
    }

    /// Frase per un formato applicato ("Ho messo in grassetto il titolo." / "I made the title bold.").
    static func formatSummary(_ format: TextFormat, _ italian: String, _ english: String) -> String {
        let name = format == .grassetto ? "in grassetto" : format == .corsivo ? "in corsivo" : "sottolineato"
        return Language.t("Ho messo \(name) \(italian).", englishFormatSummary(format, english))
    }

    /// "I made the title bold.", "I underlined 5 headings."
    static func englishFormatSummary(_ format: TextFormat, _ what: String) -> String {
        format == .sottolineato ? "I underlined \(what)." : "I made \(what) \(format == .grassetto ? "bold" : "italic")."
    }

    /// "1 paragraph", "3 paragraphs".
    static func paragraphCount(_ count: Int) -> String { count == 1 ? "1 paragraph" : "\(count) paragraphs" }

    /// I comandi comuni in inglese ("delete everything and write…", "keep only the title", "delete the Risks section",
    /// "make the section titles bold"): le stesse operazioni delle regole italiane. Le sezioni si cercano fra le intestazioni
    /// del documento, in qualunque lingua sia scritto.
    static func quickEnglishDocumentEdit(_ prompt: String, outline: DocumentOutline) -> DocumentEditPlan? {
        let lower = prompt.lowercased()
        let quote = quoted(prompt)
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        /// Testo dopo il primo dei segnali indicati (provati in ordine), o tra virgolette.
        func literal(after patterns: String...) -> String? {
            if let quote { return quote }
            for pattern in patterns {
                guard let match = Calculations.matches(pattern + #"\s*:?\s*(.+)$"#, in: prompt).first else { continue }
                let text = unquoted(match[1])
                if !text.isEmpty { return text }
            }
            return nil
        }
        /// Testo da copiare così com'è: "a short intro" (senza virgolette) è un contenuto da scrivere, lo fa il modello.
        func verbatim(_ text: String) -> Bool {
            quote != nil || text.lowercased().range(of: #"^(?:a|an|some|another|one|two|three|new|more)\s"#, options: .regularExpression) == nil
        }
        let delete = #"(?:delete|remove|erase|drop|cut|get\s+rid\s+of)"#
        let writeMarkers = #"(?:saying|that\s+says|which\s+says|writing|write|type|put(?:\s+in)?|insert|add|leave)"#

        // 1. Solo il titolo / via il corpo ("keep only the title", "delete the body and write…").
        let keepTitle = has(#"\b(?:keep|keeping|leave|leaving|retain|retaining|preserve|preserving)\s+(?:only|just|solely)\s+(?:the\s+)?title\b"#)
            || has(#"\b(?:keep|keeping|leave|leaving)\s+(?:the\s+)?title\s+only\b"#)
            || has("^" + delete + #"\s+everything\s+(?:except|but|apart\s+from|other\s+than|besides)\s+(?:the\s+)?title$"#)
        let clearBody = has(#"^(?:delete|remove|erase|clear|empty|wipe|clean)\s+(?:out\s+)?(?:all\s+(?:of\s+)?)?(?:the\s+)?(?:body|rest|(?:text|content)\s+(?:below|under|after))\b"#)
            || has(#"^(?:delete|remove|erase|clear)\s+everything\s+(?:below|under|after)\s+(?:the\s+)?title\b"#)
        if keepTitle || clearBody {
            let keep: Set<DocumentOutline.Style> = keepTitle ? [.titolo] : [.titolo, .sottotitolo]
            var operations: [DocumentOperation] = []
            let removed = outline.paragraphs.indices.filter { !keep.contains(outline.paragraphs[$0].style) }
            if !removed.isEmpty { operations.append(.delete(removed)) }
            var summary = keepTitle ? "I kept only the title" : "I deleted the text below the title"
            // "Keep only the title and change it to X": X è il titolo. "Delete the body and write X": X è il testo nuovo.
            if keepTitle, let title = literal(after: #"(?:saying|that\s+says|which\s+says|with\s+the\s+text|(?:and\s+)?(?:change|changing|rename|renaming|set|setting)\s+it\s+(?:to|as|into)|(?:and\s+)?(?:call|calling|name|naming)\s+it)"#,
                                              #"\btitle\s+(?:to|as|:)"#), !title.lowercased().hasPrefix("title") {
                if let index = outline.titleIndex { operations.append(.replace(index, title)) } else { operations.append(.insert(after: -1, [.init(title, .titolo)])) }
                summary += " and changed it to “\(title)”"
            } else if clearBody, let text = literal(after: #"(?:,|\band\b|\bthen\b)\s*"# + writeMarkers) {
                guard verbatim(text) else { return nil }
                let after = outline.paragraphs.lastIndex { keep.contains($0.style) } ?? -1
                operations.append(.insert(after: after, [.init(text, .testo)]))
                summary += " and wrote “\(text)”"
            }
            if outline.titleIndex == nil, keepTitle, operations.isEmpty { return nil }
            let removedText = removed.count == 1 ? "1 paragraph removed" : "\(removed.count) paragraphs removed"
            return DocumentEditPlan(operations: operations, summary: summary + (removed.isEmpty ? "." : " (\(removedText))."))
        }

        // 2. Svuotare tutto, eventualmente scrivendo un testo nuovo ("delete everything and write hello world").
        // Solo "everything" o "the text" da soli (o seguiti da "and write…"): "delete the text of paragraph 2" è un'altra cosa.
        let clearAll = has(#"^(?:delete|erase|clear|empty|wipe|remove|clean)\s+(?:out\s+)?(?:everything|it\s+all|all\s+of\s+it|all(?:\s+(?:of\s+)?the\s+(?:text|content))?|all\s+(?:text|content)|the\s+(?:whole|entire)\s+(?:text|document|doc|content|thing|page)|the\s+(?:text|content))\s*(?:$|,|\band\b|\bthen\b)"#)
            || has(#"^(?:clear|empty|wipe|clean)\s+(?:out\s+)?(?:the|this)\s+(?:document|doc|page)\s*(?:$|,|\band\b|\bthen\b)"#)
            || has(#"^start\s+(?:over|again|from\s+scratch)\s*(?:$|,|\band\b|\bthen\b)"#)
        if clearAll, !has(#"\b(?:except|apart\s+from|other\s+than|besides|save\s+for)\b|\b(?:everything|all)\s+but\b|\bselect(?:ed|ion)\b"#) {
            if let text = literal(after: #"(?:,|\band\b|\bthen\b)\s*"# + writeMarkers + #"(?:\s+(?:only|just))?"#) {
                guard verbatim(text) else { return nil }
                return DocumentEditPlan(operations: [.replaceAll([.init(text, .testo)])], summary: "I deleted everything and wrote “\(text)”.")
            }
            return DocumentEditPlan(operations: [.replaceAll([])], summary: "I cleared the document.")
        }
        // "Replace everything with X", "write only X".
        if let match = Calculations.matches(#"^(?:replace|substitute)\s+(?:everything|it\s+all|all(?:\s+(?:of\s+)?the\s+(?:text|content))?|the\s+(?:whole|entire)\s+(?:text|document|content))\s+with\s+(.+)$"#, in: prompt).first
            ?? Calculations.matches(#"^(?:write|put|type)\s+(?:only|just)\s+(.+)$"#, in: prompt).first {
            let text = unquoted(match[1])
            // "Write only the title…": una parte del documento, non il testo nuovo.
            guard !text.isEmpty, quote != nil || text.lowercased().range(of: #"^(?:the|this|these|those|my|our|a|an)\s"#, options: .regularExpression) == nil else { return nil }
            return DocumentEditPlan(operations: [.replaceAll([.init(text, .testo)])], summary: "I replaced everything with “\(text)”.")
        }

        // 3. Titolo nuovo ("change the title to “Plan 2027”", "call it Hello"). Il titolo di una sezione o un formato ("to bold") no.
        if let match = Calculations.matches(#"^(?:change|edit|modify|set|rename|update|replace|alter)\s+(?:the\s+)?(?:document(?:'s)?\s+|main\s+)?title(?:\s+of\s+(?:the|this)\s+(?:document|doc|file))?\s*(?:to|into|as|with|:)?\s+(.+)$"#, in: prompt).first
            ?? Calculations.matches(#"^(?:title|retitle|call|name|rename)\s+(?:it|this|the\s+(?:document|doc)|this\s+(?:document|doc))\s*(?:to|as|:)?\s+(.+)$"#, in: prompt).first
            ?? Calculations.matches(#"^(?:use|put|set)\s+(.+?)\s+as\s+(?:the\s+)?title$"#, in: prompt).first,
           case let title = unquoted(match[1]), !title.isEmpty,
           title.lowercased().range(of: #"^(?:of|for|in|on|at|from)\s"#, options: .regularExpression) == nil,
           title.lowercased().range(of: #"^(?:in\s+|to\s+)?(?:bold|italics?|underlined?|bigger|smaller|larger|centered|centred|uppercase|lowercase|capitals|(?:a\s+)?heading)$"#, options: .regularExpression) == nil {
            if let index = outline.titleIndex {
                return DocumentEditPlan(operations: [.replace(index, title)], summary: "I changed the title to “\(title)”.")
            }
            return DocumentEditPlan(operations: [.insert(after: -1, [.init(title, .titolo)])], summary: "I added the title “\(title)”.")
        }

        // 4. Via titolo o sottotitolo.
        if let match = Calculations.matches("^" + delete + #"\s+(?:the\s+)?(?:document(?:'s)?\s+)?(subtitle|title)$"#, in: prompt).first {
            let style: DocumentOutline.Style = match[1].lowercased() == "title" ? .titolo : .sottotitolo
            let indices = outline.paragraphs.indices.filter { outline.paragraphs[$0].style == style }
            guard !indices.isEmpty else { return nil }
            return DocumentEditPlan(operations: [.delete(indices)], summary: style == .titolo ? "I removed the title." : "I removed the subtitle.")
        }

        // 5. Via una sezione intera ("delete the Risks section", "remove the section about risks").
        if let match = Calculations.matches("^" + delete + #"\s+(?:the\s+)?(?:whole\s+|entire\s+)?(?:section|part|chapter)\s+(?:(?:on|about|regarding|called|titled|entitled|named|of)\s+)?(?:the\s+)?(.+)$"#, in: prompt).first
            ?? Calculations.matches("^" + delete + #"\s+(?:the\s+)?(?:whole\s+|entire\s+)?(.+?)\s+(?:section|part|chapter)$"#, in: prompt).first,
           let heading = outline.heading(matching: unquoted(match[1])) {
            let end = outline.sectionEnd(after: heading)
            return DocumentEditPlan(operations: [.delete(Array(heading..<end))],
                                    summary: "I deleted the section “\(outline.paragraphs[heading].text)” (\(paragraphCount(end - heading))).")
        }

        // 6. Via un paragrafo per posizione ("delete the second paragraph", "remove the last paragraph", "delete paragraph 3").
        let ordinals = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10]
        if let match = Calculations.matches("^" + delete + #"\s+(?:the\s+)?(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|last|second[\s-]to[\s-]last|next[\s-]to[\s-]last|penultimate|\d+(?:st|nd|rd|th)?)\s+paragraph$"#, in: prompt).first
            ?? Calculations.matches("^" + delete + #"\s+(?:the\s+)?paragraph\s+(?:number\s+|no\.?\s*)?(\d+)$"#, in: prompt).first {
            let body = outline.bodyIndices
            let word = match[1].lowercased()
            let position: Int? = word == "last" ? body.count
                : word.hasSuffix("last") || word == "penultimate" ? body.count - 1
                : ordinals[word] ?? Int(word.filter(\.isNumber))
            guard let position, position >= 1, position <= body.count else { return nil }
            return DocumentEditPlan(operations: [.delete([body[position - 1]])], summary: "I deleted paragraph \(position).")
        }

        // 7. Selezione dell'editor: cancellare o formattare "this".
        let selectionWords = #"(?:this|this\s+(?:part|bit|piece|text|sentence|passage)|the\s+selection|the\s+selected\s+(?:text|part)|the\s+highlighted\s+text|selected\s+text|what\s+i(?:'ve|\s+have)?\s+selected|what's\s+selected|what\s+is\s+selected)"#
        if outline.selectedText?.isEmpty == false, has("^" + delete + #"\s+"# + selectionWords + "$") {
            return DocumentEditPlan(operations: [.deleteSelection], summary: "I deleted the selected text.")
        }

        // 8. Formattazione di titoli, intestazioni, tutto o selezione ("make the section titles bold", "bold the headings").
        let styled: (word: String, target: String)? = {
            if let m = Calculations.matches(#"^(?:make|set|put|format|turn|mark)\s+(.+?)\s+(?:in\s+|as\s+|to\s+|into\s+)?(bold|italics?|underlined)$"#, in: prompt).first { return (m[2], m[1]) }
            if let m = Calculations.matches(#"^(bold|embolden|italici[sz]e|underline|highlight)\s+(.+)$"#, in: prompt).first { return (m[1], m[2]) }
            if let m = Calculations.matches(#"^(?:put|set|make|format)\s+(?:in\s+|as\s+)?(bold|italics?)\s+(.+)$"#, in: prompt).first { return (m[1], m[2]) }
            return nil
        }()
        if let styled {
            let word = styled.word.lowercased()
            let format: TextFormat = word.hasPrefix("bold") || word == "embolden" ? .grassetto : word.hasPrefix("ital") ? .corsivo : .sottolineato
            let target = styled.target.lowercased()
            if target.range(of: #"^(?:the\s+|all\s+(?:of\s+)?(?:the\s+)?)?(?:section\s+|chapter\s+)?(?:titles|headings|headers|subheadings|subtitles)\b"#, options: .regularExpression) != nil {
                let indices = outline.headingIndices
                guard !indices.isEmpty else { return nil }
                return DocumentEditPlan(operations: [.format(indices, format)],
                                        summary: englishFormatSummary(format, indices.count == 1 ? "the heading" : "\(indices.count) headings"))
            }
            if target.range(of: #"^(?:the\s+)?(?:document(?:'s)?\s+|main\s+)?title(?:\s+of\s+the\s+document)?$"#, options: .regularExpression) != nil, let index = outline.titleIndex {
                return DocumentEditPlan(operations: [.format([index], format)], summary: englishFormatSummary(format, "the title"))
            }
            if target.range(of: #"^(?:everything|all|all\s+(?:of\s+)?the\s+text|all\s+text|the\s+(?:whole|entire)\s+(?:text|document)|the\s+document|the\s+text)$"#, options: .regularExpression) != nil {
                return DocumentEditPlan(operations: [.format(Array(outline.paragraphs.indices), format)], summary: englishFormatSummary(format, "all the text"))
            }
            if target.range(of: "^" + selectionWords, options: .regularExpression) != nil, outline.selectedText?.isEmpty == false {
                return DocumentEditPlan(operations: [.formatSelection(format)], summary: englishFormatSummary(format, "the selected text"))
            }
        }

        // 9. Scrivere un testo così com'è ("write hello world", "add “Thanks everyone” at the beginning").
        let places = #"(at\s+the\s+end|at\s+the\s+bottom|to\s+the\s+end|to\s+the\s+bottom|at\s+the\s+beginning|at\s+the\s+start|at\s+the\s+top|to\s+the\s+top|to\s+the\s+beginning|after\s+the\s+title|below\s+the\s+title|under\s+the\s+title|underneath\s+the\s+title)"#
        if let match = Calculations.matches(#"^(?:write|type|add|insert|put|append)\s+(?:"# + places + #"\s+)?:?\s*(.+?)(?:\s+"# + places + #")?$"#, in: prompt).first {
            var text = unquoted(match[2])
            let place = (match[1].isEmpty ? match[3] : match[1]).lowercased()
            // "Add a section about…", "write a paragraph on risks": contenuto da scrivere, non testo da copiare.
            let generative = #"^(?:a|an|one|some|any|the|two|three|four|five|several|few|more|another|other|this|these|those|my|our|new)\s+"#
            let composing = text.lowercased().range(of: generative, options: .regularExpression) != nil && quote == nil
            // "Add Marketing to the title": la destinazione è una parte del documento, la sceglie il modello.
            let elsewhere = quote == nil && text.lowercased().range(of: #"\b(?:to|in|into|after|before|below|above|under|between)\s+(?:the|this|that|each|every|all|my)\b"#, options: .regularExpression) != nil
            guard !composing, !elsewhere, !text.isEmpty, quote != nil || text.split(separator: " ").count <= 15 else { return nil }
            if let quote { text = quote }
            let paragraph = DocumentOutline.Paragraph(text, .testo)
            if place.range(of: #"beginning|start|top|title"#, options: .regularExpression) != nil {
                let after = outline.paragraphs.lastIndex { $0.style.isTitle } ?? -1
                return DocumentEditPlan(operations: [.insert(after: after, [paragraph])], summary: "I wrote “\(text)” at the beginning.")
            }
            return DocumentEditPlan(operations: [.insert(after: outline.paragraphs.count - 1, [paragraph])], summary: "I wrote “\(text)” at the end.")
        }
        return nil
    }
}

// MARK: - Modifiche con il modello

extension Assistant {
    private static let documentEditSchema = makeSchema("ModificheDocumento", [
        .required("operazioni", .array(.object("Operazione", [
            .required("tipo", .choice(["sostituisci", "inserisci_dopo", "elimina", "stile", "formato"]),
                      "sostituisci il testo di un paragrafo; inserisci_dopo un paragrafo nuovo; elimina un paragrafo; stile per cambiarne il tipo; formato per grassetto, corsivo, sottolineato"),
            .required("paragrafo", .int, "Numero del paragrafo [P…] su cui agire; 0 per inserire all'inizio"),
            .optional("testo", .string, "Testo nuovo completo, per sostituisci e inserisci_dopo"),
            .optional("stile", .choice(["titolo", "sottotitolo", "intestazione", "testo"]), "Stile del paragrafo nuovo o modificato"),
            .optional("formato", .choice(["grassetto", "corsivo", "sottolineato", "normale"]), "Formato da applicare"),
        ]), min: 1, max: 12), "Operazioni da applicare, solo sui paragrafi da cambiare"),
    ])

    /// Lo stesso schema per le richieste in inglese: il codice accetta i valori in tutte e due le lingue.
    static let englishDocumentEditSchema = makeSchema("DocumentEdits", [
        .required("operations", .array(.object("Operation", [
            .required("type", .choice(["replace", "insert_after", "delete", "style", "format"]),
                      "replace the text of a paragraph; insert_after a new paragraph; delete a paragraph; style to change its type; format for bold, italic, underline"),
            .required("paragraph", .int, "Number of the [P…] paragraph to act on; 0 to insert at the beginning"),
            .optional("text", .string, "Complete new text, for replace and insert_after"),
            .optional("style", .choice(["title", "subtitle", "heading", "body"]), "Style of the new or changed paragraph"),
            .optional("format", .choice(["bold", "italic", "underline", "normal"]), "Format to apply"),
        ]), min: 1, max: 12), "Operations to apply, only on the paragraphs to change"),
    ])

    private static let paragraphSchema = makeSchema("Paragrafo", [.required("testo", .string, "Il testo risultante, completo")])
    static let englishParagraphSchema = makeSchema("Paragraph", [.required("text", .string, "The resulting text, complete")])

    /// Tipo di operazione scelto dal modello, anche in inglese ("replace" → "sostituisci").
    static func documentOperationKind(_ kind: String) -> String {
        ["replace": "sostituisci", "insert_after": "inserisci_dopo", "delete": "elimina", "style": "stile", "format": "formato"][kind.lowercased()] ?? kind
    }

    /// Lingua in cui è scritto un testo, per le istruzioni in inglese ("Italian", "English"…); nei testi brevi o incerti l'inglese.
    static func languageName(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        guard text.split(separator: " ").count >= 3, let best = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              best.value >= 0.6 else { return "English" }
        return Locale(identifier: "en").localizedString(forLanguageCode: best.key.rawValue) ?? "English"
    }

    /// Modifica del documento aperto: prima i comandi riconosciuti con regole, poi le trasformazioni di tutto il testo
    /// (paragrafo per paragrafo, niente viene tagliato), infine le operazioni mirate scelte dal modello sui paragrafi numerati.
    public func planDocumentEdit(_ instruction: String, outline: DocumentOutline,
                                 status: @escaping @MainActor (String) -> Void = { _ in }) async throws -> DocumentEditPlan {
        if let quick = Self.quickDocumentEdit(instruction, outline: outline) {
            Agent.log("MODIFICA DOCUMENTO (regole): \(quick.summary)")
            return quick
        }
        let lower = instruction.lowercased()
        let english = Language.isEnglish
        // Selezione nell'editor: "traduci questo", "riscrivi questa parte", "rendi più formale la selezione" ("translate this").
        if let selected = outline.selectedText, !selected.isEmpty,
           [" questo", " questa", "la selezione", "selezionat", "questa parte", "questo pezzo"].contains(where: (" " + lower).contains)
            || english && lower.range(of: #"\b(?:this(?!\s+(?:document|doc|text|file|page|whole))|the\s+selection|selected|highlighted)\b"#, options: .regularExpression) != nil {
            status(Language.t("Riscrivo il testo selezionato…", "Rewriting the selected text…"))
            let text = try await rewriteParagraph(selected, instruction: instruction)
            return DocumentEditPlan(operations: [.replaceSelection(text)], summary: Language.t("Ho modificato il testo selezionato.", "I edited the selected text."))
        }
        // Trasformazioni di tutto il documento: un paragrafo alla volta, così anche i documenti lunghi restano interi.
        if let targets = Self.globalTargets(lower, outline: outline) {
            var operations: [DocumentOperation] = []
            // Refusi: sempre parola per parola con il correttore (sicuro); il resto, con il modello scelto, in una sola richiesta.
            let spellingOnly = (lower.contains("corregg") || lower.contains("refus") || lower.contains("errori")) && !lower.contains("grammatic")
                || english && Self.englishSpellingFix(lower)
            if !spellingOnly, let rewritten = await rewriteInBatch(targets, outline: outline, instruction: instruction, status: status) {
                for index in targets {
                    guard let text = rewritten[index] else { continue }
                    let original = outline.paragraphs[index].text
                    if text != original, Self.plausibleRewrite(original, text, instruction: lower) { operations.append(.replace(index, text)) }
                }
                return DocumentEditPlan(operations: operations, summary: Self.rewriteSummary(operations.count, of: targets.count))
            }
            for (position, index) in targets.enumerated() {
                try Task.checkCancellation()
                status(Language.t("Modifico il paragrafo \(position + 1) di \(targets.count)…", "Editing paragraph \(position + 1) of \(targets.count)…"))
                let original = outline.paragraphs[index].text
                let text = try await rewriteParagraph(original, instruction: instruction)
                if text != original, Self.plausibleRewrite(original, text, instruction: lower) { operations.append(.replace(index, text)) }
            }
            return DocumentEditPlan(operations: operations, summary: Self.rewriteSummary(operations.count, of: targets.count))
        }
        // Operazioni mirate scelte dal modello sui paragrafi numerati.
        status(Language.t("Scelgo cosa cambiare nel documento…", "Choosing what to change in the document…"))
        let (numbered, truncated) = outline.numbered(characters: budget.scaled(2600))
        // In inglese si scrive nella lingua del documento (un documento italiano resta italiano).
        let session = LanguageModelSession(model: Agent.model, instructions: english ? """
        You edit a document open in the editor. You receive the numbered paragraphs [P1], [P2]… with their style and a request.
        Return only the necessary operations, on the paragraphs to change: the rest of the document stays as it is.
        - To change a paragraph use replace with the complete new text.
        - To add a section use insert_after: a paragraph with style heading, then one or more paragraphs with style body.
        - To remove a section delete its heading and its paragraphs.
        - “This” or “here” mean the paragraphs marked [selected] or [cursor].
        Write in \(Self.languageName(of: outline.plainText)), unless the request asks for another language.
        """ : """
        Modifichi un documento aperto nell'editor. Ricevi i paragrafi numerati [P1], [P2]… con il loro stile e una richiesta.
        Restituisci solo le operazioni necessarie, sui paragrafi da cambiare: tutto il resto del documento resta com'è.
        - Per cambiare un paragrafo usa sostituisci con il testo nuovo completo.
        - Per aggiungere una sezione usa inserisci_dopo: un paragrafo con stile intestazione e poi uno o più paragrafi con stile testo.
        - Per togliere una sezione elimina la sua intestazione e i suoi paragrafi.
        - «Questo» o «qui» indicano i paragrafi segnati [selezionato] o [cursore].
        Scrivi in italiano, salvo che la richiesta chieda un'altra lingua.
        """)
        let request = Language.t("Documento:\n\(numbered)\n\nRichiesta: \(instruction)", "Document:\n\(numbered)\n\nRequest: \(instruction)")
        let content = try await session.respond(to: request, schema: english ? Self.englishDocumentEditSchema : Self.documentEditSchema,
                                                options: GenerationOptions(temperature: 0.2)).content
        var operations: [DocumentOperation] = []
        var inserts: [Int: [DocumentOutline.Paragraph]] = [:]
        var insertOrder: [Int] = []
        var rewritten = Set<Int>()
        // Trasformazioni ("traduci", "rendi più formale"): il modello indica dove, il testo lo riscrive il codice paragrafo per paragrafo.
        let transforming = ["traduci", "riscrivi", "rendi", "correggi", "accorcia", "abbrevia", "allunga", "espandi", "semplifica", "migliora",
                            "trasforma", "riassumi"].contains(where: lower.hasPrefix)
            || english && lower.range(of: Self.englishRewriteVerbs + #"|^summari[sz]e\b"#, options: .regularExpression) != nil
        let aboutHeadings = ["titolo", "intestazion", "nome della sezione"].contains(where: lower.contains)
            || english && lower.range(of: #"\b(?:titles?|headings?|headers?|section\s+names?)\b"#, options: .regularExpression) != nil
        // Posizione scritta nella richiesta ("dopo gli obiettivi", "prima delle conclusioni"): vale più di quella scelta dal modello.
        let anchorFromText = Self.insertionAnchor(lower, outline: outline)
        // Campi e valori dello schema in italiano o in inglese.
        for item in content.objects("operazioni") + content.objects("operations") {
            guard let kind = (item.string("tipo") ?? item.string("type")).map(Self.documentOperationKind),
                  let number = item.int("paragrafo") ?? item.int("paragraph") else { continue }
            let index = number - 1
            let style = (item.string("stile") ?? item.string("style")).flatMap(DocumentOutline.Style.init(modelName:))
            let newText = item.string("testo") ?? item.string("text")
            switch kind {
            case "sostituisci":
                guard outline.paragraphs.indices.contains(index) else { continue }
                // Un'intestazione indicata per una trasformazione del testo vuol dire il testo della sua sezione.
                let targets = transforming && outline.paragraphs[index].style.isHeading && !aboutHeadings
                    ? Array((index + 1)..<outline.sectionEnd(after: index)) : [index]
                for target in targets where !rewritten.contains(target) {
                    rewritten.insert(target)
                    // Con il modello scelto il testo nuovo lo scrive lui (qui Apple Intelligence ha scelto solo dove).
                    var text = transforming || targets != [index] || textWriter != nil ? "" : (newText ?? "")
                    // Paragrafo accorciato nel prompt, testo mancante o trasformazione: si riscrive per intero, niente va perso.
                    if text.isEmpty || truncated.contains(target) {
                        status(Language.t("Riscrivo il paragrafo \(target + 1)…", "Rewriting paragraph \(target + 1)…"))
                        text = try await rewriteParagraph(outline.paragraphs[target].text, instruction: instruction)
                    }
                    let parts = Self.paragraphs(from: text, style: outline.paragraphs[target].style)
                    guard let first = parts.first else { continue }
                    operations.append(.replace(target, first.text))
                    if parts.count > 1 { operations.append(.insert(after: target, Array(parts.dropFirst()))) }
                    if targets == [index], let style, style != outline.paragraphs[target].style { operations.append(.restyle([target], style)) }
                }
            case "inserisci_dopo":
                guard var text = newText, index >= -1, index < outline.paragraphs.count else { continue }
                // Con il modello scelto la parte nuova la scrive lui; Apple Intelligence ha deciso dove metterla.
                if textWriter != nil {
                    status(Language.t("\(textWriterName ?? "Il modello") scrive la parte nuova…", "\(textWriterName ?? "The model") is writing the new part…"))
                    let apple = text
                    let role = english
                        ? "Write the text to insert into an open document, consistent with the rest and in the same tone and language (\(Self.languageName(of: outline.plainText)), unless the request asks for another language). Return only the new text in Markdown: “## Title” for the title of a new section, then the paragraphs; no comments."
                        : "Scrivi il testo da inserire in un documento aperto, coerente con il resto e con lo stesso tono. Restituisci solo il testo nuovo in Markdown: «## Titolo» per il titolo di una sezione nuova, poi i paragrafi; niente commenti."
                    text = (try? await compose(role, request) { apple }) ?? apple
                }
                // Dopo un'intestazione si intende dopo la sua sezione; senza una posizione nella richiesta si aggiunge in fondo
                // (il modello tende a mettere tutto all'inizio).
                var anchor = anchorFromText ?? index
                if anchorFromText == nil, outline.paragraphs.indices.contains(index), outline.paragraphs[index].style.isHeading {
                    anchor = outline.sectionEnd(after: index) - 1
                }
                if anchorFromText == nil, index == -1, lower.range(of: #"\b(inizio|cima|prima|sopra|apertura)\b"#, options: .regularExpression) == nil,
                   !english || lower.range(of: #"\b(?:beginning|start|top|before|above|opening)\b"#, options: .regularExpression) == nil {
                    anchor = outline.paragraphs.count - 1
                }
                if inserts[anchor] == nil { insertOrder.append(anchor) }
                // Il modello a volte scrive Markdown ("### Titolo", righe con a capo): diventano paragrafi con il loro stile.
                // Se il documento non ha sotto-sezioni, le intestazioni nuove stanno al livello delle altre sezioni.
                let flat = !outline.paragraphs.contains { $0.style == .sottointestazione }
                inserts[anchor, default: []] += Self.paragraphs(from: text, style: style ?? .testo).map { paragraph in
                    var copy = paragraph
                    if flat, copy.style == .sottointestazione { copy.style = .intestazione }
                    // Una frase lunga o chiusa dal punto non è un'intestazione, anche se il modello la segna così.
                    if copy.style.isHeading || copy.style.isTitle, copy.text.count > 80 || copy.text.hasSuffix(".") { copy.style = .testo }
                    return copy
                }
            case "elimina":
                guard outline.paragraphs.indices.contains(index) else { continue }
                // Eliminare un'intestazione vuol dire eliminare la sua sezione.
                let end = outline.paragraphs[index].style.isHeading ? outline.sectionEnd(after: index) : index + 1
                operations.append(.delete(Array(index..<end)))
            case "stile":
                guard outline.paragraphs.indices.contains(index), let style else { continue }
                operations.append(.restyle([index], style))
            case "formato":
                guard outline.paragraphs.indices.contains(index) else { continue }
                operations.append(.format([index], (item.string("formato") ?? item.string("format")).flatMap(TextFormat.init(modelName:)) ?? .grassetto))
            default: continue
            }
        }
        operations += insertOrder.map { .insert(after: $0, inserts[$0] ?? []) }
        guard !operations.isEmpty else {
            return DocumentEditPlan(operations: [], summary: Language.t("Non ho capito cosa cambiare nel documento: prova a dirmi quale parte.",
                                                                        "I didn't understand what to change in the document: try telling me which part."))
        }
        return DocumentEditPlan(operations: operations, summary: Self.summarize(operations, outline: outline))
    }

    /// "Ho modificato 3 paragrafi su 5." / "I edited 3 of 5 paragraphs."
    static func rewriteSummary(_ changed: Int, of total: Int) -> String {
        changed == 0 ? Language.t("Non ho trovato niente da cambiare.", "I didn't find anything to change.")
            : Language.t("Ho modificato \(changed) paragrafi su \(total).", "I edited \(changed) of \(total) paragraphs.")
    }

    /// Verbi inglesi delle trasformazioni del testo ("translate…", "make it more formal", "fix the typos").
    static let englishRewriteVerbs = #"^(?:translate|fix|correct|rewrite|rephrase|reword|paraphrase|simplify|improve|shorten|abbreviate|lengthen|"#
        + #"formali[sz]e|review|revise|proofread|polish|expand|condense|transform|turn(?!\s+(?:on|off|up|down)\b)|"#
        + #"make(?!\s+(?:a|an|me|us|new|another|some|sure)\b))\b"#

    /// Richiesta inglese di correggere i refusi ("fix the typos", "correct the mistakes"): con "grammar", "tone", "style"…
    /// si riscrive con il modello.
    static func englishSpellingFix(_ lower: String) -> Bool {
        lower.range(of: #"^(?:fix|correct|proofread)\b|\b(?:typos?|mistakes?|errors?|spelling|misspell\w*)\b"#, options: .regularExpression) != nil
            && lower.range(of: #"\b(?:grammar|grammatical|syntax|punctuation|agreement|tone|style|wording|phrasing|format\w*|layout|structure|flow|logic|numbers?|dates?|figures?)\b"#,
                           options: .regularExpression) == nil
    }

    /// Riscrive un solo paragrafo secondo la richiesta (il paragrafo intero, mai un estratto).
    func rewriteParagraph(_ text: String, instruction: String) async throws -> String {
        let lower = instruction.lowercased()
        let english = Language.isEnglish
        let correcting = lower.contains("corregg") || lower.contains("errori") || lower.contains("refus") || lower.contains("ortografi")
            || english && lower.range(of: #"^(?:fix|correct|proofread)\b|\b(?:typos?|mistakes?|errors?|spelling|misspell\w*)\b"#, options: .regularExpression) != nil
        // In inglese "fix the grammar", "fix the tone", "correct the formatting" non sono solo refusi: riscrive il modello.
        let grammar = ["grammatic", "sintass", "punteggiatur", "concordanz", "stile", "forma "].contains(where: lower.contains)
            || english && !Self.englishSpellingFix(lower)
        let flagged = correcting ? Self.spellingSuggestions(text) : []
        // Refusi: il modello sceglie solo fra i suggerimenti del correttore del Mac, il resto del paragrafo resta identico
        // (niente parole aggiunte o cambiate per sbaglio).
        if correcting, !grammar, !flagged.isEmpty {
            return await correctSpelling(text, flagged: flagged)
        }
        // In inglese il paragrafo resta nella sua lingua, salvo che la richiesta ne chieda un'altra ("translate… into Italian").
        let role = english ? """
        You apply an edit request to a single paragraph of a document. Return only the resulting paragraph, complete, \
        without comments. Change only what the request asks. Write in \(Self.languageName(of: text)), unless the request asks for another language.
        """ : """
        Applichi una richiesta di modifica a un solo paragrafo di un documento. Restituisci solo il paragrafo risultante, completo, \
        senza commenti. Cambia soltanto ciò che la richiesta chiede. Scrivi in italiano, salvo che la richiesta chieda un'altra lingua.
        """
        // Correzioni: le parole che il correttore del Mac non riconosce, con i suoi suggerimenti (il modello sceglie quello giusto nel contesto).
        let hints = flagged.isEmpty ? "" : Language.t("\n\nParole probabilmente sbagliate: ", "\n\nProbably misspelled words: ")
            + flagged.map { Language.t("«\($0.word)» (forse: \($0.guesses.joined(separator: ", ")))", "“\($0.word)” (maybe: \($0.guesses.joined(separator: ", ")))") }.joined(separator: "; ")
        let request = Language.t("Richiesta: \(instruction)\n\nParagrafo:\n\(text.prefix(3000))\(hints)", "Request: \(instruction)\n\nParagraph:\n\(text.prefix(3000))\(hints)")
        // Scrive il modello scelto; se non c'è o non risponde, Apple Intelligence.
        return try await compose(role, request) {
            let options = correcting ? GenerationOptions(samplingMode: .greedy) : GenerationOptions(temperature: 0.2)
            let content = try await LanguageModelSession(model: Agent.model, instructions: role)
                .respond(to: request, schema: english ? Self.englishParagraphSchema : Self.paragraphSchema, options: options).content
            return Self.unquoted(content.string("testo") ?? content.string("text") ?? text)
        }
    }

    /// Con il modello scelto (finestra grande): i paragrafi da trasformare in una sola richiesta, a blocchi, invece che uno per volta.
    /// nil se non c'è un modello scelto o la risposta non è valida: allora si procede paragrafo per paragrafo.
    func rewriteInBatch(_ targets: [Int], outline: DocumentOutline, instruction: String,
                        status: @escaping @MainActor (String) -> Void) async -> [Int: String]? {
        guard textWriter != nil else { return nil }
        var chunks: [[Int]] = [[]]
        var size = 0
        for index in targets {
            let length = outline.paragraphs[index].text.count
            if size + length > 6000, !(chunks.last ?? []).isEmpty { chunks.append([]); size = 0 }
            chunks[chunks.count - 1].append(index)
            size += length
        }
        let english = Language.isEnglish
        let writer = textWriterName ?? Language.t("Il modello", "The model")
        var result: [Int: String] = [:]
        for (number, chunk) in chunks.enumerated() {
            status(chunks.count == 1 ? Language.t("\(writer) riscrive il documento…", "\(writer) is rewriting the document…")
                : Language.t("\(writer) riscrive il documento (\(number + 1) di \(chunks.count))…", "\(writer) is rewriting the document (\(number + 1) of \(chunks.count))…"))
            let paragraphs = chunk.map { "[P\($0 + 1)] \(outline.paragraphs[$0].text)" }.joined(separator: "\n\n")
            let role = english
                ? "You apply an edit request to the paragraphs of a document: change only what the request asks and add no comments. Write in \(Self.languageName(of: outline.plainText)), unless the request asks for another language."
                : "Applichi una richiesta di modifica ai paragrafi di un documento: cambi soltanto ciò che la richiesta chiede e non aggiungi commenti. Scrivi in italiano, salvo che la richiesta chieda un'altra lingua."
            let request = english ? "Request: \(instruction)\n\nParagraphs:\n\(paragraphs)" : "Richiesta: \(instruction)\n\nParagrafi:\n\(paragraphs)"
            let fields = english
                ? "\"paragraphs\": list of objects {\"n\": paragraph number without the P, \"text\": complete edited paragraph}; omit the ones that don't change"
                : "\"paragrafi\": elenco di oggetti {\"n\": numero del paragrafo senza la P, \"testo\": paragrafo modificato completo}; ometti quelli che non cambiano"
            guard let json = await composeJSON(role, request, fields: fields) else { return nil }
            for item in json.objects("paragrafi") + json.objects("paragraphs") {
                guard let number = (item["n"] as? NSNumber)?.intValue ?? item.text("n").flatMap({ Int($0.replacingOccurrences(of: "P", with: "")) }),
                      chunk.contains(number - 1), let text = item.text("testo") ?? item.text("text") else { continue }
                result[number - 1] = Self.unquoted(text.replacingOccurrences(of: #"^\[P\d+\]\s*"#, with: "", options: .regularExpression))
            }
        }
        return result
    }

    /// Correzione dei refusi senza riscrivere: per ogni parola sconosciuta si sceglie un suggerimento (o si lascia com'è) e si sostituisce solo quella.
    func correctSpelling(_ text: String, flagged: [(word: String, range: NSRange, guesses: [String])]) async -> String {
        let ns = text as NSString
        let items = flagged.filter { !$0.guesses.isEmpty }
        guard !items.isEmpty else { return text }
        let key = Language.t("parola", "word")
        let fields: [Field] = items.enumerated().map { index, item in
            let from = max(0, item.range.location - 45), to = min(ns.length, NSMaxRange(item.range) + 45)
            let context = ns.substring(with: NSRange(location: from, length: to - from)).replacingOccurrences(of: "\n", with: " ")
            var choices = [item.word]
            for guess in item.guesses where !choices.contains(guess) { choices.append(guess) }
            return .required("\(key)\(index + 1)", .choice(choices),
                             Language.t("Forma giusta di «\(item.word)» in: «…\(context)…»", "Correct form of “\(item.word)” in: “…\(context)…”"))
        }
        let session = LanguageModelSession(model: Agent.model, instructions: Language.t("""
        Per ogni parola scegli la forma corretta nel contesto della frase. Se la parola è già giusta (un nome, una sigla, una parola straniera), lasciala com'è.
        """, """
        For each word choose the correct form in the context of the sentence. If the word is already right (a name, an acronym, a foreign word), leave it as it is.
        """))
        guard let content = try? await session.respond(to: Language.t("Testo: ", "Text: ") + text.prefix(1500),
                                                        schema: makeSchema(Language.t("Correzioni", "Corrections"), fields),
                                                        options: GenerationOptions(samplingMode: .greedy)).content else { return text }
        let result = NSMutableString(string: text)
        for (index, item) in items.enumerated().reversed() {
            guard var choice = content.string("\(key)\(index + 1)"), choice != item.word else { continue }
            // Stessa maiuscola iniziale della parola originale.
            if item.word.first?.isUppercase == true { choice = choice.prefix(1).uppercased() + choice.dropFirst() }
            result.replaceCharacters(in: item.range, with: choice)
        }
        return result as String
    }

    /// Lingua del correttore per un testo: quella in cui è scritto (un documento inglese si corregge in inglese anche con
    /// una richiesta in italiano, e viceversa); nei testi brevi o incerti quella della richiesta.
    static func spellingLanguage(for text: String) -> String {
        let fallback = Language.isEnglish ? "en" : "it"
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        guard text.split(separator: " ").count >= 4, let best = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              best.value >= 0.8 else { return fallback }
        let code = best.key.rawValue
        return spellLock.withLock { NSSpellChecker.shared.availableLanguages.contains(code) } ? code : fallback
    }

    /// Il correttore del Mac è uno solo e non regge chiamate contemporanee (risposte, sub-agent e test in parallelo).
    private static let spellLock = NSLock()

    /// Parole sconosciute al correttore del Mac (nella lingua del testo), con la posizione e i suoi suggerimenti.
    static func spellingSuggestions(_ text: String, limit: Int = 6) -> [(word: String, range: NSRange, guesses: [String])] {
        let language = spellingLanguage(for: text)
        spellLock.lock(); defer { spellLock.unlock() }
        let checker = NSSpellChecker.shared
        let ns = text as NSString
        var results: [(String, NSRange, [String])] = []
        var start = 0
        while start < ns.length, results.count < limit {
            let range = checker.checkSpelling(of: text, startingAt: start, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0 else { break }
            let word = ns.substring(with: range)
            let guesses = checker.guesses(forWordRange: range, in: text, language: language, inSpellDocumentWithTag: 0) ?? []
            results.append((word, range, Array(guesses.prefix(3))))
            start = NSMaxRange(range)
        }
        return results
    }

    /// Testo scritto dal modello in paragrafi: righe separate, "#"/"##" intestazioni, "###" sotto-intestazioni, elenchi con •.
    static func paragraphs(from text: String, style: DocumentOutline.Style) -> [DocumentOutline.Paragraph] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { line in
            var clean = line.replacingOccurrences(of: "**", with: "")
            if let marks = clean.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let level = clean[marks].filter { $0 == "#" }.count
                clean.removeSubrange(marks)
                return DocumentOutline.Paragraph(clean, level >= 3 ? .sottointestazione : .intestazione)
            }
            if let bullet = clean.range(of: #"^[-*•]\s+"#, options: .regularExpression) { clean.replaceSubrange(bullet, with: "• ") }
            return DocumentOutline.Paragraph(clean, style)
        }
    }

    /// "Dopo gli obiettivi", "prima delle conclusioni", "in fondo", "all'inizio": dove inserire, se la richiesta lo dice.
    static func insertionAnchor(_ lower: String, outline: DocumentOutline) -> Int? {
        // In inglese: "after the goals", "before the conclusions", "at the end", "at the beginning".
        if Language.isEnglish {
            if lower.range(of: #"\b(?:at|to)\s+the\s+(?:end|bottom)\b"#, options: .regularExpression) != nil { return outline.paragraphs.count - 1 }
            if lower.range(of: #"\b(?:at|to)\s+the\s+(?:beginning|start|top)\b"#, options: .regularExpression) != nil { return outline.paragraphs.lastIndex { $0.style.isTitle } ?? -1 }
            let section = #"(?:the\s+)?(?:(?:section|part|paragraph|chapter)\s+)?(?:(?:on|about|called|titled|named)\s+)?(?:the\s+)?(.+)$"#
            if let match = Calculations.matches(#"\bafter\s+"# + section, in: lower).first, let heading = outline.heading(matching: match[1]) {
                return outline.sectionEnd(after: heading) - 1
            }
            if let match = Calculations.matches(#"\bbefore\s+"# + section, in: lower).first, let heading = outline.heading(matching: match[1]) {
                return heading - 1
            }
        }
        if lower.range(of: #"\b(in fondo|alla fine)\b"#, options: .regularExpression) != nil { return outline.paragraphs.count - 1 }
        if lower.range(of: #"\b(all'inizio|in cima)\b"#, options: .regularExpression) != nil { return outline.paragraphs.lastIndex { $0.style.isTitle } ?? -1 }
        if let match = Calculations.matches(#"\bdopo\s+(?:la sezione\s+|il paragrafo\s+|la parte\s+)?(?:su\s+|sul\s+|sulla\s+|sui\s+|sugli\s+)?(?:gli\s+|le\s+|i\s+|il\s+|la\s+|l'|lo\s+)?(.+)$"#, in: lower).first,
           let heading = outline.heading(matching: match[1]) {
            return outline.sectionEnd(after: heading) - 1
        }
        if let match = Calculations.matches(#"\bprima\s+(?:della sezione\s+|del paragrafo\s+|di\s+|della\s+|delle\s+|dei\s+|degli\s+|del\s+|dello\s+)?(?:gli\s+|le\s+|i\s+|il\s+|la\s+|l'|lo\s+)?(.+)$"#, in: lower).first,
           let heading = outline.heading(matching: match[1]) {
            return heading - 1
        }
        return nil
    }

    /// Trasformazioni di tutto il testo ("traduci il documento in inglese", "correggi gli errori", "rendi tutto più formale"):
    /// paragrafi da riscrivere uno per uno. nil se la richiesta riguarda una parte precisa.
    static func globalTargets(_ lower: String, outline: DocumentOutline) -> [Int]? {
        // In inglese gli stessi controlli con le parole inglesi ("fix the typos", "make everything more formal").
        if Language.isEnglish, lower.range(of: englishRewriteVerbs, options: .regularExpression) != nil {
            let specific = #"\b(?:paragraphs?|sections?|titles?|headings?|introduction|intro|conclusions?|chapters?|sentences?|words?|first\s+part|second\s+part|"#
                + #"this|these|selection|selected|about|lines?|lists?|bullets?|points?)\b"#
            let global = #"\b(?:everything|all|whole|entire|throughout|the\s+document|the\s+text|this\s+(?:document|doc|text)|the\s+errors|the\s+mistakes|"#
                + #"the\s+typos|typos|spelling|grammar)\b"#
            func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
            guard !has(specific) || has(global) && !has(#"\b(?:paragraph|section)\b"#) else { return nil }
            return rewriteTargets(outline, translating: lower.hasPrefix("translate"),
                                  correcting: has(#"^(?:fix|correct|proofread)\b|\b(?:typos?|mistakes|errors|spelling|misspell\w*)\b"#))
        }
        let verbs = ["traduci", "correggi", "riscrivi", "rendi", "semplifica", "migliora", "accorcia", "abbrevia", "allunga", "formalizza", "rivedi",
                     "espandi", "trasforma"]
        guard verbs.contains(where: lower.hasPrefix) else { return nil }
        let specific = ["paragrafo", "sezione", "titolo", "introduzion", "conclusion", "capitolo", "frase", "parola", "prima parte", "seconda parte",
                        "questo", "questa", "selezion", "sul ", "sulla ", "sui ", "sugli ", "riga", "elenco", "punto"]
        let global = ["tutto", "tutti", "intero", "il documento", "il testo", "gli errori", "i refusi", "l'ortografia", "la grammatica"]
        guard !specific.contains(where: lower.contains) || global.contains(where: lower.contains) && !lower.contains("paragrafo") && !lower.contains("sezione") else { return nil }
        let translating = lower.hasPrefix("traduci")
        let correcting = lower.hasPrefix("correggi") || lower.contains("errori") || lower.contains("refusi")
        return rewriteTargets(outline, translating: translating, correcting: correcting)
    }

    /// Paragrafi da riscrivere: tutti per traduzioni e correzioni (anche i titoli), altrimenti il testo senza titoli e intestazioni.
    static func rewriteTargets(_ outline: DocumentOutline, translating: Bool, correcting: Bool) -> [Int]? {
        var targets = outline.paragraphs.indices.filter { index in
            let paragraph = outline.paragraphs[index]
            guard paragraph.text.trimmingCharacters(in: .whitespaces).count > 1 else { return false }
            return translating || correcting || (!paragraph.style.isHeading && !paragraph.style.isTitle)
        }
        // Correzioni: solo i paragrafi in cui il correttore del Mac trova errori (gli altri restano identici).
        if correcting {
            let flagged = targets.filter { hasSpellingErrors(outline.paragraphs[$0].text) }
            if !flagged.isEmpty { targets = flagged }
        }
        return targets.isEmpty ? nil : Array(targets.prefix(40))
    }

    /// Il correttore ortografico del Mac (nella lingua del testo) trova parole sbagliate?
    static func hasSpellingErrors(_ text: String) -> Bool {
        let language = spellingLanguage(for: text)
        return spellLock.withLock {
            NSSpellChecker.shared.checkSpelling(of: text, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound
        }
    }

    /// Scarta riscritture sospette (vuote o molto più corte senza che la richiesta chieda di accorciare).
    static func plausibleRewrite(_ original: String, _ text: String, instruction: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let shortening = ["accorcia", "abbrevia", "riassumi", "sintetizza", "semplifica"].contains(where: instruction.contains)
            || Language.isEnglish && instruction.range(of: #"\b(?:shorten|shorter|abbreviate|summari[sz]e|condense|simplify|trim|cut|concise|brief)"#, options: .regularExpression) != nil
        return shortening || text.count * 3 >= original.count
    }

    /// Frase per la chat con ciò che è cambiato.
    static func summarize(_ operations: [DocumentOperation], outline: DocumentOutline) -> String {
        var parts: [String] = []
        let replaced: [Int] = operations.compactMap { operation -> Int? in
            if case .replace(let index, _) = operation { return index }
            return nil
        }
        let deleted: [Int] = operations.flatMap { operation -> [Int] in
            if case .delete(let indices) = operation { return indices }
            return []
        }
        let insertedParagraphs: [DocumentOutline.Paragraph] = operations.flatMap { operation -> [DocumentOutline.Paragraph] in
            if case .insert(_, let items) = operation { return items }
            return []
        }
        let formatted: [Int] = operations.flatMap { operation -> [Int] in
            if case .format(let indices, _) = operation { return indices }
            return []
        }
        let restyled: [Int] = operations.flatMap { operation -> [Int] in
            if case .restyle(let indices, _) = operation { return indices }
            return []
        }
        if replaced.contains(where: { outline.paragraphs.indices.contains($0) && outline.paragraphs[$0].style == .titolo }) {
            parts.append(Language.t("cambiato il titolo", "changed the title"))
        }
        let body = replaced.filter { !(outline.paragraphs.indices.contains($0) && outline.paragraphs[$0].style == .titolo) }
        if !body.isEmpty {
            parts.append(body.count == 1 ? Language.t("riscritto il paragrafo \(body[0] + 1)", "rewrote paragraph \(body[0] + 1)")
                         : Language.t("riscritto \(body.count) paragrafi", "rewrote \(body.count) paragraphs"))
        }
        if let heading = insertedParagraphs.first(where: { $0.style.isHeading }) {
            parts.append(Language.t("aggiunto la sezione «\(heading.text)»", "added the section “\(heading.text)”"))
        } else if !insertedParagraphs.isEmpty {
            parts.append(insertedParagraphs.count == 1 ? Language.t("aggiunto un paragrafo", "added a paragraph")
                         : Language.t("aggiunto \(insertedParagraphs.count) paragrafi", "added \(insertedParagraphs.count) paragraphs"))
        }
        let headings = deleted.filter { outline.paragraphs.indices.contains($0) && outline.paragraphs[$0].style.isHeading }
        if !headings.isEmpty {
            parts.append(Language.t("eliminato la sezione " + headings.map { "«\(outline.paragraphs[$0].text)»" }.joined(separator: ", "),
                                    (headings.count == 1 ? "deleted the section " : "deleted the sections ") + headings.map { "“\(outline.paragraphs[$0].text)”" }.joined(separator: ", ")))
        } else if !deleted.isEmpty {
            parts.append(deleted.count == 1 ? Language.t("eliminato un paragrafo", "deleted a paragraph")
                         : Language.t("eliminato \(Set(deleted).count) paragrafi", "deleted \(Set(deleted).count) paragraphs"))
        }
        if !formatted.isEmpty { parts.append(Language.t("formattato \(Set(formatted).count) paragrafi", "formatted \(Set(formatted).count) paragraphs")) }
        if !restyled.isEmpty, replaced.isEmpty {
            parts.append(Language.t("cambiato lo stile di \(Set(restyled).count) paragrafi", "changed the style of \(Set(restyled).count) paragraphs"))
        }
        guard !parts.isEmpty else { return Language.t("Ho modificato il documento.", "I edited the document.") }
        return Language.t("Ho ", "I ") + joined(parts) + "."
    }

    /// "a, b e c" / "a, b and c".
    static func joined(_ parts: [String]) -> String {
        parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + Language.t(" e ", " and ") + parts.last!
    }
}
