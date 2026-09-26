import Foundation

/// Tempi delle singole richieste a Mail su una casella grande (diagnostica `--mail-probe`, solo letture).
public enum MailProbe {
    public static func run(account: String?) async -> [String] {
        guard SystemAccess.automation("com.apple.mail") == .granted else { return ["Mail non autorizzata o chiusa: niente prova"] }
        let box = account.map { "mailbox \"INBOX\" of account \(AppleScript.quote($0))" } ?? "inbox"
        var lines: [String] = []
        var firstID = ""
        let steps: [(String, String)] = [
            ("conta", "count of messages of theBox"),
            ("id 1-30", "id of messages 1 thru 30 of theBox"),
            ("oggetto 1-30", "subject of messages 1 thru 30 of theBox"),
            ("mittente 1-30", "sender of messages 1 thru 30 of theBox"),
            ("data 1-30", "date received of messages 1 thru 30 of theBox"),
            ("letto 1-30", "read status of messages 1 thru 30 of theBox"),
            ("riferimenti 1-5", "messages 1 thru 5 of theBox"),
            ("id primo", "id of message 1 of theBox"),
            ("oggetto primo", "subject of message 1 of theBox"),
            ("id ultimi 30 (per data)", "id of (messages of theBox whose date received > ((current date) - 3 * days))"),
        ]
        for (label, expression) in steps {
            let start = Date.now
            do {
                let output = try await AppleScript.run("tell application \"Mail\"\nset theBox to \(box)\nreturn \(expression)\nend tell", app: "Mail")
                if label == "id primo" { firstID = output.trimmingCharacters(in: .whitespacesAndNewlines) }
                lines.append("\(label): \(Int(Date.now.timeIntervalSince(start) * 1000)) ms · \(output.prefix(label.hasPrefix("riferimenti") ? 400 : 60))")
            } catch {
                lines.append("\(label): ERRORE \(error.localizedDescription.prefix(160)) · \(Int(Date.now.timeIntervalSince(start) * 1000)) ms")
            }
        }
        if let number = Int(firstID) {
            for (label, expression) in [("whose id", "subject of (first message of theBox whose id is \(number))"),
                                        ("contenuto whose id", "length of (content of (first message of theBox whose id is \(number)))")] {
                let start = Date.now
                do {
                    let output = try await AppleScript.run("tell application \"Mail\"\nset theBox to \(box)\nreturn \(expression)\nend tell", app: "Mail")
                    lines.append("\(label): \(Int(Date.now.timeIntervalSince(start) * 1000)) ms · \(output.prefix(60))")
                } catch {
                    lines.append("\(label): ERRORE \(error.localizedDescription.prefix(160)) · \(Int(Date.now.timeIntervalSince(start) * 1000)) ms")
                }
            }
        }
        return lines
    }
}
