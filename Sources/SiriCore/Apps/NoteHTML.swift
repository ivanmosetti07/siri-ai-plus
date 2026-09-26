import AppKit
import Foundation

/// Testo formattato ↔ HTML di Note. Si modificano titoli, intestazioni, grassetto, corsivo, sottolineato, barrato e link;
/// le note con liste, tabelle o allegati non passano da qui (Note li perderebbe).
public enum NoteHTML {
    public enum Level: Int, CaseIterable, Sendable {
        case body = 0, title = 1, heading = 2, subheading = 3

        public var label: String {
            switch self {
            case .title: Language.t("Titolo", "Title")
            case .heading: Language.t("Intestazione", "Heading")
            case .subheading: Language.t("Sottointestazione", "Subheading")
            case .body: Language.t("Corpo", "Body")
            }
        }

        public var size: CGFloat {
            switch self {
            case .title: 26
            case .heading: 20
            case .subheading: 16.5
            case .body: 14
            }
        }

        public var weight: NSFont.Weight { self == .body ? .regular : .bold }

        /// Livello di un paragrafo dalla dimensione del carattere (quella usata qui sopra).
        public init(size: CGFloat) {
            switch size {
            case 23...: self = .title
            case 18.5...: self = .heading
            case 15.5...: self = .subheading
            default: self = .body
            }
        }
    }

    // MARK: HTML → testo

    /// Testo formattato con i caratteri di sistema: i titoli di Note diventano i livelli qui sopra.
    @MainActor public static func attributed(from html: String) -> NSAttributedString {
        // Le note semplici prodotte dall'app devono conservare esattamente righe e spazi. L'importatore
        // HTML di WebKit aggiunge paragrafi differenti a seconda della versione di macOS.
        if let exact = NoteHTMLReader.read(html) { return exact }
        let data = Data(("<meta charset=\"utf-8\">" + html).utf8)
        guard let imported = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                           .characterEncoding: String.Encoding.utf8.rawValue],
                                                     documentAttributes: nil) else {
            return NSAttributedString(string: html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression),
                                      attributes: attributes(level: .body))
        }
        let result = NSMutableAttributedString()
        let text = imported.string as NSString
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { _, range, enclosing, _ in
            // Livello dal carattere più grande del paragrafo (WebKit: h1 24 pt, h2 18 pt, h3 14 pt in grassetto, testo 12 pt).
            var largest: CGFloat = 0
            var allBold = range.length > 0
            imported.enumerateAttribute(.font, in: range) { value, _, _ in
                guard let font = value as? NSFont else { return }
                largest = max(largest, font.pointSize)
                if !font.fontDescriptor.symbolicTraits.contains(.bold) { allBold = false }
            }
            let level: Level = largest >= 20 ? .title : largest >= 16 ? .heading : (largest >= 13.5 && allBold) ? .subheading : .body
            let paragraph = NSMutableAttributedString(attributedString: imported.attributedSubstring(from: range))
            restyle(paragraph, level: level)
            result.append(paragraph)
            if enclosing.length > range.length { result.append(NSAttributedString(string: "\n", attributes: attributes(level: level))) }
        }
        // WebKit aggiunge un a capo finale.
        while result.string.hasSuffix("\n") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }

    /// Come la mostra Note (liste e tabelle comprese), solo da leggere: caratteri un po' più grandi e colori di sistema.
    @MainActor public static func preview(from html: String) -> NSAttributedString {
        let data = Data(("<meta charset=\"utf-8\">" + html).utf8)
        guard let imported = try? NSMutableAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                                  .characterEncoding: String.Encoding.utf8.rawValue],
                                                            documentAttributes: nil) else {
            return NSAttributedString(string: html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        }
        let full = NSRange(location: 0, length: imported.length)
        var fonts: [(NSRange, NSFont)] = []
        imported.enumerateAttribute(.font, in: full) { value, range, _ in
            let font = value as? NSFont ?? .systemFont(ofSize: 12)
            let traits = font.fontDescriptor.symbolicTraits
            var scaled = NSFont.systemFont(ofSize: font.pointSize * 1.16, weight: traits.contains(.bold) ? .bold : .regular)
            if traits.contains(.italic) { scaled = NSFontManager.shared.convert(scaled, toHaveTrait: .italicFontMask) }
            fonts.append((range, scaled))
        }
        for (range, font) in fonts { imported.addAttribute(.font, value: font, range: range) }
        imported.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        return imported
    }

    /// Attributi di base per un livello (i nuovi testi scritti nell'editor).
    public static func attributes(level: Level) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = level == .body ? 2 : 6
        style.lineHeightMultiple = 1.12
        return [.font: NSFont.systemFont(ofSize: level.size, weight: level.weight), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
    }

    /// Caratteri di sistema al posto di quelli di WebKit, tenendo grassetto e corsivo delle singole parole.
    static func restyle(_ paragraph: NSMutableAttributedString, level: Level) {
        let full = NSRange(location: 0, length: paragraph.length)
        var fonts: [(NSRange, NSFont)] = []
        paragraph.enumerateAttribute(.font, in: full) { value, range, _ in
            let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var font = NSFont.systemFont(ofSize: level.size, weight: level == .body && !traits.contains(.bold) ? .regular : .bold)
            if traits.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if traits.contains(.monoSpace) { font = NSFont.monospacedSystemFont(ofSize: level.size - 1, weight: .regular) }
            fonts.append((range, font))
        }
        let base = attributes(level: level)
        paragraph.addAttribute(.paragraphStyle, value: base[.paragraphStyle]!, range: full)
        paragraph.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        paragraph.removeAttribute(.backgroundColor, range: full)
        for (range, font) in fonts { paragraph.addAttribute(.font, value: font, range: range) }
    }

    // MARK: Testo → HTML

    /// HTML come lo scrive Note: un `<div>` per paragrafo, `<h1>`–`<h3>` per titoli e intestazioni.
    public static func html(from text: NSAttributedString) -> String {
        var html = ""
        let string = text.string as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0 else { html += "<div><br></div>"; return }
            var largest: CGFloat = 0
            text.enumerateAttribute(.font, in: range) { value, _, _ in largest = max(largest, (value as? NSFont)?.pointSize ?? 0) }
            let level = Level(size: largest)
            var inner = ""
            text.enumerateAttributes(in: range) { attributes, run, _ in
                var piece = escape(string.substring(with: run))
                let font = attributes[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                if traits.contains(.monoSpace) { piece = "<tt>\(piece)</tt>" }
                if traits.contains(.italic) { piece = "<i>\(piece)</i>" }
                // Nei titoli il grassetto è quello del titolo stesso.
                if level == .body, traits.contains(.bold) { piece = "<b>\(piece)</b>" }
                if let underline = attributes[.underlineStyle] as? Int, underline != 0, attributes[.link] == nil { piece = "<u>\(piece)</u>" }
                if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { piece = "<strike>\(piece)</strike>" }
                if let link = attributes[.link] {
                    let target = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                    if !target.isEmpty { piece = "<a href=\"\(escape(target))\">\(piece)</a>" }
                }
                inner += piece
            }
            switch level {
            case .title: html += "<div><h1>\(inner)</h1></div>"
            case .heading: html += "<div><h2>\(inner)</h2></div>"
            case .subheading: html += "<div><h3>\(inner)</h3></div>"
            case .body: html += "<div>\(inner)</div>"
            }
        }
        return html
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Lettore deterministico per il sottoinsieme di HTML che Siri AI+ sa riscrivere senza perdere struttura.
private final class NoteHTMLReader: NSObject, XMLParserDelegate {
    private struct Style {
        var level = NoteHTML.Level.body
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var link: String?
    }

    private var style = Style()
    private var stack: [Style] = []
    private var current: NSMutableAttributedString?
    private var paragraphs: [NSAttributedString] = []
    private var unsupported = false

    static func read(_ html: String) -> NSAttributedString? {
        guard html.range(of: #"(?i)<div(?:\s|>)"#, options: .regularExpression) != nil else { return nil }
        let normalized = html.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "<br/>", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: "&#160;")
        let reader = NoteHTMLReader()
        let parser = XMLParser(data: Data(("<root>" + normalized + "</root>").utf8))
        parser.delegate = reader
        guard parser.parse(), !reader.unsupported, !reader.paragraphs.isEmpty else { return nil }
        let result = NSMutableAttributedString()
        for (index, paragraph) in reader.paragraphs.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: NoteHTML.attributes(level: .body))) }
            result.append(paragraph)
        }
        return result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let tag = elementName.lowercased()
        guard ["root", "div", "h1", "h2", "h3", "b", "strong", "i", "em", "u", "strike", "s", "a", "br"].contains(tag) else {
            unsupported = true; parser.abortParsing(); return
        }
        stack.append(style)
        switch tag {
        case "div": current = NSMutableAttributedString()
        case "h1": style.level = .title
        case "h2": style.level = .heading
        case "h3": style.level = .subheading
        case "b", "strong": style.bold = true
        case "i", "em": style.italic = true
        case "u": style.underline = true
        case "strike", "s": style.strike = true
        case "a": style.link = attributeDict["href"]
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased() == "div", let current {
            paragraphs.append(current)
            self.current = nil
        }
        if let previous = stack.popLast() { style = previous }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let current, !string.isEmpty else { return }
        var attributes = NoteHTML.attributes(level: style.level)
        var font = NSFont.systemFont(ofSize: style.level.size,
                                     weight: style.level == .body && !style.bold ? .regular : .bold)
        if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        attributes[.font] = font
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = style.link { attributes[.link] = link }
        current.append(NSAttributedString(string: string, attributes: attributes))
    }
}
