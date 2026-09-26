import AppKit
import SiriCore

/// Tra il documento di Pages (testo con attributi) e il motore (paragrafi con stile): lettura per il modello e
/// applicazione delle operazioni. I paragrafi che non cambiano restano identici, con immagini, link e formattazione.
@MainActor
enum DocumentBridge {
    /// Intervalli dei paragrafi (ognuno comprende il suo a capo).
    static func paragraphRanges(of text: NSAttributedString) -> [NSRange] {
        let string = text.string as NSString
        var ranges: [NSRange] = []
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(range)
            location = NSMaxRange(range)
        }
        return ranges
    }

    static func style(of font: NSFont?) -> DocumentOutline.Style {
        switch PagesStyle.detect(font) {
        case .title: .titolo
        case .subtitle: .sottotitolo
        case .heading1: .intestazione
        case .heading2: .sottointestazione
        case .caption: .didascalia
        case .body: .testo
        }
    }

    static func pagesStyle(_ style: DocumentOutline.Style) -> PagesStyle {
        switch style {
        case .titolo: .title
        case .sottotitolo: .subtitle
        case .intestazione: .heading1
        case .sottointestazione: .heading2
        case .didascalia: .caption
        case .testo: .body
        }
    }

    /// Il documento a paragrafi, con la selezione dell'editor se c'è.
    static func outline(of text: NSAttributedString, selection: NSRange? = nil) -> DocumentOutline {
        let ranges = paragraphRanges(of: text)
        let string = text.string as NSString
        let paragraphs = ranges.map { range -> DocumentOutline.Paragraph in
            let body = string.substring(with: range).trimmingCharacters(in: .newlines)
            let font = range.length > 0 ? text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont : nil
            return DocumentOutline.Paragraph(body, style(of: font))
        }
        var outline = DocumentOutline(paragraphs: paragraphs)
        if let selection, selection.location <= string.length {
            if selection.length > 0 {
                outline.selected = ranges.indices.filter { NSIntersectionRange(ranges[$0], selection).length > 0 }
                outline.selectedText = string.substring(with: selection)
            }
            outline.cursor = ranges.firstIndex { NSLocationInRange(selection.location, $0) } ?? (ranges.isEmpty ? nil : ranges.count - 1)
        }
        return outline
    }

    /// Nuovo testo con le operazioni applicate. `selection` serve alle operazioni sul testo selezionato.
    static func applying(_ operations: [DocumentOperation], to text: NSAttributedString, selection: NSRange?) -> NSAttributedString {
        // Tutto sostituito: paragrafi nuovi con gli stili di Pages.
        if let last = operations.last(where: { if case .replaceAll = $0 { true } else { false } }), case .replaceAll(let paragraphs) = last {
            let result = NSMutableAttributedString()
            for paragraph in paragraphs { result.append(pagesStyle(paragraph.style).paragraphText(paragraph.text)) }
            return result
        }
        // Operazioni sulla selezione: anche parti di un paragrafo.
        if let selection, selection.length > 0, NSMaxRange(selection) <= text.length {
            let result = NSMutableAttributedString(attributedString: text)
            for operation in operations {
                switch operation {
                case .replaceSelection(let replacement):
                    let attributes = text.attributes(at: selection.location, effectiveRange: nil)
                    result.replaceCharacters(in: selection, with: NSAttributedString(string: replacement, attributes: attributes))
                    return result
                case .deleteSelection:
                    result.deleteCharacters(in: selection)
                    return result
                case .formatSelection(let format):
                    apply(format, to: result, in: selection)
                    return result
                default: continue
                }
            }
        }
        let ranges = paragraphRanges(of: text)
        var replaced: [Int: String] = [:]
        var deleted = Set<Int>()
        var styles: [Int: DocumentOutline.Style] = [:]
        var formats: [Int: TextFormat] = [:]
        var inserted: [Int: [DocumentOutline.Paragraph]] = [:]
        for operation in operations {
            switch operation {
            case .replace(let index, let value): replaced[index] = value
            case .insert(let after, let items): inserted[after, default: []] += items
            case .delete(let indices): deleted.formUnion(indices)
            case .restyle(let indices, let style): for index in indices { styles[index] = style }
            case .format(let indices, let format): for index in indices { formats[index] = format }
            default: continue
            }
        }
        let result = NSMutableAttributedString()
        func appendNew(_ paragraph: DocumentOutline.Paragraph) {
            // Il paragrafo precedente deve finire con un a capo.
            if result.length > 0, !result.string.hasSuffix("\n") { result.append(NSAttributedString(string: "\n", attributes: PagesStyle.body.attributes)) }
            result.append(pagesStyle(paragraph.style).paragraphText(paragraph.text))
        }
        for paragraph in inserted[-1] ?? [] { appendNew(paragraph) }
        for (index, range) in ranges.enumerated() {
            if !deleted.contains(index) {
                if result.length > 0, !result.string.hasSuffix("\n") { result.append(NSAttributedString(string: "\n", attributes: PagesStyle.body.attributes)) }
                let start = result.length
                if let style = styles[index] {
                    let body = replaced[index] ?? (text.string as NSString).substring(with: range).trimmingCharacters(in: .newlines)
                    result.append(pagesStyle(style).paragraphText(body))
                } else if let body = replaced[index] {
                    // Testo nuovo con l'aspetto che aveva il paragrafo.
                    let attributes = range.length > 0 ? text.attributes(at: range.location, effectiveRange: nil) : PagesStyle.body.attributes
                    result.append(NSAttributedString(string: body + "\n", attributes: attributes))
                } else {
                    result.append(text.attributedSubstring(from: range))
                }
                if let format = formats[index] {
                    let length = result.length - start - (result.string.hasSuffix("\n") ? 1 : 0)
                    if length > 0 { apply(format, to: result, in: NSRange(location: start, length: length)) }
                }
            }
            for paragraph in inserted[index] ?? [] { appendNew(paragraph) }
        }
        return result
    }

    /// Grassetto, corsivo, sottolineato (o nessuno) su un intervallo, conservando i caratteri usati.
    static func apply(_ format: TextFormat, to text: NSMutableAttributedString, in range: NSRange) {
        let manager = NSFontManager.shared
        text.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? NSFont else { return }
            let converted: NSFont = switch format {
            case .grassetto: manager.convert(font, toHaveTrait: .boldFontMask)
            case .corsivo: manager.convert(font, toHaveTrait: .italicFontMask)
            case .normale: manager.convert(manager.convert(font, toNotHaveTrait: .boldFontMask), toNotHaveTrait: .italicFontMask)
            case .sottolineato: font
            }
            text.addAttribute(.font, value: converted, range: run)
        }
        if format == .sottolineato { text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        if format == .normale { text.removeAttribute(.underlineStyle, range: range) }
    }
}
