import Foundation

/// Markdown → HTML per l'anteprima dei file .md (titoli, elenchi, caselle, citazioni, codice, tabelle, link, frontmatter).
public enum Markdown {
    public static func html(from markdown: String) -> String {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [String] = []

        // Frontmatter YAML (---) in una tabellina discreta.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            let rows = lines[1..<end].compactMap { line -> String? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return "<tr><th>\(escape(key))</th><td>\(inline(value))</td></tr>"
            }
            if !rows.isEmpty { out.append("<table class=\"frontmatter\">\(rows.joined())</table>") }
            lines.removeSubrange(0...end)
        }

        var index = 0
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append("<p>\(paragraph.map(inline).joined(separator: "<br>"))</p>") }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blocchi di codice
            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3))
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[index]); index += 1 }
                out.append("<pre><code class=\"language-\(escape(language))\">\(escape(code.joined(separator: "\n")))</code></pre>")
                index += 1
                continue
            }
            if trimmed.isEmpty { flush(); index += 1; continue }

            // Titoli
            if let match = trimmed.range(of: #"^#{1,6}\s"#, options: .regularExpression) {
                flush()
                let level = trimmed[match].filter { $0 == "#" }.count
                let text = String(trimmed[match.upperBound...])
                let anchor = text.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "-", options: .regularExpression)
                out.append("<h\(level) id=\"\(anchor)\">\(inline(text))</h\(level)>")
                index += 1
                continue
            }
            // Linea orizzontale
            if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                flush(); out.append("<hr>"); index += 1; continue
            }
            // Citazioni (anche i callout di Obsidian «> [!nota]»)
            if trimmed.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                var body = quote
                var className = ""
                if let first = body.first, let callout = first.range(of: #"^\[!(\w+)\]"#, options: .regularExpression) {
                    className = " class=\"callout\""
                    let title = first[callout.upperBound...].trimmingCharacters(in: .whitespaces)
                    body[0] = title.isEmpty ? "**\(first[callout].dropFirst(2).dropLast())**" : "**\(title)**"
                }
                out.append("<blockquote\(className)>\(html(from: body.joined(separator: "\n")))</blockquote>")
                continue
            }
            // Tabelle
            if trimmed.hasPrefix("|"), index + 1 < lines.count,
               lines[index + 1].trimmingCharacters(in: .whitespaces).range(of: #"^\|?\s*:?-{2,}"#, options: .regularExpression) != nil {
                flush()
                func cells(_ row: String) -> [String] {
                    row.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                let header = cells(trimmed).map { "<th>\(inline($0))</th>" }.joined()
                var rows: [String] = []
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append("<tr>" + cells(lines[index]).map { "<td>\(inline($0))</td>" }.joined() + "</tr>")
                    index += 1
                }
                out.append("<table><thead><tr>\(header)</tr></thead><tbody>\(rows.joined())</tbody></table>")
                continue
            }
            // Elenchi (anche annidati e con caselle)
            if trimmed.range(of: #"^([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil {
                flush()
                var items: [(indent: Int, ordered: Bool, text: String)] = []
                while index < lines.count {
                    let raw = lines[index]
                    let t = raw.trimmingCharacters(in: .whitespaces)
                    guard let marker = t.range(of: #"^([-*+]|\d+[.)])\s"#, options: .regularExpression) else {
                        // Riga di continuazione dell'elemento precedente.
                        if !t.isEmpty, raw.hasPrefix("  "), !items.isEmpty { items[items.count - 1].text += " " + t; index += 1; continue }
                        break
                    }
                    let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                    let ordered = t[marker].first?.isNumber == true
                    // Un elenco numerato subito dopo uno puntato (allo stesso livello) è un nuovo elenco.
                    if let first = items.first, indent / 2 == first.indent, ordered != first.ordered { break }
                    items.append((indent / 2, ordered, String(t[marker.upperBound...])))
                    index += 1
                }
                out.append(list(items[...]))
                continue
            }
            paragraph.append(trimmed)
            index += 1
        }
        flush()
        return out.joined(separator: "\n")
    }

    private static func list(_ items: ArraySlice<(indent: Int, ordered: Bool, text: String)>) -> String {
        guard let first = items.first else { return "" }
        let base = first.indent
        let tag = first.ordered ? "ol" : "ul"
        var html = "<\(tag)>"
        var i = items.startIndex
        while i < items.endIndex {
            let item = items[i]
            var j = i + 1
            while j < items.endIndex, items[j].indent > base { j += 1 }
            var text = item.text
            var checkbox = ""
            if let box = text.range(of: #"^\[([ xX])\]\s*"#, options: .regularExpression) {
                let checked = text[box].lowercased().contains("x")
                checkbox = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                text = String(text[box.upperBound...])
                html += "<li class=\"task\(checked ? " done" : "")\">"
            } else {
                html += "<li>"
            }
            html += checkbox + inline(text)
            if j > i + 1 { html += list(items[(i + 1)..<j]) }
            html += "</li>"
            i = j
        }
        return html + "</\(tag)>"
    }

    /// Grassetto, corsivo, barrato, codice, link, immagini, wikilink di Obsidian ed evidenziato.
    static func inline(_ text: String) -> String {
        var codes: [String] = []
        var result = escape(text)
        // Il codice in linea non va toccato dalle altre regole.
        result = replace(result, #"`([^`]+)`"#) { groups in
            codes.append("<code>\(groups[1])</code>")
            return "\u{1}\(codes.count - 1)\u{1}"
        }
        result = replace(result, #"!\[([^\]]*)\]\(([^)\s]+)[^)]*\)"#) { "<img src=\"\(safeURL($0[2], image: true))\" alt=\"\($0[1])\">" }
        result = replace(result, #"\[([^\]]+)\]\(([^)\s]+)[^)]*\)"#) { "<a href=\"\(safeURL($0[2]))\">\($0[1])</a>" }
        // `[[Nome|testo]]` di Obsidian: un collegamento che l'app apre in un'altra scheda (schema interno, mai eseguito dal browser).
        result = replace(result, #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#) { groups in
            let target = groups[1].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groups[1]
            return "<a class=\"wikilink\" href=\"siriai-wiki:\(target)\">\(groups[2].isEmpty ? groups[1] : groups[2])</a>"
        }
        result = replace(result, #"(\*\*|__)(.+?)\1"#) { "<strong>\($0[2])</strong>" }
        result = replace(result, #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\w)"#) { "<em>\($0[1])</em>" }
        result = replace(result, #"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)"#) { "<em>\($0[1])</em>" }
        result = replace(result, #"~~(.+?)~~"#) { "<del>\($0[1])</del>" }
        result = replace(result, #"==(.+?)=="#) { "<mark>\($0[1])</mark>" }
        result = replace(result, #"(?<!["=>])\b(https?://[^\s<]+)"#) { "<a href=\"\($0[1])\">\($0[1])</a>" }
        for (i, code) in codes.enumerated() { result = result.replacingOccurrences(of: "\u{1}\(i)\u{1}", with: code) }
        return result
    }

    private static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { i -> String in
                let range = match.range(at: i)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        return result + ns.substring(from: last)
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Solo indirizzi innocui nei link e nelle immagini: web, email, ancore e percorsi relativi (niente `javascript:` o `file:`).
    static func safeURL(_ raw: String, image: Bool = false) -> String {
        let value = raw.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespaces)
        let lower = value.lowercased()
        if let colon = lower.firstIndex(of: ":"), !lower[..<colon].contains("/") {
            let scheme = String(lower[..<colon])
            let allowed = image ? ["http", "https", "data"] : ["http", "https", "mailto"]
            guard allowed.contains(scheme), scheme != "data" || lower.hasPrefix("data:image/") else { return "#" }
        }
        return escape(value)
    }

    /// Pagina completa per l'anteprima, con lo stile di sistema (chiaro e scuro).
    public static func page(_ markdown: String, title: String = "") -> String {
        """
        <!doctype html><html lang="it"><head><meta charset="utf-8"><title>\(escape(title))</title>
        <meta name="color-scheme" content="light dark">
        <style>
        :root { --text:#1d1d1f; --muted:#6e6e73; --bg:#ffffff; --soft:#f5f5f7; --line:#d2d2d7; --accent:#0071e3; --mark:#fff3a3; }
        @media (prefers-color-scheme: dark) { :root { --text:#f5f5f7; --muted:#a1a1a6; --bg:#1e1e1e; --soft:#2c2c2e; --line:#3a3a3c; --accent:#2997ff; --mark:#5c4d00; } }
        html { background: var(--bg); }
        body { font: 15px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; color: var(--text); max-width: 760px; margin: 0 auto; padding: 32px 40px 80px; }
        h1, h2, h3, h4 { font-family: -apple-system, "SF Pro Display", sans-serif; line-height: 1.25; margin: 1.6em 0 .5em; }
        h1 { font-size: 30px; letter-spacing: -.02em; margin-top: .4em; } h2 { font-size: 22px; padding-bottom: .25em; border-bottom: 1px solid var(--line); } h3 { font-size: 18px; }
        a { color: var(--accent); text-decoration: none; } a:hover { text-decoration: underline; }
        code { font: 13px "SF Mono", ui-monospace, monospace; background: var(--soft); padding: .1em .35em; border-radius: 5px; }
        pre { background: var(--soft); padding: 14px 16px; border-radius: 10px; overflow-x: auto; } pre code { background: none; padding: 0; }
        blockquote { margin: 1em 0; padding: .4em 1em; border-left: 3px solid var(--accent); color: var(--muted); background: var(--soft); border-radius: 0 8px 8px 0; }
        blockquote.callout { color: var(--text); } blockquote p { margin: .4em 0; }
        table { border-collapse: collapse; margin: 1em 0; width: 100%; font-size: 14px; } th, td { border: 1px solid var(--line); padding: 6px 10px; text-align: left; } th { background: var(--soft); }
        table.frontmatter { font-size: 12.5px; color: var(--muted); width: auto; margin: 0 0 1.4em; border-collapse: separate; border-spacing: 0 2px; }
        table.frontmatter th, table.frontmatter td { border: none; background: none; padding: 1px 14px 1px 0; vertical-align: top; }
        table.frontmatter th { font-weight: 500; min-width: 90px; } table.frontmatter td { color: var(--text); }
        li.task { list-style: none; margin-left: -1.3em; } li.task.done { color: var(--muted); text-decoration: line-through; } input[type=checkbox] { margin-right: 6px; }
        hr { border: none; border-top: 1px solid var(--line); margin: 2em 0; } img { max-width: 100%; border-radius: 10px; }
        mark { background: var(--mark); color: inherit; padding: 0 .15em; border-radius: 3px; } .wikilink { color: var(--accent); }
        </style></head><body>
        \(html(from: markdown))
        </body></html>
        """
    }
}
