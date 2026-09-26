import AppKit
import Contacts
import Foundation
import Testing
@testable import SiriCore

/// Le app dentro Siri AI+: letture dall'indice di Mail e da Messaggi, caselle, note formattate, file e segreti.
@Suite struct AppsTests {
    @Test func mailboxKinds() {
        #expect(MailboxInfo.kind(of: "INBOX") == .inbox)
        #expect(MailboxInfo.kind(of: "Sent Messages") == .sent)
        #expect(MailboxInfo.kind(of: "[Gmail]/Posta inviata") == .sent)
        #expect(MailboxInfo.kind(of: "Tutti i messaggi") == .archive)
        #expect(MailboxInfo.kind(of: "INBOX/Trash") == .trash)
        #expect(MailboxInfo.kind(of: "Posta indesiderata") == .junk)
        #expect(MailboxInfo.kind(of: "Clienti") == .other)
        let nested = MailboxInfo(account: "Lavoro", accountID: "A", name: "INBOX/Clienti/Rossi", kind: .other)
        #expect(nested.displayPath == ["Clienti", "Rossi"])
        #expect(nested.displayName == "Rossi")
        #expect(nested.depth == 1)
        #expect(MailboxInfo(account: "Lavoro", name: "INBOX", kind: .inbox).displayName == "In arrivo")
    }

    @Test func mailboxScriptUsesAccountID() {
        let box = MailboxInfo(account: "Ivan - Gmail", accountID: "5E54", name: "[Gmail]/Tutti i messaggi", kind: .archive)
        #expect(MailStore.box(box) == "mailbox \"[Gmail]/Tutti i messaggi\" of account id \"5E54\"")
        #expect(MailStore.box(.unifiedInbox) == "inbox")
        #expect(MailStore.box(MailboxInfo(account: nil, name: "sent", kind: .sent)) == "sent mailbox")
        // Un'email si ritrova con «whose id»: «message id N» non compila in Mail.
        #expect(MailStore.message("42", in: .unifiedInbox).contains("first message of theBox whose id is 42"))
    }

    @Test func mailIndexURLs() {
        let parsed = MailIndex.parse(url: "imap://5E54630F-34CC/%5BGmail%5D/Tutti%20i%20messaggi")
        #expect(parsed?.accountID == "5E54630F-34CC")
        #expect(parsed?.name == "[Gmail]/Tutti i messaggi")
        #expect(MailIndex.parse(url: "local://ABC/Outbox")?.name == "Outbox")
        #expect(MailIndex.parse(url: "nonsense") == nil)
    }

    @Test func mailListParsing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let f = AppleScript.field, r = AppleScript.record
        let output = "2\(r)11\(f)Ciao\(f)Mario Rossi <mario@esempio.it>\(f)60\(f)false\(f)true\(r)12\(f)missing value\(f)anna@esempio.it\(f)3600\(f)true\(f)false\(r)"
        let page = MailStore.parseMessages(output, now: now)
        #expect(page.total == 2)
        #expect(page.items.map(\.id) == ["11", "12"])
        #expect(page.items[0].senderName == "Mario Rossi")
        #expect(page.items[0].senderAddress == "mario@esempio.it")
        #expect(page.items[0].read == false && page.items[0].flagged == true)
        #expect(page.items[1].subject == "")
        #expect(page.items[1].date == now.addingTimeInterval(-3600))
    }

    @Test func replyAndForwardDrafts() {
        let content = MailContent(id: "7", subject: "Preventivo", sender: "Mario Rossi <mario@esempio.it>", to: ["io@esempio.it", "anna@esempio.it"],
                                  cc: ["capo@esempio.it"], attachments: [], date: .now, dateText: "23 settembre 2026 alle 10:15",
                                  content: "Ciao\nEcco il preventivo", read: true, flagged: false)
        let reply = MailStore.replyDraft(to: content, box: .unifiedInbox, all: false, from: "Io <io@esempio.it>")
        #expect(reply.to == "mario@esempio.it")
        #expect(reply.subject == "Re: Preventivo")
        #expect(reply.quote.contains("> Ecco il preventivo"))
        let all = MailStore.replyDraft(to: content, box: .unifiedInbox, all: true, from: "Io <io@esempio.it>")
        #expect(all.to == "mario@esempio.it, anna@esempio.it, capo@esempio.it")
        #expect(MailStore.forwardDraft(of: content, box: .unifiedInbox).subject == "Fwd: Preventivo")
        #expect(MailComposition.addresses("a@b.it; Carlo <c@d.it>,\n e@f.it") == ["a@b.it", "Carlo <c@d.it>", "e@f.it"])
    }

    @Test func notesListParsing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let f = AppleScript.field, r = AppleScript.record
        let output = "id1\(f)Spesa\(f)120\(f)Spesa\nlatte\nuova\(r)id2\(f)\(f)10\(f)\(r)"
        let notes = NotesStore.parseNotes(output, folderID: "F", now: now)
        #expect(notes.map(\.id) == ["id2", "id1"])
        #expect(notes[0].title == "Nuova nota")
        #expect(notes[1].preview == "latte uova")
        #expect(notes[1].modified == now.addingTimeInterval(-120))
    }

    @Test func notesTrashFolder() {
        #expect(NotesFolder(id: "1", name: "Recently Deleted", account: "iCloud", accountID: "A", count: 3).isTrash)
        #expect(NotesFolder(id: "2", name: "Eliminate di recente", account: "iCloud", accountID: "A", count: 0).isTrash)
        #expect(!NotesFolder(id: "3", name: "Notes", account: "iCloud", accountID: "A", count: 1).isTrash)
    }

    @MainActor @Test func noteFormattingRoundTrip() {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Spesa & <casa>\n", attributes: NoteHTML.attributes(level: .title)))
        text.append(NSAttributedString(string: "Da comprare\n", attributes: NoteHTML.attributes(level: .heading)))
        var bold = NoteHTML.attributes(level: .body)
        bold[.font] = NSFont.systemFont(ofSize: NoteHTML.Level.body.size, weight: .bold)
        text.append(NSAttributedString(string: "latte", attributes: bold))
        var underline = NoteHTML.attributes(level: .body)
        underline[.underlineStyle] = NSUnderlineStyle.single.rawValue
        text.append(NSAttributedString(string: " fresco\n", attributes: underline))
        text.append(NSAttributedString(string: "\n", attributes: NoteHTML.attributes(level: .body)))
        var italic = NoteHTML.attributes(level: .body)
        italic[.font] = NSFontManager.shared.convert(NSFont.systemFont(ofSize: NoteHTML.Level.body.size), toHaveTrait: .italicFontMask)
        text.append(NSAttributedString(string: "fine", attributes: italic))
        let html = NoteHTML.html(from: text)
        #expect(html == "<div><h1>Spesa &amp; &lt;casa&gt;</h1></div><div><h2>Da comprare</h2></div><div><b>latte</b><u> fresco</u></div><div><br></div><div><i>fine</i></div>")
        // Andata e ritorno: stessi livelli, stesso testo.
        let back = NoteHTML.attributed(from: html)
        #expect(back.string == "Spesa & <casa>\nDa comprare\nlatte fresco\n\nfine")
        #expect(NoteHTML.html(from: back) == html)
    }

    @Test func noteSafety() {
        #expect(NotesStore.canRewrite("<div><h1>Titolo</h1></div><div>testo</div>"))
        #expect(!NotesStore.canRewrite("<div><ul><li>uno</li></ul></div>"))
        #expect(!NotesStore.canRewrite("<div><table><tr><td>1</td></tr></table></div>"))
        #expect(!NotesStore.canRewrite("<div><img src=\"x\"></div>"))
    }

    @Test func messagesAttributedBody() {
        // Formato «typedstream»: dopo «NSString» 5 byte, poi la lunghezza e il testo in UTF-8.
        func body(_ text: String) -> Data {
            let utf8 = Array(text.utf8)
            var bytes = Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40] + Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
            if utf8.count < 0x80 { bytes.append(UInt8(utf8.count)) } else { bytes += [0x81, UInt8(utf8.count & 0xFF), UInt8(utf8.count >> 8)] }
            return Data(bytes + utf8 + [0x86, 0x84])
        }
        #expect(MessagesStore.decodeAttributedBody(body("Ciao! Ci vediamo alle 18 🙂")) == "Ciao! Ci vediamo alle 18 🙂")
        let long = String(repeating: "lungo ", count: 60)
        #expect(MessagesStore.decodeAttributedBody(body(long)) == long)
        #expect(MessagesStore.decodeAttributedBody(Data("niente".utf8)) == nil)
    }

    @Test func fileOperations() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "prova-file-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try FileStore.newFolder(in: folder)
        let second = try FileStore.newFolder(in: folder)
        #expect(first.lastPathComponent == "Nuova cartella")
        #expect(second.lastPathComponent == "Nuova cartella 2")
        let note = try FileStore.newTextFile(in: folder, content: "# Ciao")
        #expect(note.lastPathComponent == "Senza titolo.md")
        // Rinominando senza estensione, l'estensione resta.
        let renamed = try FileStore.rename(note, to: "Appunti")
        #expect(renamed.lastPathComponent == "Appunti.md")
        #expect(throws: (any Error).self) { try FileStore.rename(first, to: "Nuova cartella 2") }
        let copy = try FileStore.duplicate(renamed)
        #expect(copy.lastPathComponent == "Appunti copia.md")
        let moved = try FileStore.move(copy, into: first)
        #expect(moved.deletingLastPathComponent().lastPathComponent == "Nuova cartella")
        let entries = try FileStore.list(folder)
        #expect(entries.map(\.name) == ["Nuova cartella", "Nuova cartella 2", "Appunti.md"])
        #expect(entries.first?.isFolder == true)
        #expect(entries.last?.symbol == "doc.text")
    }

    @Test func secretsStayInFileWithPrivatePermissions() throws {
        guard !Keychain.disabled else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "segreti-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Keychain.fileOverride = folder.appending(path: "segreti.json")
        defer { Keychain.fileOverride = nil; try? FileManager.default.removeItem(at: folder) }
        let account = "prova-\(UUID().uuidString.prefix(6))"
        #expect(Keychain.set("segreto", for: account))
        #expect(Keychain.get(account) == "segreto")
        let attributes = try FileManager.default.attributesOfItem(atPath: Keychain.fileURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        // Tolto il valore, il Portachiavi non si riapre per questa voce.
        Keychain.set(nil, for: account)
        #expect(Keychain.get(account) == nil)
        #expect(Keychain.read().migrated.contains(account))
    }

    @Test func voiceMemoTranscripts() {
        let json = #"{"attributedString":{"attributeTable":[{"timeRange":[0,1.2]},{"timeRange":[1.2,2]}],"runs":["Ciao",0," a tutti",1]},"locale":{"identifier":"it_IT","current":0}}"#
        #expect(VoiceMemosStore.transcript(json: Data(json.utf8)) == "Ciao a tutti")
        // Nel file: 4 byte di lunghezza, «tsrp», poi il JSON (l'atomo sta vicino alla fine).
        var file = Data(repeating: 0, count: 64)
        let payload = Data(json.utf8)
        let size = UInt32(8 + payload.count)
        file.append(contentsOf: [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
        file.append(Data("tsrp".utf8))
        file.append(payload)
        #expect(VoiceMemosStore.transcript(inFile: file) == "Ciao a tutti")
        #expect(VoiceMemosStore.transcript(inFile: Data(repeating: 1, count: 100)) == nil)
        #expect(VoiceMemosStore.transcript(json: Data(#"{"attributedString":{"runs":[]}}"#.utf8)) == nil)
        #expect(VoiceMemo.format(125) == "2:05")
        #expect(VoiceMemo.format(3725) == "1:02:05")
    }

    @Test func contactSummaries() {
        let person = CNMutableContact()
        person.givenName = "Mario"
        person.familyName = "Rossi"
        person.organizationName = "Studio Rossi"
        person.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+39 333 1234567"))]
        let summary = ContactsStore.summary(person)
        #expect(summary.name == "Mario Rossi")
        #expect(summary.organization == "Studio Rossi")
        #expect(summary.sortKey == "rossi mario")
        #expect(summary.detail == "+39 333 1234567")
        let company = CNMutableContact()
        company.organizationName = "Apple Italia"
        company.contactType = .organization
        #expect(ContactsStore.summary(company).name == "Apple Italia")
        #expect(ContactsStore.summary(company).isCompany)
        #expect(ContactsStore.summary(CNMutableContact()).sortKey.isEmpty)
        let address = PostalField(label: CNLabelHome, street: "Via Roma 1", city: "Roma", postalCode: "00100", country: "Italia")
        #expect(address.oneLine == "Via Roma 1, 00100 Roma, Italia")
        #expect(!address.isEmpty)
        #expect(PostalField(label: CNLabelHome).isEmpty)
    }

    @Test func eventRepeatRules() {
        #expect(CalendarStore.rule(for: .never) == nil)
        #expect(CalendarStore.rule(for: .weekdays)?.daysOfTheWeek?.count == 5)
        #expect(CalendarStore.rule(for: .biweekly)?.interval == 2)
        #expect(ReminderEntry.Priority(level: 1) == .high)
        #expect(ReminderEntry.Priority(level: 5) == .medium)
        #expect(ReminderEntry.Priority(level: 9) == .low)
        #expect(ReminderEntry.Priority(level: 0) == .none)
    }
}
