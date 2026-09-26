import Foundation

/// Chat figlie: cosa porta con sé una figlia dalla madre, e quando chiede di tornarci.
public enum ChildChat {
    /// Il contesto che la figlia eredita: prima ciò che ha detto Ivan (lì ci sono i fatti: date, nomi, decisioni),
    /// poi l'ultima risposta della madre se dice qualcosa (una risposta incerta confonderebbe la figlia).
    public static func handoff(title: String, turns: [ChatTurn]) -> String {
        let recent = turns.suffix(8)
        let said = recent.filter { $0.role == .user }.suffix(4).map { "- " + $0.text.replacingOccurrences(of: "\n", with: " ").prefix(320) }
        var text = "Chat madre «\(title)». Ivan ha detto:\n" + said.joined(separator: "\n")
        if let reply = recent.last(where: { $0.role == .assistant }), !Assistant.soundsUnsure(reply.text) {
            text += "\nUltima risposta: " + reply.text.replacingOccurrences(of: "\n", with: " ").prefix(240)
        }
        return text
    }

    /// «Concludi», «torna alla chat madre», «riporta tutto alla madre» scritti in una chat figlia.
    /// Non «manda un messaggio a mia madre»: la madre è quella della chat.
    public static func asksToReturn(_ prompt: String) -> Bool {
        let lower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let verb = #"\b(?:torna(?:re|mo)?|riporta(?:lo|la|mi)?|manda(?:lo|la)?|invia(?:lo|la)?|rimanda(?:lo|la)?)\b"#
        if lower.range(of: verb + #".*\b(?:chat\s+madre|alla\s+madre|nella\s+madre)\b"#, options: .regularExpression) != nil { return true }
        let words = lower.split(separator: " ").count
        return lower.range(of: #"^(?:ok[, ]+|va bene[, ]+)?(?:concludi|conclusa|chiudi|termina|finisci|abbiamo finito|ho finito)\b"#, options: .regularExpression) != nil
            && (words <= 4 || lower.contains("chat") || lower.contains("figlia"))
    }
}
