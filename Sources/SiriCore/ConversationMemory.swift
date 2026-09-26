import Foundation

// MARK: - Memoria della conversazione per il modello
//
// A ogni risposta il modello riceve: gli scambi più recenti che stanno nella sua finestra (l'ultimo quasi intero,
// i precedenti via via più corti), gli scambi più vecchi solo se c'entrano con la domanda, e il riassunto di quelli
// usciti dalla finestra. Con Apple Intelligence (4096 token) la sessione si ricostruisce così a ogni risposta:
// misurato, non costa tempo (il modello rilegge comunque tutta la conversazione), i dati letti per le risposte passate
// non restano a occupare la finestra e la cronologia non si perde quando cambiano le istruzioni o una risposta era una scheda.

public enum ConversationMemory {
    /// Una domanda di Ivan e la risposta mostrata (vuota o «scheda» se c'è stata solo un'azione).
    public struct Exchange: Equatable, Sendable {
        public var user: String
        public var reply: String
        /// Dati letti per rispondere (web, file, calendario…), se la risposta si basava su quelli.
        public var data: String?
        /// Posizione del turno di Ivan in `turns` (quello della risposta, se lo scambio comincia con una risposta).
        public var index: Int

        public init(user: String, reply: String, data: String? = nil, index: Int) {
            self.user = user; self.reply = reply; self.data = data; self.index = index
        }
    }

    /// Scambi in ordine, dal più vecchio. Una risposta senza domanda (il riepilogo di una chat figlia) è uno scambio a sé.
    public static func exchanges(_ turns: [ChatTurn]) -> [Exchange] {
        var result: [Exchange] = []
        var open = false
        for (index, turn) in turns.enumerated() {
            switch turn.role {
            case .user:
                result.append(Exchange(user: turn.text, reply: "", data: turn.data, index: index))
                open = true
            case .assistant:
                if open, let last = result.indices.last {
                    result[last].reply += (result[last].reply.isEmpty ? "" : "\n") + turn.text
                } else {
                    result.append(Exchange(user: "", reply: turn.text, index: index))
                    open = false
                }
            }
        }
        return result
    }

    /// Gli scambi più recenti che stanno in `characters` caratteri, accorciati: l'ultimo fino a 700 + 1.400 caratteri
    /// (più i dati che aveva letto, se c'è posto: servono per «e il terzo risultato?»), i due prima 400 + 700, gli altri 250 + 400.
    public static func window(_ exchanges: [Exchange], characters: Int) -> [Exchange] {
        var room = characters
        var kept: [Exchange] = []
        for (rank, exchange) in exchanges.reversed().enumerated() {
            guard room >= 160 else { break }
            let caps = rank == 0 ? (user: 700, reply: 1400) : rank <= 2 ? (user: 400, reply: 700) : (user: 250, reply: 400)
            var user = excerpt(exchange.user, limit: caps.user)
            var reply = excerpt(exchange.reply, limit: caps.reply)
            var cost = user.count + reply.count + 24
            if cost > room {
                // Più corto, purché ne resti una parte che dica qualcosa; altrimenti ci si ferma qui (gli scambi più vecchi non entrano).
                let scale = Double(room - 24) / Double(max(1, cost - 24))
                guard scale >= 0.3 else { break }
                user = excerpt(exchange.user, limit: max(60, Int(Double(user.count) * scale)))
                reply = excerpt(exchange.reply, limit: max(80, Int(Double(reply.count) * scale)))
                cost = user.count + reply.count + 24
                guard cost <= room else { break }
            }
            var data: String?
            if rank == 0, let read = exchange.data, !read.isEmpty, room - cost > 700 {
                let text = excerpt(read, limit: min(900, room - cost - 400))
                data = text
                cost += text.count + 60
            }
            room -= cost
            kept.insert(Exchange(user: user, reply: reply, data: data, index: exchange.index), at: 0)
        }
        return kept
    }

    /// Estratto di un testo lungo: l'inizio (di solito la risposta vera e propria) e la fine (la conclusione), tagliati tra le parole.
    public static func excerpt(_ text: String, limit: Int) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        guard limit >= 120 else { return String(clean.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespaces) + "…" }
        let headCount = limit * 7 / 10
        let tailCount = limit - headCount - 7
        var head = String(clean.prefix(headCount))
        if let space = head.lastIndex(where: \.isWhitespace), head.distance(from: head.startIndex, to: space) > headCount / 2 {
            head = String(head[..<space])
        }
        var tail = String(clean.suffix(tailCount))
        if let space = tail.firstIndex(where: \.isWhitespace), tail.distance(from: tail.startIndex, to: space) < tailCount / 2 {
            tail = String(tail[tail.index(after: space)...])
        }
        return head + " […] " + tail
    }

    /// Scambi più vecchi che c'entrano con la richiesta: almeno due parole importanti in comune, oppure una parola rara
    /// (che compare in un solo scambio: un nome, un codice, «armadietto»). Al massimo `limit`, dai più pertinenti.
    public static func recall(_ exchanges: [Exchange], request: String, limit: Int = 2) -> [Exchange] {
        let asked = Assistant.significant(MemoryStore.keywords(request))
        guard !asked.isEmpty, !exchanges.isEmpty else { return [] }
        let words = exchanges.map { Assistant.significant(MemoryStore.keywords($0.user + " " + $0.reply)) }
        var frequency: [String: Int] = [:]
        for set in words { for word in set { frequency[word, default: 0] += 1 } }
        let scored = exchanges.indices.compactMap { index -> (Int, Double)? in
            let common = asked.intersection(words[index])
            let rare = common.filter { frequency[$0] == 1 && ($0.count >= 5 || $0.allSatisfy(\.isNumber)) }
            guard common.count >= 2 || !rare.isEmpty else { return nil }
            // Le parole di Ivan contano più di quelle delle risposte: è lì che ha detto nomi, numeri e scelte.
            let own = asked.intersection(MemoryStore.keywords(exchanges[index].user)).count
            return (index, Double(common.count) + Double(rare.count) * 0.5 + Double(own) * 0.5)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 > $1.0 }.prefix(limit)
            .map(\.0).sorted().map { exchanges[$0] }
    }

    /// Scambi come righe di testo («Ivan: …» / «Siri AI+: …»), per riformulazioni, riassunti e richiami.
    public static func lines(_ exchanges: [Exchange]) -> String {
        exchanges.map { exchange in
            [exchange.user.isEmpty ? nil : "\(Assistant.userFirstName ?? Language.t("Utente", "User")): \(exchange.user)", exchange.reply.isEmpty ? nil : "\(AppInfo.name): \(exchange.reply)"]
                .compactMap { $0 }.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
