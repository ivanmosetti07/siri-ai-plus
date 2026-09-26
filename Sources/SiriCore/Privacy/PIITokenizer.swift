import Foundation

// MARK: - Tokenizer di rizzo-pii (quello di Gemma, 256.000 voci)
//
// Stessi passaggi di `tokenizers` di Hugging Face con il tokenizer.json del modello:
// 1. i token aggiunti (a-capo ripetuti, «<bos>», «<unusedN>»…) si riconoscono sul testo grezzo, prima di tutto;
// 2. il resto: spazi → «▁», un «▁» davanti a ogni pezzo (Metaspace, «always»), divisione a ogni «▁»;
// 3. BPE con le fusioni in ordine di rango; un carattere fuori vocabolario diventa i suoi byte («<0xE2>»…);
// 4. «<bos>» … «<eos>» ai bordi.
// Ogni token porta le posizioni (in code point) del testo originale, per riportare le etichette sui caratteri.

final class PIITokenizer: @unchecked Sendable {
    struct Token: Equatable {
        let id: Int32
        let start: Int
        let end: Int
        let special: Bool
    }

    private struct Added {
        let scalars: [Unicode.Scalar]
        let id: Int32
        let special: Bool
    }

    /// Chiavi in byte UTF-8 esatti: per le stringhe di Swift «;» (U+003B) e «;» (U+037E, punto interrogativo greco)
    /// sono uguali, come «é» composta e scomposta, ma nel vocabolario sono token diversi.
    private let vocab: [[UInt8]: Int32]
    /// I token di un carattere solo, per carattere.
    private let charIDs: [UInt32: Int32]
    /// Coppia di id → (rango, id della fusione).
    private let merges: [UInt64: (rank: Int32, id: Int32)]
    private let byteIDs: [Int32]
    /// Token aggiunti per primo carattere, dal più lungo.
    private let added: [Unicode.Scalar: [Added]]
    let bos: Int32
    let eos: Int32
    private let unk: Int32
    private var cache: [[Unicode.Scalar]: [(id: Int32, first: Int, last: Int)]] = [:]
    private let lock = NSLock()

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let model = json["model"] as? NSDictionary,
              let rawVocab = model["vocab"] as? NSDictionary,
              let rawMerges = model["merges"] as? NSArray else {
            throw PrivacyError.failed("tokenizer.json non leggibile")
        }
        func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
        var vocab: [[UInt8]: Int32] = [:]
        vocab.reserveCapacity(rawVocab.count)
        var charIDs: [UInt32: Int32] = [:]
        // NSDictionary confronta le chiavi alla lettera: i token «uguali» per Swift restano distinti.
        for case let (token as String, id as NSNumber) in rawVocab {
            vocab[bytes(token)] = id.int32Value
            let scalars = token.unicodeScalars
            if scalars.count == 1, let scalar = scalars.first { charIDs[scalar.value] = id.int32Value }
        }
        var merges: [UInt64: (Int32, Int32)] = [:]
        merges.reserveCapacity(rawMerges.count)
        for (rank, item) in rawMerges.enumerated() {
            let pair: ([UInt8], [UInt8])?
            if let list = item as? NSArray, list.count == 2, let a = list[0] as? String, let b = list[1] as? String {
                pair = (bytes(a), bytes(b))
            } else if let text = item as? String, let space = text.firstIndex(of: " ") {
                pair = (bytes(String(text[..<space])), bytes(String(text[text.index(after: space)...])))
            } else {
                pair = nil
            }
            guard let pair, let a = vocab[pair.0], let b = vocab[pair.1], let merged = vocab[pair.0 + pair.1] else { continue }
            let key = UInt64(UInt32(bitPattern: a)) << 32 | UInt64(UInt32(bitPattern: b))
            if merges[key] == nil { merges[key] = (Int32(rank), merged) }
        }
        var byteIDs = [Int32](repeating: -1, count: 256)
        for byte in 0..<256 { byteIDs[byte] = vocab[bytes(String(format: "<0x%02X>", byte))] ?? -1 }
        var added: [Unicode.Scalar: [Added]] = [:]
        for case let item as NSDictionary in json["added_tokens"] as? NSArray ?? [] {
            guard let content = item["content"] as? String, let id = (item["id"] as? NSNumber)?.int32Value,
                  let first = content.unicodeScalars.first else { continue }
            added[first, default: []].append(Added(scalars: Array(content.unicodeScalars), id: id, special: (item["special"] as? NSNumber)?.boolValue ?? false))
            vocab[bytes(content)] = id
        }
        for key in added.keys { added[key]?.sort { $0.scalars.count > $1.scalars.count } }
        self.vocab = vocab
        self.charIDs = charIDs
        self.merges = merges
        self.byteIDs = byteIDs
        self.added = added
        bos = vocab[bytes("<bos>")] ?? 2
        eos = vocab[bytes("<eos>")] ?? 1
        unk = vocab[bytes("<unk>")] ?? 3
    }

    func encode(_ text: PIIText) -> [Token] {
        var tokens = [Token(id: bos, start: 0, end: 0, special: true)]
        var segmentStart = 0
        var i = 0
        while i < text.count {
            if let match = addedToken(in: text, at: i) {
                if segmentStart < i { encodeSegment(text, segmentStart, i, into: &tokens) }
                tokens.append(Token(id: match.id, start: i, end: i + match.scalars.count, special: match.special))
                i += match.scalars.count
                segmentStart = i
            } else {
                i += 1
            }
        }
        if segmentStart < text.count { encodeSegment(text, segmentStart, text.count, into: &tokens) }
        tokens.append(Token(id: eos, start: 0, end: 0, special: true))
        return tokens
    }

    private func addedToken(in text: PIIText, at index: Int) -> Added? {
        guard let candidates = added[text[index]] else { return nil }
        for candidate in candidates where index + candidate.scalars.count <= text.count {
            var equal = true
            for (offset, scalar) in candidate.scalars.enumerated() where text[index + offset] != scalar {
                equal = false
                break
            }
            if equal { return candidate }
        }
        return nil
    }

    private static let meta: Unicode.Scalar = "\u{2581}"

    /// Un tratto di testo fra due token aggiunti: normalizzazione, «▁» iniziale, pezzi, BPE.
    private func encodeSegment(_ text: PIIText, _ start: Int, _ end: Int, into tokens: inout [Token]) {
        // Caratteri normalizzati con la posizione originale (il «▁» aggiunto davanti non occupa caratteri).
        var chars: [(scalar: Unicode.Scalar, start: Int, end: Int)] = []
        chars.reserveCapacity(end - start + 1)
        for index in start..<end {
            chars.append((text[index] == " " ? Self.meta : text[index], index, index + 1))
        }
        // Come `prepend` di tokenizers: il «▁» aggiunto prende le posizioni del primo carattere.
        if let first = chars.first, first.scalar != Self.meta { chars.insert((Self.meta, first.start, first.end), at: 0) }
        var pieceStart = 0
        for index in 1...chars.count {
            guard index == chars.count || chars[index].scalar == Self.meta else { continue }
            let piece = chars[pieceStart..<index]
            for part in bpe(piece.map(\.scalar)) {
                let first = chars[pieceStart + part.first], last = chars[pieceStart + part.last]
                tokens.append(Token(id: part.id, start: first.start, end: max(first.start, last.end), special: false))
            }
            pieceStart = index
        }
    }

    /// BPE di un pezzo: (id, primo carattere, ultimo carattere), con la cache delle parole già viste.
    private func bpe(_ scalars: [Unicode.Scalar]) -> [(id: Int32, first: Int, last: Int)] {
        lock.lock()
        let cached = cache[scalars]
        lock.unlock()
        if let cached { return cached }
        var symbols: [(id: Int32, first: Int, last: Int)] = []
        symbols.reserveCapacity(scalars.count)
        for (index, scalar) in scalars.enumerated() {
            if let id = charIDs[scalar.value] {
                symbols.append((id, index, index))
            } else {
                // Fuori vocabolario: i suoi byte UTF-8, ognuno con le posizioni del carattere intero.
                for byte in String(scalar).utf8 {
                    let id = byteIDs[Int(byte)]
                    symbols.append((id >= 0 ? id : unk, index, index))
                }
            }
        }
        while symbols.count > 1 {
            var best: (index: Int, rank: Int32, id: Int32)?
            for index in 0..<(symbols.count - 1) {
                let key = UInt64(UInt32(bitPattern: symbols[index].id)) << 32 | UInt64(UInt32(bitPattern: symbols[index + 1].id))
                if let merge = merges[key], merge.rank < best?.rank ?? .max { best = (index, merge.rank, merge.id) }
            }
            guard let best else { break }
            symbols[best.index] = (best.id, symbols[best.index].first, symbols[best.index + 1].last)
            symbols.remove(at: best.index + 1)
        }
        lock.lock()
        if cache.count > 50_000 { cache.removeAll(keepingCapacity: true) }
        cache[scalars] = symbols
        lock.unlock()
        return symbols
    }
}
