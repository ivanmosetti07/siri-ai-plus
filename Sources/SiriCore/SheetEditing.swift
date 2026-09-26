import Foundation
import FoundationModels

// MARK: - Foglio aperto: righe, colonne, celle e grafici

/// Una modifica al foglio. Si applicano in ordine: ogni indice (da 0) vale per il foglio dopo le operazioni precedenti.
public enum SheetOperation: Sendable, Equatable {
    case set(CellRef, String)
    /// Riga nuova: valori per colonna (le formule di riga e i totali si aggiornano da soli).
    case insertRow(at: Int, values: [Int: String])
    case deleteRow(Int)
    case insertColumn(at: Int, header: String)
    case deleteColumn(Int)
    case addChart(ChartSpec.Kind, range: String)
}

public struct SheetEditPlan: Sendable, Equatable {
    public var operations: [SheetOperation]
    public var summary: String

    public init(operations: [SheetOperation], summary: String) { self.operations = operations; self.summary = summary }
}

extension Sheet {
    // MARK: Spostamenti con le formule aggiornate (usati anche dall'editor)

    /// Inserisce (delta > 0) o elimina (delta < 0) righe o colonne a partire da `from`, riscrivendo i riferimenti delle formule.
    public mutating func shift(rows fromRow: Int? = nil, cols fromCol: Int? = nil, by delta: Int) {
        var moved: [String: String] = [:]
        var movedFormats: [String: CellFormat] = [:]
        for (key, raw) in cells {
            guard let ref = CellRef(key) else { continue }
            if let fromRow, delta < 0, ref.row >= fromRow, ref.row < fromRow - delta { continue }
            if let fromCol, delta < 0, ref.col >= fromCol, ref.col < fromCol - delta { continue }
            let target = Self.moved(ref, fromRow: fromRow, fromCol: fromCol, delta: delta)
            moved[target.name] = raw.hasPrefix("=") ? Self.rewrite(raw, fromRow: fromRow, fromCol: fromCol, delta: delta) : raw
            if let format = formats[key] { movedFormats[target.name] = format }
        }
        cells = moved
        formats = movedFormats
        if fromRow != nil { rows = max(1, rows + delta) }
        if fromCol != nil { columns = max(1, columns + delta) }
        for index in charts.indices { charts[index].range = Self.rewrite(charts[index].range, fromRow: fromRow, fromCol: fromCol, delta: delta) }
    }

    public static func moved(_ ref: CellRef, fromRow: Int?, fromCol: Int?, delta: Int) -> CellRef {
        var result = ref
        if let fromRow, ref.row >= fromRow { result.row = max(0, ref.row + delta) }
        if let fromCol, ref.col >= fromCol { result.col = max(0, ref.col + delta) }
        return result
    }

    /// Riscrive i riferimenti di una formula. Negli intervalli (B2:B6) gli estremi che cadono nelle righe o colonne eliminate
    /// restringono l'intervallo invece di uscire dai dati.
    public static func rewrite(_ formula: String, fromRow: Int?, fromCol: Int?, delta: Int) -> String {
        let ns = formula as NSString
        let range = try! NSRegularExpression(pattern: #"(\$?[A-Z]{1,2}\$?[0-9]+):(\$?[A-Z]{1,2}\$?[0-9]+)"#)
        let single = try! NSRegularExpression(pattern: #"\$?[A-Z]{1,2}\$?[0-9]+"#)
        var covered: [NSRange] = []
        var replacements: [(NSRange, String)] = []
        for match in range.matches(in: formula, range: NSRange(location: 0, length: ns.length)) {
            guard let start = CellRef(ns.substring(with: match.range(at: 1))), let end = CellRef(ns.substring(with: match.range(at: 2))) else { continue }
            covered.append(match.range)
            var from = moved(start, fromRow: fromRow, fromCol: fromCol, delta: delta)
            var to = moved(end, fromRow: fromRow, fromCol: fromCol, delta: delta)
            if delta < 0 {
                // Estremi dentro il blocco eliminato: l'intervallo si stringe sulle celle che restano.
                if let fromRow, start.row >= fromRow, start.row < fromRow - delta { from.row = fromRow }
                if let fromRow, end.row >= fromRow, end.row < fromRow - delta { to.row = fromRow - 1 }
                if let fromCol, start.col >= fromCol, start.col < fromCol - delta { from.col = fromCol }
                if let fromCol, end.col >= fromCol, end.col < fromCol - delta { to.col = fromCol - 1 }
            }
            replacements.append((match.range, "\(from.name):\(to.name)"))
        }
        for match in single.matches(in: formula, range: NSRange(location: 0, length: ns.length))
        where !covered.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            guard let ref = CellRef(ns.substring(with: match.range)) else { continue }
            replacements.append((match.range, moved(ref, fromRow: fromRow, fromCol: fromCol, delta: delta).name))
        }
        var result = formula
        for (range, text) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            result = (result as NSString).replacingCharacters(in: range, with: text)
        }
        return result
    }

    // MARK: Righe e colonne per nome

    /// Righe e colonne con contenuto.
    public var usedSize: (rows: Int, columns: Int) {
        let refs = cells.keys.compactMap(CellRef.init)
        return ((refs.map(\.row).max() ?? -1) + 1, (refs.map(\.col).max() ?? -1) + 1)
    }

    /// Riga con questa etichetta nella prima colonna ("cibo" → la riga «Cibo»).
    public func rowIndex(named name: String) -> Int? {
        let clean = name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "«»\"'.")))
        if let number = Int(clean), number >= 1 { return number - 1 }
        let wanted = DocumentOutline.words(clean)
        let scored = (0..<usedSize.rows).map { row -> (Int, Int) in
            let label = display(CellRef(col: 0, row: row))
            let exact = label.lowercased() == clean.lowercased() ? 5 : 0
            return (row, exact + DocumentOutline.words(label).intersection(wanted).count * 2)
        }
        return scored.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }

    /// Colonna con questa intestazione nella prima riga, o per lettera ("ottobre", "B").
    public func columnIndex(named name: String) -> Int? {
        let clean = name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "«»\"'.")))
        if clean.count <= 2, clean.allSatisfy(\.isLetter), clean == clean.uppercased(), let ref = CellRef(clean + "1") { return ref.col }
        let wanted = DocumentOutline.words(clean)
        let scored = (0..<usedSize.columns).map { col -> (Int, Int) in
            let header = display(CellRef(col: col, row: 0))
            let exact = header.lowercased() == clean.lowercased() ? 5 : 0
            return (col, exact + DocumentOutline.words(header).intersection(wanted).count * 2)
        }
        return scored.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }

    /// Riga dei totali ("Totale", "Totali", "Somma").
    public var totalRowIndex: Int? {
        (1..<max(1, usedSize.rows)).first { row in
            ["totale", "totali", "somma", "total"].contains(display(CellRef(col: 0, row: row)).lowercased().trimmingCharacters(in: .whitespaces))
        }
    }

    /// Colonna dei totali di riga.
    public var totalColumnIndex: Int? {
        (1..<max(1, usedSize.columns)).first { col in
            ["totale", "totali", "somma", "total"].contains(display(CellRef(col: col, row: 0)).lowercased().trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: Applicazione

    /// Riga nuova: sopra il totale si allargano gli intervalli dei totali; le formule di riga si copiano dalla riga sopra.
    public mutating func insertRow(at row: Int, values: [Int: String]) {
        let previous = row - 1
        shift(rows: row, by: 1)
        let pattern = try! NSRegularExpression(pattern: #"(\$?[A-Z]{1,2}\$?)([0-9]+):(\$?[A-Z]{1,2}\$?)([0-9]+)"#)
        for (key, raw) in cells where raw.hasPrefix("=") {
            guard let ref = CellRef(key), ref.row > row else { continue }
            let ns = raw as NSString
            var result = raw
            for match in pattern.matches(in: raw, range: NSRange(location: 0, length: ns.length)).reversed() {
                // Un intervallo che finiva sulla riga sopra quella nuova ora la comprende.
                guard Int(ns.substring(with: match.range(at: 4))) == previous + 1 else { continue }
                let text = ns.substring(with: match.range(at: 1)) + ns.substring(with: match.range(at: 2)) + ":" + ns.substring(with: match.range(at: 3)) + String(row + 1)
                result = (result as NSString).replacingCharacters(in: match.range, with: text)
            }
            cells[key] = result
        }
        if previous >= 1 {
            for col in 0..<max(columns, usedSize.columns) where values[col] == nil {
                let above = raw(CellRef(col: col, row: previous))
                guard above.hasPrefix("=") else { continue }
                set(CellRef(col: col, row: row), Self.retarget(above, fromRow: previous, toRow: row))
            }
        }
        for (col, value) in values { set(CellRef(col: col, row: row), value) }
    }

    /// Formula della riga sopra adattata alla riga nuova (=SOMMA(B4:C4) → =SOMMA(B5:C5)).
    static func retarget(_ formula: String, fromRow: Int, toRow: Int) -> String {
        let pattern = try! NSRegularExpression(pattern: #"(\$?[A-Z]{1,2})(\$?)([0-9]+)"#)
        let ns = formula as NSString
        var result = formula
        for match in pattern.matches(in: formula, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard ns.substring(with: match.range(at: 2)).isEmpty, Int(ns.substring(with: match.range(at: 3))) == fromRow + 1 else { continue }
            result = (result as NSString).replacingCharacters(in: match.range(at: 3), with: String(toRow + 1))
        }
        return result
    }

    /// Applica le operazioni in ordine e restituisce la cella da mostrare.
    @discardableResult
    public mutating func apply(_ operations: [SheetOperation]) -> CellRef? {
        var focus: CellRef?
        for operation in operations {
            switch operation {
            case .set(let ref, let raw):
                set(ref, raw)
                focus = ref
            case .insertRow(let row, let values):
                insertRow(at: row, values: values)
                focus = CellRef(col: 0, row: row)
            case .deleteRow(let row):
                shift(rows: row, by: -1)
                focus = CellRef(col: 0, row: max(0, row - 1))
            case .insertColumn(let col, let header):
                shift(cols: col, by: 1)
                set(CellRef(col: col, row: 0), header)
                focus = CellRef(col: col, row: 0)
            case .deleteColumn(let col):
                shift(cols: col, by: -1)
                focus = CellRef(col: max(0, col - 1), row: 0)
            case .addChart(let kind, let range):
                charts.append(ChartSpec(kind: kind, range: range, title: name))
            }
        }
        return focus
    }

    /// Intervallo dei dati per un grafico: etichette e colonne numeriche, senza la riga e la colonna dei totali.
    public func chartRange(kind: ChartSpec.Kind) -> String {
        let size = usedSize
        let lastRow = (totalRowIndex ?? size.rows) - 1
        var lastCol = (totalColumnIndex ?? size.columns) - 1
        if kind == .pie { lastCol = min(lastCol, 1) }
        return "A1:\(CellRef(col: max(1, lastCol), row: max(1, lastRow)).name)"
    }

    /// Il foglio per il modello: intestazioni con le lettere delle colonne, poi ogni riga con etichetta e valori.
    func described(maxRows: Int = 40) -> String {
        let size = usedSize
        guard size.rows > 0 else { return "(foglio vuoto)" }
        let headers = (0..<size.columns).map { "\(CellRef.columnName($0))=\(display(CellRef(col: $0, row: 0)))" }.joined(separator: ", ")
        let rowsText = (1..<max(1, min(size.rows, maxRows))).map { row in
            "Riga \(row + 1): " + (0..<size.columns).map { col in
                let ref = CellRef(col: col, row: row)
                let raw = self.raw(ref)
                return raw.hasPrefix("=") ? "\(raw) (\(display(ref)))" : display(ref)
            }.joined(separator: " | ")
        }
        return "Colonne: \(headers)\n" + rowsText.joined(separator: "\n")
    }
}

extension Assistant {
    /// Comandi sul foglio riconosciuti con regole: eliminare righe o colonne, grafici, raddoppiare o aumentare una voce.
    public static func quickSheetEdit(_ instruction: String, sheet: Sheet) -> SheetEditPlan? {
        let prompt = instruction.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        let lower = prompt.lowercased()
        if let match = Calculations.matches(#"^(?:elimina|cancella|togli|rimuovi)\s+(?:la\s+)?riga\s+(?:del|della|dello|dei|delle|degli|di|per|su|con|numero)?\s*(.+)$"#, in: prompt).first,
           let row = sheet.rowIndex(named: unquoted(match[1])), row > 0 {
            let label = sheet.display(CellRef(col: 0, row: row))
            return SheetEditPlan(operations: [.deleteRow(row)], summary: "Ho eliminato la riga «\(label)»; i totali si sono aggiornati.")
        }
        if let match = Calculations.matches(#"^(?:elimina|cancella|togli|rimuovi)\s+(?:la\s+)?colonna\s+(?:del|della|dello|dei|delle|degli|di)?\s*(.+)$"#, in: prompt).first,
           let col = sheet.columnIndex(named: unquoted(match[1])), col > 0 {
            let header = sheet.display(CellRef(col: col, row: 0))
            return SheetEditPlan(operations: [.deleteColumn(col)], summary: "Ho eliminato la colonna «\(header)».")
        }
        if lower.range(of: #"^(crea|fai|aggiungi|inserisci|fammi|metti)\s+(un|il)\s+grafico"#, options: .regularExpression) != nil {
            let kind: ChartSpec.Kind = lower.contains("torta") ? .pie : lower.contains("line") ? .line : .bar
            let name = kind == .pie ? "a torta" : kind == .line ? "a linee" : "a barre"
            return SheetEditPlan(operations: [.addChart(kind, range: sheet.chartRange(kind: kind))], summary: "Ho aggiunto un grafico \(name).")
        }
        // "Raddoppia la spesa dell'hotel", "aumenta del 10% il volo", "dimezza il cibo".
        let change: (String, String)? = {
            if let m = Calculations.matches(#"^raddoppia\s+(.+)$"#, in: prompt).first { return ("x * 2", m[1]) }
            if let m = Calculations.matches(#"^dimezza\s+(.+)$"#, in: prompt).first { return ("x / 2", m[1]) }
            if let m = Calculations.matches(#"^(aumenta|diminuisci|riduci|alza|abbassa)\s+(?:del\s+)?(\d+(?:[.,]\d+)?)\s*%\s+(.+)$"#, in: prompt).first,
               let percent = Calculations.number(m[2]) {
                let sign = ["aumenta", "alza"].contains(m[1].lowercased()) ? "+" : "-"
                return ("x * (1 \(sign) \(percent) / 100)", m[3])
            }
            if let m = Calculations.matches(#"^(aumenta|diminuisci|riduci|alza|abbassa)\s+(.+?)\s+del\s+(\d+(?:[.,]\d+)?)\s*%$"#, in: prompt).first,
               let percent = Calculations.number(m[3]) {
                let sign = ["aumenta", "alza"].contains(m[1].lowercased()) ? "+" : "-"
                return ("x * (1 \(sign) \(percent) / 100)", m[2])
            }
            return nil
        }()
        if let (expression, target) = change {
            let name = target.replacingOccurrences(of: #"^(la spesa|il costo|il valore|la voce|l'importo|i valori)?\s*(del|della|dello|dei|delle|degli|di|per)?\s*(l'|la |il |lo )?"#,
                                                   with: "", options: [.regularExpression, .caseInsensitive])
            guard let row = sheet.rowIndex(named: name), row > 0 else { return nil }
            let operations = changedCells(in: sheet, row: row, expression: expression)
            guard !operations.isEmpty else { return nil }
            return SheetEditPlan(operations: operations, summary: "Ho aggiornato «\(sheet.display(CellRef(col: 0, row: row)))» (\(operations.count) celle); i totali si sono ricalcolati.")
        }
        return nil
    }

    /// Nuovi valori per le celle numeriche di una riga (le formule restano): x è il valore attuale.
    static func changedCells(in sheet: Sheet, row: Int, columns: [Int]? = nil, expression: String) -> [SheetOperation] {
        let size = sheet.usedSize
        let total = sheet.totalColumnIndex
        return (columns ?? Array(1..<max(1, size.columns))).compactMap { col -> SheetOperation? in
            let ref = CellRef(col: col, row: row)
            let raw = sheet.raw(ref)
            guard col != total, !raw.hasPrefix("="), let value = sheet.value(ref).number, !raw.isEmpty,
                  let result = Calculations.evaluate(expression.replacingOccurrences(of: #"\bx\b"#, with: "(\(value))", options: .regularExpression)) else { return nil }
            let rounded = (result * 100).rounded() / 100
            return .set(ref, rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded))
        }
    }

    private static let sheetEditSchema = makeSchema("ModificheFoglio", [
        .required("operazioni", .array(.object("Operazione", [
            .required("tipo", .choice(["imposta", "aggiungi_riga", "elimina_riga", "aggiungi_colonna", "elimina_colonna", "grafico"]),
                      "imposta scrive o cambia valori; aggiungi_riga ne crea una nuova; elimina_riga, aggiungi_colonna, elimina_colonna, grafico"),
            .optional("riga", .string, "Etichetta della riga (prima colonna) o numero di riga"),
            .optional("colonna", .string, "Intestazione o lettera della colonna; «tutte» per tutte le colonne con numeri"),
            .optional("valore", .string, "Numero o formula da scrivere, per imposta"),
            .optional("espressione", .string, "Per cambiare i valori che ci sono: espressione con x al posto del valore attuale, es. x * 2"),
            .optional("valori", .array(.object("ValoreColonna", [
                .required("colonna", .string, "Intestazione o lettera della colonna"),
                .required("valore", .string, "Numero o formula"),
            ]), max: 8), "Per aggiungi_riga: i valori della riga nuova"),
            .optional("intestazione", .string, "Per aggiungi_colonna: nome della colonna nuova"),
            .optional("grafico", .choice(["barre", "linee", "torta"]), "Per grafico: il tipo"),
        ]), min: 1, max: 8), "Operazioni da applicare, in ordine"),
    ])

    /// Modifica del foglio aperto: regole per i comandi comuni, altrimenti il modello indica righe e colonne per nome.
    public func planSheetEdit(_ instruction: String, sheet: Sheet,
                              status: @escaping @MainActor (String) -> Void = { _ in }) async throws -> SheetEditPlan {
        if let quick = Self.quickSheetEdit(instruction, sheet: sheet) {
            Agent.log("MODIFICA FOGLIO (regole): \(quick.summary)")
            return quick
        }
        status("Scelgo cosa cambiare nel foglio…")
        let session = LanguageModelSession(model: Agent.model, instructions: """
        Modifichi un foglio di calcolo aperto nell'editor. Ricevi le colonne (lettera=intestazione) e le righe con etichetta e valori.
        Restituisci solo le operazioni necessarie. Indica righe e colonne con la loro etichetta o intestazione, così come compaiono.
        Per cambiare valori esistenti in proporzione usa espressione con x (x * 2 per raddoppiare). Numeri senza simbolo di valuta.
        """)
        let content = try await session.respond(to: "Foglio «\(sheet.name)»:\n\(sheet.described())\n\nRichiesta: \(instruction)",
                                                schema: Self.sheetEditSchema, options: GenerationOptions(samplingMode: .greedy)).content
        // Le operazioni si risolvono su una copia del foglio aggiornata passo per passo (gli indici cambiano).
        var working = sheet
        var operations: [SheetOperation] = []
        var parts: [String] = []
        func number(_ text: String) -> String {
            let clean = text.replacingOccurrences(of: "€", with: "").trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("=") { return clean }
            return Calculations.number(clean).map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? clean
        }
        for item in content.objects("operazioni") {
            guard let kind = item.string("tipo") else { continue }
            var step: [SheetOperation] = []
            switch kind {
            case "imposta":
                guard let rowName = item.string("riga"), let row = working.rowIndex(named: rowName) else { continue }
                let columnName = item.string("colonna") ?? "tutte"
                let columns: [Int]? = columnName.lowercased().hasPrefix("tutt") ? nil : working.columnIndex(named: columnName).map { [$0] }
                if let expression = item.string("espressione"), expression.contains("x") {
                    step = Self.changedCells(in: working, row: row, columns: columns, expression: expression)
                } else if let value = item.string("valore"), let col = columns?.first {
                    step = [.set(CellRef(col: col, row: row), number(value))]
                }
                if !step.isEmpty { parts.append("aggiornato «\(working.display(CellRef(col: 0, row: row)))»") }
            case "aggiungi_riga":
                guard let label = item.string("riga"), !label.isEmpty else { continue }
                var values: [Int: String] = [0: label]
                for pair in item.objects("valori") {
                    // La colonna dei totali tiene la sua formula (copiata dalla riga sopra).
                    guard let columnName = pair.string("colonna"), let col = working.columnIndex(named: columnName), col > 0,
                          col != working.totalColumnIndex, let value = pair.string("valore") else { continue }
                    values[col] = number(value)
                }
                // Colonna non detta nella richiesta e stesso valore dappertutto: va solo nella prima colonna di numeri.
                let named = (1..<max(1, working.usedSize.columns)).contains { col in
                    let header = working.display(CellRef(col: col, row: 0)).lowercased()
                    return !header.isEmpty && instruction.lowercased().contains(header)
                }
                let numbers = values.filter { $0.key > 0 }
                if !named, numbers.count > 1, Set(numbers.values).count == 1, let first = numbers.keys.min() {
                    values = [0: label, first: numbers[first]!]
                }
                let at = working.totalRowIndex ?? working.usedSize.rows
                step = [.insertRow(at: at, values: values)]
                parts.append("aggiunto la riga «\(label)»")
            case "elimina_riga":
                guard let rowName = item.string("riga"), let row = working.rowIndex(named: rowName), row > 0 else { continue }
                step = [.deleteRow(row)]
                parts.append("eliminato la riga «\(working.display(CellRef(col: 0, row: row)))»")
            case "aggiungi_colonna":
                guard let header = item.string("intestazione") ?? item.string("colonna") else { continue }
                let at = working.totalColumnIndex ?? working.usedSize.columns
                step = [.insertColumn(at: at, header: header)]
                parts.append("aggiunto la colonna «\(header)»")
            case "elimina_colonna":
                guard let columnName = item.string("colonna"), let col = working.columnIndex(named: columnName), col > 0 else { continue }
                step = [.deleteColumn(col)]
                parts.append("eliminato la colonna «\(working.display(CellRef(col: col, row: 0)))»")
            case "grafico":
                let chart: ChartSpec.Kind = item.string("grafico") == "torta" ? .pie : item.string("grafico") == "linee" ? .line : .bar
                step = [.addChart(chart, range: working.chartRange(kind: chart))]
                parts.append("aggiunto un grafico")
            default: continue
            }
            working.apply(step)
            operations += step
        }
        guard !operations.isEmpty else { return SheetEditPlan(operations: [], summary: "Non ho capito cosa cambiare nel foglio: dimmi quale riga o colonna.") }
        let text = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " e " + parts.last!
        return SheetEditPlan(operations: operations, summary: "Ho " + text + "; i totali si sono aggiornati.")
    }
}
