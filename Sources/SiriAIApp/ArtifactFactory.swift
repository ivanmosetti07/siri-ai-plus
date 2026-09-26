import AppKit
import SiriCore
import SwiftUI
import UniformTypeIdentifiers

/// Stili di paragrafo dell'editor Pages, condivisi da editor, generazione ed export.
enum PagesStyle: String, CaseIterable, Identifiable {
    case title, subtitle, heading1, heading2, body, caption

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: "Titolo"
        case .subtitle: "Sottotitolo"
        case .heading1: "Intestazione 1"
        case .heading2: "Intestazione 2"
        case .body: "Corpo"
        case .caption: "Didascalia"
        }
    }

    var font: NSFont {
        switch self {
        case .title: .systemFont(ofSize: 28, weight: .bold)
        case .subtitle: .systemFont(ofSize: 17, weight: .regular)
        case .heading1: .systemFont(ofSize: 20, weight: .semibold)
        case .heading2: .systemFont(ofSize: 16, weight: .semibold)
        case .body: Self.serif(14)
        case .caption: .systemFont(ofSize: 11, weight: .regular)
        }
    }

    var color: NSColor {
        switch self {
        case .subtitle, .caption: NSColor(white: 0.4, alpha: 1)
        default: NSColor(white: 0.1, alpha: 1)
        }
    }

    var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = self == .body ? 1.3 : 1.1
        style.paragraphSpacing = switch self {
        case .title: 4
        case .subtitle: 18
        case .heading1, .heading2: 6
        case .body: 10
        case .caption: 8
        }
        style.paragraphSpacingBefore = (self == .heading1 || self == .heading2) ? 10 : 0
        return style
    }

    var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    static func serif(_ size: CGFloat) -> NSFont {
        NSFontDescriptor.preferredFontDescriptor(forTextStyle: .body).withDesign(.serif)
            .flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
    }

    /// Riconosce lo stile di un paragrafo dal suo font, per mostrarlo nella toolbar.
    static func detect(_ font: NSFont?) -> PagesStyle {
        guard let font else { return .body }
        return allCases.first { abs($0.font.pointSize - font.pointSize) < 0.5 && $0.font.fontDescriptor.symbolicTraits == font.fontDescriptor.symbolicTraits } ?? .body
    }

    func paragraphText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text + "\n", attributes: attributes)
    }
}

/// Costruzione ed esportazione degli artefatti. I file finiscono nella cartella del progetto o in ~/Documents/Siri AI+.
@MainActor
enum ArtifactFactory {
    // MARK: Documento

    static func document(from draft: DocumentDraft) -> NSAttributedString {
        let result = NSMutableAttributedString()
        // Testo dettato dall'utente: così com'è, senza titolo né sezioni inventate.
        if let body = draft.body, draft.sections.isEmpty {
            for line in body.components(separatedBy: "\n") { result.append(PagesStyle.body.paragraphText(line)) }
            return result
        }
        result.append(PagesStyle.title.paragraphText(draft.title))
        if !draft.subtitle.isEmpty { result.append(PagesStyle.subtitle.paragraphText(draft.subtitle)) }
        for section in draft.sections {
            result.append(PagesStyle.heading1.paragraphText(section.title))
            result.append(PagesStyle.body.paragraphText(section.body))
        }
        return result
    }

    static func blankDocument(title: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(PagesStyle.title.paragraphText(title))
        result.append(PagesStyle.body.paragraphText(""))
        return result
    }

    static func imageAttachment(_ url: URL, width: CGFloat = 420) -> NSAttributedString? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let attachment = NSTextAttachment()
        let ratio = image.size.height / max(1, image.size.width)
        image.size = CGSize(width: width, height: width * ratio)
        attachment.image = image
        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(string: "\n", attributes: PagesStyle.body.attributes))
        return result
    }

    // MARK: Cartelle

    static var defaultFolder: URL {
        AppPaths.documents
    }

    static func safeName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return cleaned.isEmpty ? AppInfo.name : String(cleaned.prefix(80))
    }

    enum ExportFormat: String, CaseIterable, Identifiable {
        case docx, rtf, pdf, csv, txt
        var id: String { rawValue }
        var label: String {
            switch self {
            case .docx: "Word (.docx)"
            case .rtf: "RTF"
            case .pdf: "PDF"
            case .csv: "CSV"
            case .txt: "Testo semplice"
            }
        }
    }

    static func formats(for kind: ArtifactKind) -> [ExportFormat] {
        switch kind {
        case .pages: [.docx, .pdf, .rtf, .txt]
        case .numbers: [.csv]
        case .keynote: [.pdf]
        }
    }

    /// Scrive il file e restituisce l'URL.
    static func export(_ artifact: ArtifactModel, as format: ExportFormat, to url: URL? = nil, folder: URL? = nil, sheetIndex: Int = 0) throws -> URL {
        let destination = url ?? (folder ?? defaultFolder).appending(path: "\(safeName(artifact.title)).\(format.rawValue)")
        switch (artifact.content, format) {
        case (.document(let text), .docx), (.document(let text), .rtf):
            let type: NSAttributedString.DocumentType = format == .docx ? .officeOpenXML : .rtf
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
            try data.write(to: destination)
        case (.document(let text), .txt):
            try text.string.write(to: destination, atomically: true, encoding: .utf8)
        case (.document(let text), .pdf):
            try pdf(pages: paginate(text), to: destination)
        case (.sheet(let spreadsheet), _):
            let sheet = spreadsheet.sheets[min(max(0, sheetIndex), spreadsheet.sheets.count - 1)]
            try csv(sheet).data(using: .utf8)?.write(to: destination)
        case (.deck(let deck), _):
            try deckPDF(deck, to: destination)
        default:
            throw CocoaError(.fileWriteUnsupportedScheme)
        }
        artifact.exportedURL = destination
        artifact.lastExport = .now
        artifact.snapshot("Salvato come \(format.rawValue.uppercased())")
        return destination
    }

    /// Esporta nel formato più adatto e lo apre nell'app iWork (o nell'app predefinita).
    static func openInApp(_ artifact: ArtifactModel, folder: URL? = nil) async throws {
        if artifact.kind == .keynote, let deck = artifact.deck {
            do {
                try await buildKeynote(deck)
                artifact.lastExport = .now
                artifact.snapshot("Aperto in Keynote")
                return
            } catch {
                // Senza permesso di automazione: ripiega sul PDF.
            }
        }
        let format: ExportFormat = switch artifact.kind {
        case .pages: .docx
        case .numbers: .csv
        case .keynote: .pdf
        }
        let url = try export(artifact, as: format, folder: folder)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: artifact.kind.bundleID) {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Numbers

    static func csv(_ sheet: Sheet) -> String {
        func cell(_ s: String) -> String { s.contains(",") || s.contains("\"") || s.contains("\n") ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s }
        let usedRows = (sheet.cells.keys.compactMap { CellRef($0)?.row }.max() ?? -1) + 1
        let usedCols = (sheet.cells.keys.compactMap { CellRef($0)?.col }.max() ?? -1) + 1
        return (0..<usedRows).map { row in
            (0..<usedCols).map { col -> String in
                let value = sheet.value(CellRef(col: col, row: row))
                if case .number(let n) = value { return n.rounded() == n ? String(Int(n)) : String(n) }
                return cell(value.display)
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    // MARK: Keynote

    private static func buildKeynote(_ deck: Deck) async throws {
        func quote(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func body(_ slide: Slide) -> String {
            slide.bodyText.split(separator: "\n").map { $0.hasPrefix("• ") ? String($0.dropFirst(2)) : String($0) }.joined(separator: "\n")
        }
        var lines = ["tell application \"Keynote\"", "activate", "set doc to make new document", "tell doc"]
        for (index, slide) in deck.slides.enumerated() {
            lines.append(index == 0 ? "set s to slide 1" : "set s to make new slide at end of slides")
            lines += ["try", "set object text of default title item of s to \(quote(slide.title))", "end try",
                      "try", "set object text of default body item of s to \(quote(body(slide)))", "end try"]
        }
        lines += ["end tell", "end tell"]
        let source = lines.joined(separator: "\n")
        try await Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { throw NSError(domain: "Siri AI+.Keynote", code: 1, userInfo: error as? [String: Any]) }
        }.value
    }

    // MARK: PDF

    private static func paginate(_ text: NSAttributedString) -> [NSImage] {
        let pageSize = CGSize(width: 595, height: 842)
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: CGSize(width: pageSize.width - 144, height: pageSize.height - 144))
            layout.addTextContainer(container)
            containers.append(container)
        } while layout.glyphRange(for: containers.last!).upperBound < layout.numberOfGlyphs && containers.count < 80
        return containers.map { container in
            NSImage(size: pageSize, flipped: true) { _ in
                NSColor.white.setFill()
                CGRect(origin: .zero, size: pageSize).fill()
                layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: CGPoint(x: 72, y: 72))
                return true
            }
        }
    }

    private static func pdf(pages: [NSImage], to url: URL) throws {
        guard let first = pages.first else { return }
        var box = CGRect(origin: .zero, size: first.size)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for page in pages {
            context.beginPDFPage(nil)
            if let cg = page.cgImage(forProposedRect: nil, context: nil, hints: nil) { context.draw(cg, in: box) }
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func deckPDF(_ deck: Deck, to url: URL) throws {
        let images = deck.slides.compactMap { slide -> NSImage? in
            let renderer = ImageRenderer(content: SlideCanvas(slide: slide, theme: deck.theme).frame(width: 1280, height: 720))
            renderer.scale = 1
            return renderer.nsImage
        }
        try pdf(pages: images, to: url)
    }
}
