import Foundation
import FoundationModels

extension Assistant {
    // MARK: - Note, Mail, File, Messaggi

    /// `readable`: le fonti fra Mail e Messaggi che si possono leggere in questa richiesta (per cercare nell'altra quando una è vuota).
    func handleApps(_ plan: Plan, prompt: String, readable: Set<SourceKind> = [], status: @escaping @MainActor (String) -> Void) async throws -> Outcome {
        let lower = prompt.lowercased()
        let query = plan["cerca"].flatMap { $0.isEmpty ? nil : $0 }
        let wantsContent = ["riassumi", "leggi", "cosa dice", "cosa c'è scritto", "contenuto", "di cosa parla", "spiega"].contains(where: lower.contains)
            || (Language.isEnglish && lower.range(of: #"\b(?:summari[sz]e|summary|read|explain|content|contents)\b|what (?:does|did) it say|what it says|what(?:'s| is) it about|what(?:'s| is) written"#,
                                                  options: .regularExpression) != nil)

        switch plan.action {
        case .note:
            status(query.map { Language.t("Cerco «\($0)» nelle Note…", "Searching Notes for «\($0)»…") } ?? Language.t("Leggo le Note…", "Reading Notes…"))
            var items = try await NotesService.search(query)
            // Per riassumere serve il testo completo della prima nota trovata.
            if wantsContent, let first = items.rows.first, let reference = first.reference,
               let body = try? await NotesService.body(id: reference) {
                items.rows[0].detail = String(body.prefix(2000))
            }
            remember(items.digest)
            return .items(items, prompt: grounded(prompt, items.digest))

        case .crea_nota:
            status(Language.t("Scrivo la nota…", "Writing the note…"))
            return .noteDraft(try await draftNote(prompt: prompt, title: plan["titolo"]))

        case .mail_leggi:
            status(query.map { Language.t("Cerco «\($0)» nella posta…", "Searching mail for «\($0)»…") } ?? Language.t("Leggo la posta in arrivo…", "Reading the inbox…"))
            let unreadOnly = lower.contains("non lett") || lower.contains("da leggere")
                || (Language.isEnglish && ["unread", "not read", "haven't read", "have not read", "to read", "new emails", "new mail"].contains(where: lower.contains))
            let search = query ?? plan["destinatari"]
            var items = try await MailReader.inbox(query: search, unreadOnly: unreadOnly)
            // «Any news from my accountant?» con la posta in italiano: chi scrive, cercato anche nell'altra lingua.
            if items.rows.isEmpty, !unreadOnly, let search, let other = Self.roleInOtherLanguage(search),
               var found = try? await MailReader.inbox(query: other), !found.rows.isEmpty {
                found.title = MailReader.listTitle(query: search, unreadOnly: false, account: SpaceScope.current.mailAccount)
                items = found
            }
            if items.rows.isEmpty, !unreadOnly, let search, !search.isEmpty {
                // «Mi ha scritto Giulia?» senza dire dove: niente nella posta, si guarda nei Messaggi.
                if !Self.namesMail(lower), readable.contains(.messages),
                   let texts = try? MessagesService.recent(matching: search), !texts.rows.isEmpty {
                    FixtureWorld.active?.recordRead("leggi_messaggi", search: search)
                    remember(texts.digest)
                    return .items(texts, prompt: grounded(prompt, texts.digest))
                }
                // Nessuna email con quelle parole: le ultime ricevute, dette per quello che sono, così il modello riconosce chi ha
                // scritto con un altro nome o in un'altra lingua («accountant» → «Studio Neri Commercialisti»).
                var latest = try await MailReader.inbox(query: nil)
                if !latest.rows.isEmpty {
                    latest.title = Language.t("Nessuna email con «\(search)» nell'oggetto o nel mittente. Le ultime ricevute",
                                              "No email with «\(search)» in the subject or sender. The latest received")
                    items = latest
                }
            }
            // "Rispondi alla prima", "inoltrala a Giulia": le email appena mostrate.
            recentMails = items.rows.map { MailMessage(id: $0.id, subject: $0.title, sender: $0.subtitle, date: "") }
            recentMail = nil
            remember(items.digest)
            return .items(items, prompt: grounded(prompt, items.digest))

        case .file:
            let search = query ?? plan["argomento"] ?? prompt
            status(Language.t("Cerco «\(search.prefix(40))» sul Mac…", "Searching the Mac for «\(search.prefix(40))»…"))
            var items = try await FileSearch.search(search)
            var data = items.digest
            if wantsContent, let path = items.rows.first(where: { !$0.title.hasPrefix("📁") })?.reference,
               let text = try? FileSearch.read(path) {
                items.rows[0].detail = String(text.prefix(300))
                data += Language.t("\n\nContenuto di ", "\n\nContents of ") + "\((path as NSString).lastPathComponent):\n\(text)"
            }
            remember(items.digest)
            return .items(items, prompt: grounded(prompt, data))

        case .messaggi:
            status(Language.t("Leggo i Messaggi…", "Reading Messages…"))
            let search = plan["destinatari"] ?? query
            let items = try MessagesService.recent(matching: search)
            // «Mi ha scritto Paolo Verdi?» senza dire dove: nessun messaggio, ma forse un'email.
            if items.rows.isEmpty, let search, !search.isEmpty, !Self.namesTexts(lower), readable.contains(.mail),
               let mail = try? await MailReader.inbox(query: search), !mail.rows.isEmpty {
                FixtureWorld.active?.recordRead("leggi_email", search: search)
                recentMails = mail.rows.map { MailMessage(id: $0.id, subject: $0.title, sender: $0.subtitle, date: "") }
                recentMail = nil
                remember(mail.digest)
                return .items(mail, prompt: grounded(prompt, mail.digest))
            }
            remember(items.digest)
            return .items(items, prompt: grounded(prompt, items.digest))

        case .invia_messaggio:
            status(Language.t("Preparo il messaggio…", "Preparing the message…"))
            var draft = try await draftMessage(prompt: prompt, recipient: plan["destinatari"])
            // Contatto o conversazione sullo schermo: il recapito è già noto.
            if let known = screenHandle(for: draft.recipient) {
                draft.recipient = known.name
                draft.handle = known.handle
            }
            return .messageDraft(draft)

        default:
            return .reply(prompt: withContext(prompt))
        }
    }

    private static let noteSchema = makeSchema("Nota", [
        .required("titolo", .string, "Titolo breve della nota"),
        .required("testo", .string, "Testo della nota. Se l'utente detta un contenuto o un elenco, riportalo fedelmente, una voce per riga"),
    ])

    func draftNote(prompt: String, title: String?) async throws -> NoteDraft {
        let role = "Scrivi note chiare e ordinate per l'app Note. Se l'utente detta il contenuto, riportalo senza aggiungere nulla."
        let request = "Richiesta: \(prompt)" + (title.map { "\nTitolo suggerito: \($0)" } ?? "")
        if let json = await composeJSON(role, request, fields: "\"titolo\": titolo breve della nota; \"testo\": testo della nota, una voce per riga"),
           let body = json.text("testo") {
            return NoteDraft(title: json.text("titolo") ?? title ?? "Nota", body: body)
        }
        let content = try await writer(role).respond(to: request, schema: Self.noteSchema).content
        return NoteDraft(title: content.string("titolo") ?? title ?? "Nota", body: content.string("testo") ?? "")
    }

    private static var messageSchema: GenerationSchema {
        makeSchema("Messaggio", [
            .required("destinatario", .string, Language.t("Nome, numero o email della persona a cui scrivere, come indicato dall'utente",
                                                          "Name, number or email of the person to write to, as the user gave it")),
            .required("testo", .string, Language.t("Testo del messaggio, breve e naturale, in prima persona come se lo scrivesse \(userFirstName ?? "l'utente")",
                                                   "Text of the message, short and natural, in the first person as if \(userFirstName ?? "the user") wrote it")),
        ])
    }

    func draftMessage(prompt: String, recipient: String?) async throws -> MessageDraft {
        let role = "Scrivi messaggi brevi e cordiali da mandare con iMessage. Non inventare orari, luoghi o impegni non indicati."
        let request = "Richiesta: \(prompt)" + (recipient.map { "\nDestinatario: \($0)" } ?? "")
        let fields = Language.t("\"destinatario\": nome, numero o email della persona come indicato dall'utente; \"testo\": il messaggio, breve e naturale, in prima persona come se lo scrivesse \(Self.userFirstName ?? "l'utente")",
                                "\"destinatario\": name, number or email of the person as the user gave it; \"testo\": the message, short and natural, in the first person as if \(Self.userFirstName ?? "the user") wrote it")
        if let json = await composeJSON(role, request, fields: fields),
           let text = json.text("testo") {
            let name = json.text("destinatario") ?? recipient ?? ""
            return MessageDraft(recipient: name, handle: Contacts.resolve(name) ?? "", text: text)
        }
        let content = try await writer(role).respond(to: request, schema: Self.messageSchema).content
        let name = content.string("destinatario") ?? recipient ?? ""
        return MessageDraft(recipient: name, handle: Contacts.resolve(name) ?? "", text: content.string("testo") ?? "")
    }
}
