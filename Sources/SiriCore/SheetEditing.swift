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

    /// Etichette dei totali, in italiano e in inglese (un foglio può essere scritto in una lingua diversa dalla richiesta).
    static let totalLabels: Set = ["totale", "totali", "somma", "total", "totals", "sum", "grand total"]

    /// Riga dei totali ("Totale", "Totali", "Somma", "Total").
    public var totalRowIndex: Int? {
        (1..<max(1, usedSize.rows)).first { row in
            Self.totalLabels.contains(display(CellRef(col: 0, row: row)).lowercased().trimmingCharacters(in: .whitespaces))
        }
    }

    /// Colonna dei totali di riga.
    public var totalColumnIndex: Int? {
        (1..<max(1, usedSize.columns)).first { col in
            Self.totalLabels.contains(display(CellRef(col: col, row: 0)).lowercased().trimmingCharacters(in: .whitespaces))
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
        guard size.rows > 0 else { return Language.t("(foglio vuoto)", "(empty sheet)") }
        let headers = (0..<size.columns).map { "\(CellRef.columnName($0))=\(display(CellRef(col: $0, row: 0)))" }.joined(separator: ", ")
        let rowsText = (1..<max(1, min(size.rows, maxRows))).map { row in
            Language.t("Riga \(row + 1): ", "Row \(row + 1): ") + (0..<size.columns).map { col in
                let ref = CellRef(col: col, row: row)
                let raw = self.raw(ref)
                return raw.hasPrefix("=") ? "\(raw) (\(display(ref)))" : display(ref)
            }.joined(separator: " | ")
        }
        return Language.t("Colonne: ", "Columns: ") + headers + "\n" + rowsText.joined(separator: "\n")
    }
}

extension Assistant {
    /// Numero scritto dal modello o nella richiesta ("45", "1.580", "89,90"); in inglese anche "1,500" (migliaia), "$30", "45 euros".
    static func sheetNumber(_ text: String) -> Double? {
        guard Language.isEnglish else { return Calculations.number(text) }
        let clean = text.replacingOccurrences(of: #"(?i)(?:€|\$|£|\beuros?\b|\beur\b|\bdollars?\b|\busd\b|\bpounds?\b|\bgbp\b)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if clean.range(of: #"^-?\d{1,3}(?:,\d{3})+(?:\.\d+)?$"#, options: .regularExpression) != nil {
            return Double(clean.replacingOccurrences(of: ",", with: ""))
        }
        return Calculations.number(clean)
    }

    /// Comandi inglesi sul foglio: "delete the food row", "delete the October column", "create a pie chart", "double the hotel cost",
    /// "increase flights by 10%", "add a row for insurance, 45 euros in October".
    static func quickEnglishSheetEdit(_ prompt: String, sheet: Sheet) -> SheetEditPlan? {
        let lower = prompt.lowercased()
        let delete = #"(?:delete|remove|erase|drop|get\s+rid\s+of)"#
        // Righe e colonne per nome, prima o dopo la parola ("the food row", "the row for food", "row 3").
        if let match = Calculations.matches("^" + delete + #"\s+(?:the\s+)?row\s+(?:(?:for|of|with|about|called|named|labell?ed|number)\s+)?(?:the\s+)?(.+)$"#, in: prompt).first
            ?? Calculations.matches("^" + delete + #"\s+(?:the\s+)?(.+?)\s+row$"#, in: prompt).first,
           let row = sheet.rowIndex(named: unquoted(match[1])), row > 0 {
            let label = sheet.display(CellRef(col: 0, row: row))
            return SheetEditPlan(operations: [.deleteRow(row)], summary: "I deleted the row “\(label)”; the totals have been updated.")
        }
        if let match = Calculations.matches("^" + delete + #"\s+(?:the\s+)?column\s+(?:(?:for|of|with|called|named|labell?ed)\s+)?(?:the\s+)?(.+)$"#, in: prompt).first
            ?? Calculations.matches("^" + delete + #"\s+(?:the\s+)?(.+?)\s+column$"#, in: prompt).first,
           let col = sheet.columnIndex(named: unquoted(match[1])), col > 0 {
            let header = sheet.display(CellRef(col: col, row: 0))
            return SheetEditPlan(operations: [.deleteColumn(col)], summary: "I deleted the column “\(header)”.")
        }
        if lower.range(of: #"^(?:create|make|add|insert|draw|build|generate|put|give\s+me|show\s+me)\s+(?:me\s+)?(?:a|an|the)\s+(?:[\w-]+\s+){0,3}(?:chart|graph)\b"#, options: .regularExpression) != nil {
            let kind: ChartSpec.Kind = lower.range(of: #"\bpie\b"#, options: .regularExpression) != nil ? .pie
                : lower.range(of: #"\bline\b"#, options: .regularExpression) != nil ? .line : .bar
            let name = kind == .pie ? "pie" : kind == .line ? "line" : "bar"
            return SheetEditPlan(operations: [.addChart(kind, range: sheet.chartRange(kind: kind))], summary: "I added a \(name) chart.")
        }
        // "Double the hotel cost", "halve the food", "increase flights by 10%", "reduce the hotel by 5 percent".
        let percent = #"(\d+(?:[.,]\d+)?)\s*(?:%|percent|per\s+cent)"#
        let change: (String, String)? = {
            if let m = Calculations.matches(#"^double\s+(.+)$"#, in: prompt).first { return ("x * 2", m[1]) }
            if let m = Calculations.matches(#"^triple\s+(.+)$"#, in: prompt).first { return ("x * 3", m[1]) }
            if let m = Calculations.matches(#"^halve\s+(.+)$"#, in: prompt).first { return ("x / 2", m[1]) }
            if let m = Calculations.matches(#"^cut\s+(.+?)\s+in\s+half$"#, in: prompt).first { return ("x / 2", m[1]) }
            if let m = Calculations.matches(#"^(increase|raise|decrease|reduce|lower|cut)\s+(.+?)\s+by\s+"# + percent + "$", in: prompt).first,
               let value = Calculations.number(m[3]) {
                return ("x * (1 \(["increase", "raise"].contains(m[1].lowercased()) ? "+" : "-") \(value) / 100)", m[2])
            }
            if let m = Calculations.matches(#"^(increase|raise|decrease|reduce|lower|cut)\s+by\s+"# + percent + #"\s+(.+)$"#, in: prompt).first,
               let value = Calculations.number(m[2]) {
                return ("x * (1 \(["increase", "raise"].contains(m[1].lowercased()) ? "+" : "-") \(value) / 100)", m[3])
            }
            return nil
        }()
        if let (expression, target) = change {
            let name = target
                .replacingOccurrences(of: #"^(?:the\s+)?(?:cost|costs|expense|expenses|spending|value|values|amount|price|figure|entry|item)\s+(?:of|for)\s+"#,
                                      with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"^(?:the|all\s+the)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"\s+(?:cost|costs|expense|expenses|spending|value|values|amount|price|figures?|row|line|entry|item)$"#,
                                      with: "", options: [.regularExpression, .caseInsensitive])
            guard let row = sheet.rowIndex(named: name), row > 0 else { return nil }
            let operations = changedCells(in: sheet, row: row, expression: expression)
            guard !operations.isEmpty else { return nil }
            return SheetEditPlan(operations: operations,
                                 summary: "I updated “\(sheet.display(CellRef(col: 0, row: row)))” (\(operations.count) \(operations.count == 1 ? "cell" : "cells")); the totals have been recalculated.")
        }
        if let plan = englishNewRow(prompt, sheet: sheet) { return plan }
        return nil
    }

    /// "Add a row for insurance, 45 euros in October (and 30 in November)": riga nuova sopra il totale, senza modello.
    /// Solo se tutto ciò che segue l'etichetta sono importi con la loro colonna; altrimenti decide il modello.
    static func englishNewRow(_ prompt: String, sheet: Sheet) -> SheetEditPlan? {
        guard let match = Calculations.matches(#"^(?:add|insert|create|put)\s+(?:a\s+|another\s+)?(?:new\s+)?row\s+(?:for|called|named|labell?ed|with\s+the\s+label)\s+(?:the\s+|an?\s+)?(.+?)(?:\s*[,:;]\s*|\s+with\s+|\s+of\s+|\s+at\s+)(.+)$"#, in: prompt).first
        else { return nil }
        let label = unquoted(match[1])
        guard !label.isEmpty, label.split(separator: " ").count <= 4, label.rangeOfCharacter(from: .decimalDigits) == nil else { return nil }
        let amount = #"(?:€|\$|£)?\s*(\d+(?:[.,]\d+)*)\s*(?:€|\$|£|euros?|eur|dollars?|usd|pounds?|gbp)?(?:\s+(?:in|for|on|under)\s+(?:the\s+)?([\p{L}][\p{L}\d ]*?))?\s*(?:,|;|&|\band\b|$)"#
        let rest = match[2].trimmingCharacters(in: .whitespaces)
        let pairs = Calculations.matches(amount, in: rest)
        // Tutto il resto dev'essere fatto di importi: "45 euros in October and 30 in November".
        let leftover = rest.replacingOccurrences(of: amount, with: "", options: [.regularExpression, .caseInsensitive])
        guard !pairs.isEmpty, leftover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let total = sheet.totalColumnIndex
        let numeric = (1..<max(1, sheet.usedSize.columns)).filter { $0 != total }
        var values: [Int: String] = [0: label.prefix(1).uppercased() + label.dropFirst()]
        for (position, pair) in pairs.enumerated() {
            guard let value = sheetNumber(pair[1]) else { return nil }
            let col: Int
            if !pair[2].isEmpty {
                guard let named = sheet.columnIndex(named: pair[2].trimmingCharacters(in: .whitespaces)), named > 0, named != total else { return nil }
                col = named
            } else {
                // Importi senza colonna: nelle colonne di numeri, in ordine.
                guard numeric.indices.contains(position) else { return nil }
                col = numeric[position]
            }
            values[col] = value == value.rounded() ? String(Int(value)) : String(value)
        }
        let at = sheet.totalRowIndex ?? sheet.usedSize.rows
        return SheetEditPlan(operations: [.insertRow(at: at, values: values)], summary: "I added the row “\(values[0] ?? label)”; the totals have been updated.")
    }

    /// Comandi sul foglio riconosciuti con regole: eliminare righe o colonne, grafici, raddoppiare o aumentare una voce.
    public static func quickSheetEdit(_ instruction: String, sheet: Sheet) -> SheetEditPlan? {
        let prompt = instruction.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        // In inglese prima le regole inglesi; un comando in italiano resta valido.
        if Language.isEnglish, let plan = quickEnglishSheetEdit(prompt, sheet: sheet) { return plan }
        let lower = prompt.lowercased()
        if let match = Calculations.matches(#"^(?:elimina|cancella|togli|rimuovi)\s+(?:la\s+)?riga\s+(?:del|della|dello|dei|delle|degli|di|per|su|con|numero)?\s*(.+)$"#, in: prompt).first,
           let row = sheet.rowIndex(named: unquoted(match[1])), row > 0 {
            let label = sheet.display(CellRef(col: 0, row: row))
            return SheetEditPlan(operations: [.deleteRow(row)], summary: Language.t("Ho eliminato la riga «\(label)»; i totali si sono aggiornati.",
                                                                                  "I deleted the row “\(label)”; the totals have been updated."))
        }
        if let match = Calculations.matches(#"^(?:elimina|cancella|togli|rimuovi)\s+(?:la\s+)?colonna\s+(?:del|della|dello|dei|delle|degli|di)?\s*(.+)$"#, in: prompt).first,
           let col = sheet.columnIndex(named: unquoted(match[1])), col > 0 {
            let header = sheet.display(CellRef(col: col, row: 0))
            return SheetEditPlan(operations: [.deleteColumn(col)], summary: Language.t("Ho eliminato la colonna «\(header)».", "I deleted the column “\(header)”."))
        }
        if lower.range(of: #"^(crea|fai|aggiungi|inserisci|fammi|metti)\s+(un|il)\s+grafico"#, options: .regularExpression) != nil {
            let kind: ChartSpec.Kind = lower.contains("torta") ? .pie : lower.contains("line") ? .line : .bar
            let name = kind == .pie ? "a torta" : kind == .line ? "a linee" : "a barre"
            let english = kind == .pie ? "pie" : kind == .line ? "line" : "bar"
            return SheetEditPlan(operations: [.addChart(kind, range: sheet.chartRange(kind: kind))],
                                 summary: Language.t("Ho aggiunto un grafico \(name).", "I added a \(english) chart."))
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
            let label = sheet.display(CellRef(col: 0, row: row))
            return SheetEditPlan(operations: operations, summary: Language.t("Ho aggiornato «\(label)» (\(operations.count) celle); i totali si sono ricalcolati.",
                                                                           "I updated “\(label)” (\(operations.count) \(operations.count == 1 ? "cell" : "cells")); the totals have been recalculated."))
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

    /// Lo stesso schema per le richieste in inglese: il codice accetta i valori in tutte e due le lingue.
    static let englishSheetEditSchema = makeSchema("SheetEdits", [
        .required("operations", .array(.object("Operation", [
            .required("type", .choice(["set", "add_row", "delete_row", "add_column", "delete_column", "chart"]),
                      "set writes or changes values; add_row creates a new one; delete_row, add_column, delete_column, chart"),
            .optional("row", .string, "Row label (first column) or row number"),
            .optional("column", .string, "Column header or letter; “all” for all the columns with numbers"),
            .optional("value", .string, "Number or formula to write, for set"),
            .optional("expression", .string, "To change the existing values: expression with x in place of the current value, e.g. x * 2"),
            .optional("values", .array(.object("ColumnValue", [
                .required("column", .string, "Column header or letter"),
                .required("value", .string, "Number or formula"),
            ]), max: 8), "For add_row: the values of the new row"),
            .optional("header", .string, "For add_column: name of the new column"),
            .optional("chart", .choice(["bar", "line", "pie"]), "For chart: the type"),
        ]), min: 1, max: 8), "Operations to apply, in order"),
    ])

    /// Tipo di operazione scelto dal modello, anche in inglese ("add_row" → "aggiungi_riga").
    static func sheetOperationKind(_ kind: String) -> String {
        ["set": "imposta", "add_row": "aggiungi_riga", "delete_row": "elimina_riga", "add_column": "aggiungi_colonna",
         "delete_column": "elimina_colonna", "chart": "grafico"][kind.lowercased()] ?? kind
    }

    /// Modifica del foglio aperto: regole per i comandi comuni, altrimenti il modello indica righe e colonne per nome.
    public func planSheetEdit(_ instruction: String, sheet: Sheet,
                              status: @escaping @MainActor (String) -> Void = { _ in }) async throws -> SheetEditPlan {
        if let quick = Self.quickSheetEdit(instruction, sheet: sheet) {
            Agent.log("MODIFICA FOGLIO (regole): \(quick.summary)")
            return quick
        }
        status(Language.t("Scelgo cosa cambiare nel foglio…", "Choosing what to change in the sheet…"))
        let english = Language.isEnglish
        let session = LanguageModelSession(model: Agent.model, instructions: english ? """
        You edit a spreadsheet open in the editor. You receive the columns (letter=header) and the rows with label and values.
        Return only the necessary operations. Refer to rows and columns by their label or header, exactly as they appear.
        To change existing values proportionally use expression with x (x * 2 to double). Numbers without currency symbols.
        """ : """
        Modifichi un foglio di calcolo aperto nell'editor. Ricevi le colonne (lettera=intestazione) e le righe con etichetta e valori.
        Restituisci solo le operazioni necessarie. Indica righe e colonne con la loro etichetta o intestazione, così come compaiono.
        Per cambiare valori esistenti in proporzione usa espressione con x (x * 2 per raddoppiare). Numeri senza simbolo di valuta.
        """)
        let request = english ? "Sheet “\(sheet.name)”:\n\(sheet.described())\n\nRequest: \(instruction)"
            : "Foglio «\(sheet.name)»:\n\(sheet.described())\n\nRichiesta: \(instruction)"
        let content = try await session.respond(to: request, schema: english ? Self.englishSheetEditSchema : Self.sheetEditSchema,
                                                options: GenerationOptions(samplingMode: .greedy)).content
        // Le operazioni si risolvono su una copia del foglio aggiornata passo per passo (gli indici cambiano).
        var working = sheet
        var operations: [SheetOperation] = []
        var parts: [String] = []
        func number(_ text: String) -> String {
            let clean = text.replacingOccurrences(of: "€", with: "").trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("=") { return clean }
            return Self.sheetNumber(clean).map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? clean
        }
        // Campi e valori dello schema in italiano o in inglese.
        for item in content.objects("operazioni") + content.objects("operations") {
            guard let kind = (item.string("tipo") ?? item.string("type")).map(Self.sheetOperationKind) else { continue }
            let rowName = item.string("riga") ?? item.string("row")
            let columnField = item.string("colonna") ?? item.string("column")
            var step: [SheetOperation] = []
            switch kind {
            case "imposta":
                guard let rowName, let row = working.rowIndex(named: rowName) else { continue }
                let columnName = columnField ?? "tutte"
                let all = columnName.lowercased().hasPrefix("tutt")
                    || english && ["all", "all columns", "every column", "each column", "everything", "*"].contains(columnName.lowercased())
                let columns: [Int]? = all ? nil : working.columnIndex(named: columnName).map { [$0] }
                if let expression = item.string("espressione") ?? item.string("expression"), expression.contains("x") {
                    step = Self.changedCells(in: working, row: row, columns: columns, expression: expression)
                } else if let value = item.string("valore") ?? item.string("value"), let col = columns?.first {
                    step = [.set(CellRef(col: col, row: row), number(value))]
                }
                if !step.isEmpty {
                    let label = working.display(CellRef(col: 0, row: row))
                    parts.append(Language.t("aggiornato «\(label)»", "updated “\(label)”"))
                }
            case "aggiungi_riga":
                guard let label = rowName, !label.isEmpty else { continue }
                var values: [Int: String] = [0: label]
                for pair in item.objects("valori") + item.objects("values") {
                    // La colonna dei totali tiene la sua formula (copiata dalla riga sopra).
                    guard let columnName = pair.string("colonna") ?? pair.string("column"), let col = working.columnIndex(named: columnName), col > 0,
                          col != working.totalColumnIndex, let value = pair.string("valore") ?? pair.string("value") else { continue }
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
                parts.append(Language.t("aggiunto la riga «\(label)»", "added the row “\(label)”"))
            case "elimina_riga":
                guard let rowName, let row = working.rowIndex(named: rowName), row > 0 else { continue }
                step = [.deleteRow(row)]
                let label = working.display(CellRef(col: 0, row: row))
                parts.append(Language.t("eliminato la riga «\(label)»", "deleted the row “\(label)”"))
            case "aggiungi_colonna":
                guard let header = item.string("intestazione") ?? item.string("header") ?? columnField else { continue }
                let at = working.totalColumnIndex ?? working.usedSize.columns
                step = [.insertColumn(at: at, header: header)]
                parts.append(Language.t("aggiunto la colonna «\(header)»", "added the column “\(header)”"))
            case "elimina_colonna":
                guard let columnName = columnField, let col = working.columnIndex(named: columnName), col > 0 else { continue }
                step = [.deleteColumn(col)]
                let header = working.display(CellRef(col: col, row: 0))
                parts.append(Language.t("eliminato la colonna «\(header)»", "deleted the column “\(header)”"))
            case "grafico":
                let kindName = item.string("grafico") ?? item.string("chart")
                let chart: ChartSpec.Kind = ["torta", "pie"].contains(kindName) ? .pie : ["linee", "line"].contains(kindName) ? .line : .bar
                step = [.addChart(chart, range: working.chartRange(kind: chart))]
                parts.append(Language.t("aggiunto un grafico", "added a chart"))
            default: continue
            }
            working.apply(step)
            operations += step
        }
        guard !operations.isEmpty else {
            return SheetEditPlan(operations: [], summary: Language.t("Non ho capito cosa cambiare nel foglio: dimmi quale riga o colonna.",
                                                                     "I didn't understand what to change in the sheet: tell me which row or column."))
        }
        return SheetEditPlan(operations: operations, summary: Language.t("Ho ", "I ") + Self.joined(parts)
                             + Language.t("; i totali si sono aggiornati.", "; the totals have been updated."))
    }
}
