import Foundation

/// Diagnostica delle app (`--apps-probe`): solo letture, e solo dove macOS ha già dato il permesso,
/// così nessuna richiesta compare sullo schermo di chi usa il Mac. Scrive tempi e quantità nel log.
public enum AppsProbe {
    public static func run() async -> [String] {
        var lines: [String] = []
        func measure(_ label: String, _ work: () async throws -> String) async {
            let start = Date.now
            do {
                let result = try await work()
                lines.append("\(label): \(result) · \(Int(Date.now.timeIntervalSince(start) * 1000)) ms")
            } catch {
                lines.append("\(label): ERRORE \(error.localizedDescription) · \(Int(Date.now.timeIntervalSince(start) * 1000)) ms")
            }
        }
        let mail = SystemAccess.automation("com.apple.mail")
        let notes = SystemAccess.automation("com.apple.Notes")
        let messages = SystemAccess.automation("com.apple.MobileSMS")
        lines.append("PERMESSI: Mail \(mail.rawValue) · Note \(notes.rawValue) · Messaggi \(messages.rawValue) · disco \(SystemAccess.fullDiskAccess) · calendario \(CalendarStore.authorized) · promemoria \(ReminderStore.authorized)")

        if CalendarStore.authorized {
            await measure("CALENDARI") {
                let calendars = CalendarStore.calendars()
                return "\(calendars.count) (\(Set(calendars.map(\.account)).count) account, \(calendars.filter(\.writable).count) modificabili)"
            }
            await measure("EVENTI 7 GIORNI") {
                let start = Calendar.current.startOfDay(for: .now)
                return "\(CalendarStore.events(from: start, to: start.addingTimeInterval(7 * 86_400), calendarIDs: nil).count)"
            }
            if let day = ProcessInfo.processInfo.environment["SIRIAI_PROBE_DAY"].flatMap({ try? Date($0, strategy: .iso8601.year().month().day()) }) {
                for event in CalendarStore.events(from: day, to: day.addingTimeInterval(86_400), calendarIDs: nil) {
                    lines.append("EVENTO \(event.start.formatted(.dateTime.hour().minute())) \(event.title.prefix(30)) · id \(event.id.suffix(40)) · cal \(event.calendarTitle) · ripete \(event.isRecurring)")
                }
            }
            await measure("EVENTI MESE") {
                let start = Calendar.current.startOfDay(for: .now)
                return "\(CalendarStore.events(from: start.addingTimeInterval(-7 * 86_400), to: start.addingTimeInterval(35 * 86_400), calendarIDs: nil).count)"
            }
        }
        if ReminderStore.authorized {
            await measure("LISTE PROMEMORIA") { "\(ReminderStore.lists().count)" }
            await measure("PROMEMORIA DA FARE") { "\(await ReminderStore.fetch(completed: false, listIDs: nil).count)" }
            await measure("PROMEMORIA COMPLETATI") { "\(await ReminderStore.fetch(completed: true, listIDs: nil).count)" }
        }
        if mail == .granted {
            await measure("MAIL ACCOUNT") { try await MailStore.accounts().map { "\($0.name) (\($0.addresses.count) indirizzi)" }.joined(separator: ", ") }
            var boxes: [MailboxInfo] = []
            await measure("MAIL CASELLE") {
                boxes = try await MailStore.mailboxes()
                return "\(boxes.count): " + boxes.prefix(40).map { "\($0.account ?? "*")/\($0.name)=\($0.kind.rawValue)[\($0.unread)]" }.joined(separator: " ")
            }
            var first: MailSummary?
            await measure(MailIndex.available ? "MAIL IN ARRIVO (indice)" : "MAIL IN ARRIVO (AppleScript, 60)") {
                let page = MailIndex.available ? try MailIndex.messages(in: .unifiedInbox, limit: 120) : try await MailStore.messages(in: .unifiedInbox, count: 60)
                first = page.items.first
                return "\(page.items.count) di \(page.total), non lette \(page.items.filter { !$0.read }.count)"
            }
            if let first {
                await measure("MAIL CONTENUTO") {
                    let content = try await MailStore.content(of: first.id, in: .unifiedInbox)
                    return "\(content.content.count) caratteri, a \(content.to.count), cc \(content.cc.count), allegati \(content.attachments.count)"
                }
            }
            if MailIndex.available {
                for box in (try? MailIndex.mailboxes())?.filter({ $0.account == nil }) ?? [] {
                    await measure("MAIL \(box.kind.label.uppercased()) (indice)") {
                        let page = try MailIndex.messages(in: box, limit: 60)
                        return "\(page.items.count) di \(page.total)"
                    }
                }
            }
        }
        if notes == .granted {
            var folders: [NotesFolder] = []
            await measure("NOTE CARTELLE") {
                folders = try await NotesStore.folders()
                return "\(folders.count): " + folders.map { "\($0.account)/\($0.name)[\($0.count)]" }.joined(separator: " ")
            }
            if let folder = folders.first(where: { $0.count > 0 && !$0.isTrash }) {
                await measure("NOTE IN \(folder.name)") { "\(try await NotesStore.notes(in: folder.id).count)" }
            }
            await measure("NOTE TUTTE") { "\(try await NotesStore.notes(in: nil).count)" }
        }
        if SystemAccess.fullDiskAccess {
            var chats: [ChatSummary] = []
            await measure("MESSAGGI CONVERSAZIONI") {
                chats = try MessagesStore.chats()
                return "\(chats.count), senza testo \(chats.filter { $0.lastText == "Allegato" }.count)"
            }
            if let chat = chats.first {
                await measure("MESSAGGI STORICO") {
                    let items = try MessagesStore.messages(chat: chat.id)
                    return "\(items.count), vuoti \(items.filter { $0.text.isEmpty }.count)"
                }
            }
        }
        await measure("FILE CASA") { "\(try FileStore.list(FileManager.default.homeDirectoryForCurrentUser).count)" }
        await measure("FILE RECENTI") { "\(await FileStore.recents().count)" }
        return lines
    }
}
