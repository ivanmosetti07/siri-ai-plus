import Foundation

/// Una fonte trovata sul web.
public struct WebSource: Codable, Sendable, Equatable, Identifiable {
    public var id: String { url }
    public var title: String
    public var url: String
    public var snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title; self.url = url; self.snippet = snippet
    }

    public var domain: String {
        (URL(string: url)?.host() ?? url).replacingOccurrences(of: "www.", with: "")
    }
}

/// Esito di una ricerca o della lettura di una pagina, mostrato in una scheda con le fonti.
public struct WebAnswer: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case search, page }
    public var kind: Kind
    public var query: String
    public var sources: [WebSource]

    public init(kind: Kind, query: String, sources: [WebSource]) {
        self.kind = kind; self.query = query; self.sources = sources
    }
}

public enum WebError: LocalizedError {
    case offline, nothing, blocked, http(Int)

    public var errorDescription: String? {
        switch self {
        case .offline: "Non riesco a raggiungere il web: controlla la connessione."
        case .nothing: "La ricerca non ha dato risultati."
        case .blocked: "Il motore di ricerca ha rifiutato la richiesta: riprova tra poco."
        case .http(let code): "Il sito ha risposto con errore \(code)."
        }
    }
}

/// Ricerca sul web (DuckDuckGo, senza chiavi né account) e lettura del testo delle pagine.
public enum Web {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: configuration)
    }()

    /// Lingua preferita per le pagine e i risultati: quella della richiesta in corso.
    static var acceptLanguage: String { Language.isEnglish ? "en-US,en;q=0.9,it;q=0.6" : "it-IT,it;q=0.9,en;q=0.7" }

    // MARK: Ricerca

    /// DuckDuckGo, con un secondo tentativo e Bing come riserva (DuckDuckGo a volte risponde vuoto a ricerche ravvicinate).
    public static func search(_ query: String, limit: Int = 6) async throws -> [WebSource] {
        if let world = FixtureWorld.active, !world.realWeb { return world.webSearch(query, limit: limit) }
        var lastError: Error = WebError.nothing
        for attempt in 0..<2 {
            do {
                return Array(try await searchDuckDuckGo(query).prefix(limit))
            } catch WebError.offline {
                throw WebError.offline
            } catch {
                lastError = error
                if attempt == 0 { try? await Task.sleep(for: .milliseconds(700)) }
            }
        }
        if let results = try? await searchBing(query), !results.isEmpty { return Array(results.prefix(limit)) }
        throw lastError
    }

    private static func searchDuckDuckGo(_ query: String) async throws -> [WebSource] {
        var request = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "kl", value: Language.isEnglish ? "us-en" : "it-it")]
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw WebError.offline }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let html = String(decoding: data, as: UTF8.self)
        if code == 202 || html.contains("anomaly-modal") { throw WebError.blocked }
        guard code == 200 else { throw WebError.http(code) }
        let results = parseDuckDuckGo(html)
        guard !results.isEmpty else { throw WebError.nothing }
        return results
    }

    private static func searchBing(_ query: String) async throws -> [WebSource] {
        var components = URLComponents(string: "https://www.bing.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "setlang", value: Language.isEnglish ? "en" : "it"), URLQueryItem(name: "cc", value: Language.isEnglish ? "us" : "it")]
        var request = URLRequest(url: components.url!)
        request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WebError.nothing }
        return parseBing(String(decoding: data, as: UTF8.self))
    }

    static func parseBing(_ html: String) -> [WebSource] {
        var seen = Set<String>()
        return matches(#"<li class="b_algo"(.*?)</li>"#, in: html).compactMap { groups in
            let block = groups[0]
            guard let link = matches(#"<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: block).first else { return nil }
            var url = decodeEntities(link[0])
            // Link di tracciamento `bing.com/ck/a?…&u=a1<base64url>`.
            if url.contains("bing.com/ck/"), let encoded = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "u" })?.value,
               encoded.hasPrefix("a1") {
                var base64 = String(encoded.dropFirst(2)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while base64.count % 4 != 0 { base64 += "=" }
                if let data = Data(base64Encoded: base64), let decoded = String(data: data, encoding: .utf8) { url = decoded }
            }
            guard url.hasPrefix("http"), !url.contains("bing.com/"), seen.insert(url).inserted else { return nil }
            let snippet = matches(#"<p[^>]*>(.*?)</p>"#, in: block).first.map { plain($0[0]) } ?? ""
            return WebSource(title: plain(link[1]), url: url, snippet: snippet)
        }
    }

    static func parseDuckDuckGo(_ html: String) -> [WebSource] {
        let titles = matches(#"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: html)
        let snippets = matches(#"class="result__snippet"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: html)
        var snippetByURL: [String: String] = [:]
        for groups in snippets { snippetByURL[resolve(groups[0])] = plain(groups[1]) }
        var seen = Set<String>()
        return titles.compactMap { groups in
            let url = resolve(groups[0])
            // Annunci e link interni del motore di ricerca.
            guard url.hasPrefix("http"), !url.contains("duckduckgo.com/y.js"), seen.insert(url).inserted else { return nil }
            return WebSource(title: plain(groups[1]), url: url, snippet: snippetByURL[url] ?? "")
        }
    }

    /// I link di DuckDuckGo a volte passano da un redirect `/l/?uddg=…`.
    private static func resolve(_ href: String) -> String {
        let decoded = decodeEntities(href)
        if decoded.contains("uddg="), let components = URLComponents(string: decoded.hasPrefix("//") ? "https:" + decoded : decoded),
           let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return target
        }
        return decoded.hasPrefix("//") ? "https:" + decoded : decoded
    }

    // MARK: Pagine

    public struct Page: Sendable {
        public let url: String
        public let title: String
        public let text: String
    }

    /// Scarica una pagina e ne estrae il testo leggibile (articolo o contenuto principale).
    public static func fetch(_ url: URL, maxChars: Int = 12_000) async throws -> Page {
        if let world = FixtureWorld.active, !world.realWeb { return world.webFetch(url) }
        let data: Data
        let response: URLResponse
        var request = URLRequest(url: url)
        request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        do { (data, response) = try await session.data(for: request) } catch { throw WebError.offline }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<400).contains(code) else { throw WebError.http(code) }
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let html = String(decoding: data, as: UTF8.self)
        if type.contains("text/plain") || type.contains("json") {
            return Page(url: url.absoluteString, title: url.lastPathComponent, text: String(html.prefix(maxChars)))
        }
        return Page(url: (response.url ?? url).absoluteString, title: title(of: html) ?? url.host() ?? "",
                    text: String(readableText(html).prefix(maxChars)))
    }

    static func title(of html: String) -> String? {
        let og = matches(#"<meta[^>]+property="og:title"[^>]+content="([^"]*)""#, in: html).first?.first
        let tag = matches(#"<title[^>]*>(.*?)</title>"#, in: html).first?.first
        return (og ?? tag).map(plain).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Testo principale: toglie script, menu e piè di pagina, preferisce `<article>` o `<main>` e i paragrafi.
    public static func readableText(_ html: String) -> String {
        var body = html
        for tag in ["script", "style", "noscript", "svg", "nav", "header", "footer", "aside", "form", "iframe", "template"] {
            body = body.replacingOccurrences(of: "<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        body = body.replacingOccurrences(of: "<!--.*?-->", with: " ", options: .regularExpression)
        for container in ["article", "main"] {
            if let inner = matches("<\(container)\\b[^>]*>(.*)</\(container)>", in: body).first?.first, inner.count > 800 {
                body = inner
                break
            }
        }
        let blocks = matches(#"<(p|h[1-4]|li|td|blockquote|pre)\b[^>]*>(.*?)</\1>"#, in: body)
            .map { plain($0[1]) }
            .filter { $0.count > 25 || $0.hasSuffix(":") }
        if blocks.joined().count > 400 { return blocks.joined(separator: "\n") }
        return plain(body.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6])[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive]))
    }

    /// I passaggi più pertinenti alla domanda, entro un budget di caratteri.
    public static func relevantPassages(_ text: String, query: String, budget: Int) -> String {
        guard text.count > budget else { return text }
        let words = Set(MemoryStore.keywords(query))
        let paragraphs = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 30 }
        let scored = paragraphs.enumerated().map { index, paragraph -> (Int, Int, String) in
            let hits = Set(MemoryStore.keywords(paragraph)).intersection(words).count
            return (index, hits * 10 - index / 8, paragraph)
        }
        var chosen: [(Int, String)] = []
        var used = 0
        // Il primo paragrafo spesso riassume la pagina.
        for (index, _, paragraph) in [scored.first].compactMap({ $0 }) + scored.dropFirst().sorted(by: { $0.1 > $1.1 }) {
            let piece = Self.clip(paragraph, 600)
            guard used + piece.count <= budget else { continue }
            chosen.append((index, piece))
            used += piece.count
        }
        return chosen.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
    }

    /// Taglia un testo al limite, preferibilmente alla fine di una frase.
    static func clip(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let end = head.range(of: #"[.!?…](?=\s|$)"#, options: [.regularExpression, .backwards]), head.distance(from: head.startIndex, to: end.upperBound) > limit / 2 {
            return String(head[..<end.upperBound])
        }
        return head + "…"
    }

    // MARK: HTML

    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).map { i in
                let range = match.range(at: i)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }

    /// Testo senza tag, con entità decodificate e spazi compattati.
    static func plain(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeEntities(stripped)
            .replacingOccurrences(of: "[ \\t\\x{00A0}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: " ([,.;:!?])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        // "&amp;" per ultimo: "&amp;lt;" deve restare il testo "&lt;", non diventare "<".
        let named = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
                     "&egrave;": "è", "&eacute;": "é", "&agrave;": "à", "&ograve;": "ò", "&ugrave;": "ù", "&igrave;": "ì",
                     "&laquo;": "«", "&raquo;": "»", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”",
                     "&hellip;": "…", "&ndash;": "–", "&mdash;": "—", "&euro;": "€", "&deg;": "°", "&middot;": "·"]
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        for groups in matches("&#(x?[0-9a-fA-F]+);", in: result) {
            let code = groups[0]
            let value = code.hasPrefix("x") || code.hasPrefix("X") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            if let value, let scalar = Unicode.Scalar(value) { result = result.replacingOccurrences(of: "&#\(code);", with: String(Character(scalar))) }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Primo indirizzo web presente in un testo.
    public static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
            .first { $0.scheme == "http" || $0.scheme == "https" }
    }
}

/// Pagina aperta in Safari, letta con AppleScript (serve il permesso di automazione la prima volta).
@MainActor
public enum SafariBridge {
    public struct Tab: Sendable { public let title: String; public let url: String }

    public static func currentTab() -> Tab? {
        let source = """
        if application "Safari" is running then
            tell application "Safari"
                if (count of windows) > 0 then return (name of current tab of front window) & linefeed & (URL of current tab of front window)
            end tell
        end if
        return ""
        """
        var error: NSDictionary?
        guard let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue, !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: "\n")
        guard parts.count >= 2, parts[1].hasPrefix("http") else { return nil }
        return Tab(title: parts[0], url: parts[1])
    }
}
