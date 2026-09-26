import Foundation
import FoundationModels

/// Sito generato: cartella con index.html e style.css.
public struct WebsiteDraft: Codable, Sendable, Equatable {
    public var title: String
    public var folder: String
    public var files: [String: String]

    public init(title: String, folder: String, files: [String: String]) {
        self.title = title; self.folder = folder; self.files = files
    }
}

extension Assistant {
    private static let websiteSchema = makeSchema("PaginaWeb", [
        .required("titolo", .string, "Nome del sito o titolo principale, breve"),
        .required("sottotitolo", .string, "Frase che spiega in una riga di cosa si tratta"),
        .required("pulsante", .string, "Testo del pulsante principale, 1-3 parole (es. «Scopri di più», «Prenota»)"),
        .required("caratteristiche", .array(.object("Caratteristica", [
            .required("icona", .string, "Una sola emoji adatta"),
            .required("titolo", .string, "Titolo breve"),
            .required("testo", .string, "Una o due frasi"),
        ]), min: 3, max: 6), "Punti di forza o servizi"),
        .required("sezioni", .array(.object("Sezione", [
            .required("titolo", .string, "Titolo della sezione"),
            .required("testo", .string, "Paragrafo di 2-4 frasi"),
            .optional("punti", .array(.string, max: 5), "Elenco facoltativo di punti brevi"),
        ]), min: 1, max: 4), "Sezioni di contenuto"),
        .required("invito", .string, "Frase finale che invita all'azione"),
        .required("tema", .choice(["chiaro", "scuro"]), "Tema dei colori"),
        .required("colore", .choice(["blu", "viola", "verde", "arancio", "rosa", "grafite"]), "Colore principale adatto all'argomento"),
    ])

    /// Pagina web completa (index.html + style.css) sull'argomento richiesto.
    public func generateWebsite(topic: String) async throws -> WebsiteDraft {
        let role = "Sei un copywriter e web designer: scrivi i contenuti di una pagina web moderna, concreta e persuasiva, in italiano."
        let request = "Crea una pagina web per: \(topic)"
        var title: String, subtitle: String, button: String, closing: String, dark: Bool, accent: String
        var features: [(icon: String, title: String, text: String)]
        var sections: [(title: String, text: String, points: [String])]
        if let json = await composeJSON(role, request, fields: """
            "titolo": nome del sito, breve; "sottotitolo": una riga che spiega di cosa si tratta; "pulsante": testo del pulsante principale (1-3 parole); \
            "caratteristiche": da 3 a 6 oggetti {"icona": una emoji, "titolo": breve, "testo": una o due frasi}; \
            "sezioni": da 1 a 4 oggetti {"titolo", "testo": 2-4 frasi, "punti": elenco facoltativo}; "invito": frase finale che invita all'azione; \
            "tema": "chiaro" o "scuro"; "colore": uno fra blu, viola, verde, arancio, rosa, grafite
            """), json.text("titolo") != nil, !json.objects("caratteristiche").isEmpty {
            title = json.text("titolo") ?? "Il mio sito"
            subtitle = json.text("sottotitolo") ?? ""
            button = json.text("pulsante") ?? "Scopri di più"
            closing = json.text("invito") ?? ""
            dark = json.text("tema") == "scuro"
            accent = ["blu", "viola", "verde", "arancio", "rosa", "grafite"].first { $0 == json.text("colore") } ?? "blu"
            features = json.objects("caratteristiche").map { (icon: $0.text("icona") ?? "✨", title: $0.text("titolo") ?? "", text: $0.text("testo") ?? "") }
            sections = json.objects("sezioni").map { (title: $0.text("titolo") ?? "", text: $0.text("testo") ?? "", points: $0.texts("punti")) }
        } else {
            let content = try await writer(role).respond(to: request, schema: Self.websiteSchema).content
            title = content.string("titolo") ?? "Il mio sito"
            subtitle = content.string("sottotitolo") ?? ""
            button = content.string("pulsante") ?? "Scopri di più"
            closing = content.string("invito") ?? ""
            dark = content.string("tema") == "scuro"
            accent = content.string("colore") ?? "blu"
            features = content.objects("caratteristiche").map { (icon: $0.string("icona") ?? "✨", title: $0.string("titolo") ?? "", text: $0.string("testo") ?? "") }
            sections = content.objects("sezioni").map { (title: $0.string("titolo") ?? "", text: $0.string("testo") ?? "", points: $0.strings("punti")) }
        }
        let html = WebsiteTemplate.html(title: title, subtitle: subtitle, button: button, features: features, sections: sections, closing: closing)
        let css = WebsiteTemplate.css(dark: dark, accent: accent)
        let slug = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return WebsiteDraft(title: title, folder: "sito-" + (slug.isEmpty ? "nuovo" : String(slug.prefix(30))), files: ["index.html": html, "style.css": css])
    }
}

/// Modello HTML/CSS curato: responsive, accessibile, tema chiaro o scuro.
public enum WebsiteTemplate {
    static func html(title: String, subtitle: String, button: String, features: [(icon: String, title: String, text: String)],
                     sections: [(title: String, text: String, points: [String])], closing: String) -> String {
        let e = Markdown.escape
        let featureCards = features.map { """
                <article class="card">
                    <div class="icon" aria-hidden="true">\(e($0.icon))</div>
                    <h3>\(e($0.title))</h3>
                    <p>\(e($0.text))</p>
                </article>
        """ }.joined(separator: "\n")
        let sectionBlocks = sections.enumerated().map { index, section in
            let points = section.points.isEmpty ? "" : "\n            <ul>\n" + section.points.map { "                <li>\(e($0))</li>" }.joined(separator: "\n") + "\n            </ul>"
            return """
                <section class="content\(index % 2 == 1 ? " alt" : "")" id="sezione-\(index + 1)">
                    <div class="wrap">
                        <h2>\(e(section.title))</h2>
                        <p>\(e(section.text))</p>\(points)
                    </div>
                </section>
            """
        }.joined(separator: "\n")
        let nav = sections.enumerated().map { "<a href=\"#sezione-\($0.offset + 1)\">\(e($0.element.title))</a>" }.prefix(4).joined(separator: "\n                ")
        return """
        <!doctype html>
        <html lang="it">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(e(title))</title>
            <meta name="description" content="\(e(subtitle))">
            <link rel="stylesheet" href="style.css">
        </head>
        <body>
            <header class="nav">
                <div class="wrap nav-inner">
                    <a class="brand" href="#">\(e(title))</a>
                    <nav>
                        \(nav)
                    </nav>
                </div>
            </header>

            <main>
                <section class="hero">
                    <div class="wrap">
                        <h1>\(e(title))</h1>
                        <p class="lead">\(e(subtitle))</p>
                        <a class="button" href="#contatti">\(e(button))</a>
                    </div>
                </section>

                <section class="features">
                    <div class="wrap grid">
        \(featureCards)
                    </div>
                </section>

        \(sectionBlocks)

                <section class="cta" id="contatti">
                    <div class="wrap">
                        <h2>\(e(closing))</h2>
                        <a class="button" href="mailto:">\(e(button))</a>
                    </div>
                </section>
            </main>

            <footer>
                <div class="wrap">© \(Calendar.current.component(.year, from: .now)) \(e(title))</div>
            </footer>
        </body>
        </html>
        """
    }

    static func css(dark: Bool, accent: String) -> String {
        let colors: [String: (String, String)] = [
            "blu": ("#0071e3", "#2997ff"), "viola": ("#7d3cff", "#a77bff"), "verde": ("#1f9d55", "#34c77b"),
            "arancio": ("#f56300", "#ff8a3d"), "rosa": ("#e3346f", "#ff5c93"), "grafite": ("#3a3a3c", "#8e8e93"),
        ]
        let (accentLight, accentDark) = colors[accent] ?? colors["blu"]!
        return """
        /* Colori: modifica qui per cambiare l'aspetto del sito. */
        :root {
            --accent: \(dark ? accentDark : accentLight);
            --bg: \(dark ? "#0b0b0c" : "#ffffff");
            --surface: \(dark ? "#161618" : "#f5f5f7");
            --text: \(dark ? "#f5f5f7" : "#1d1d1f");
            --muted: \(dark ? "#a1a1a6" : "#6e6e73");
            --line: \(dark ? "#2c2c2e" : "#d2d2d7");
            --radius: 18px;
            --max: 1080px;
        }

        * { box-sizing: border-box; }
        html { scroll-behavior: smooth; }
        body {
            margin: 0;
            background: var(--bg);
            color: var(--text);
            font: 17px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
            -webkit-font-smoothing: antialiased;
        }
        .wrap { max-width: var(--max); margin: 0 auto; padding: 0 24px; }
        a { color: var(--accent); text-decoration: none; }

        /* Barra di navigazione */
        .nav { position: sticky; top: 0; z-index: 10; backdrop-filter: saturate(180%) blur(20px); background: color-mix(in srgb, var(--bg) 78%, transparent); border-bottom: 1px solid var(--line); }
        .nav-inner { display: flex; align-items: center; justify-content: space-between; height: 56px; }
        .brand { color: var(--text); font-weight: 600; letter-spacing: -.01em; }
        .nav nav { display: flex; gap: 22px; }
        .nav nav a { color: var(--muted); font-size: 14px; }
        .nav nav a:hover { color: var(--text); }

        /* Apertura */
        .hero { padding: 120px 0 90px; text-align: center; }
        .hero h1 { font-size: clamp(40px, 7vw, 76px); line-height: 1.05; letter-spacing: -.035em; margin: 0 0 18px; }
        .lead { font-size: clamp(19px, 2.4vw, 24px); color: var(--muted); max-width: 680px; margin: 0 auto 34px; }
        .button { display: inline-block; background: var(--accent); color: #fff; padding: 13px 26px; border-radius: 980px; font-weight: 600; transition: transform .15s ease, opacity .15s ease; }
        .button:hover { transform: translateY(-1px); opacity: .92; }

        /* Punti di forza */
        .features { padding: 20px 0 80px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 20px; }
        .card { background: var(--surface); border-radius: var(--radius); padding: 28px; border: 1px solid var(--line); }
        .card .icon { font-size: 30px; margin-bottom: 10px; }
        .card h3 { margin: 0 0 8px; font-size: 20px; letter-spacing: -.01em; }
        .card p { margin: 0; color: var(--muted); }

        /* Sezioni */
        .content { padding: 90px 0; }
        .content.alt { background: var(--surface); }
        .content h2 { font-size: clamp(30px, 4vw, 44px); letter-spacing: -.025em; margin: 0 0 16px; max-width: 760px; }
        .content p { font-size: 19px; color: var(--muted); max-width: 760px; }
        .content ul { padding-left: 1.2em; max-width: 760px; }
        .content li { margin: 6px 0; }

        /* Chiusura */
        .cta { padding: 110px 0; text-align: center; }
        .cta h2 { font-size: clamp(28px, 4vw, 42px); letter-spacing: -.025em; max-width: 760px; margin: 0 auto 28px; }

        footer { border-top: 1px solid var(--line); padding: 28px 0; color: var(--muted); font-size: 13px; }

        @media (max-width: 700px) {
            .nav nav { display: none; }
            .hero { padding: 80px 0 60px; }
            .content, .cta { padding: 64px 0; }
        }
        """
    }
}
