import Foundation
import FoundationModels

extension Assistant {
    // MARK: - Note, Mail, File, Messaggi

    func handleApps(_ plan: Plan, prompt: String, status: @escaping @MainActor (String) -> Void) async throws -> Outcome {
        let lower = prompt.lowercased()
        let query = plan["cerca"].flatMap { $0.isEmpty ? nil : $0 }
        let wantsContent = ["riassumi", "leggi", "cosa dice", "cosa c'è scritto", "contenuto", "di cosa parla", "spiega"].contains(where: lower.contains)
            || (Language.isEnglish && lower.range(of: #"\b(?:summari[sz]e|summary|read|explain|content|contents)\b|what (?:does|did) it say|what it says|what(?:'s| is) it about|what(?:'s| is) written"#,
                                                  options: .regularExpression) != nil)

        switch plan.action {
        case .note:
            status(query.map { "Cerco «\($0)» nelle Note…" } ?? "Leggo le Note…")
            var items = try await NotesService.search(query)
            // Per riassumere serve il testo completo della prima nota trovata.
            if wantsContent, let first = items.rows.first, let reference = first.reference,
               let body = try? await NotesService.body(id: reference) {
                items.rows[0].detail = String(body.prefix(2000))
            }
            remember(items.digest)
            return .items(items, prompt: grounded(prompt, items.digest))

        case .crea_nota:
            status("Scrivo la nota…")
            return .noteDraft(try await draftNote(prompt: prompt, title: plan["titolo"]))

        case .mail_leggi:
            status(query.map { "Cerco «\($0)» nella posta…" } ?? "Leggo la posta in arrivo…")
            let items = try await MailReader.inbox(query: query ?? plan["destinatari"], unreadOnly: lower.contains("non lett") || lower.contains("da leggere"))
            // "Rispondi alla prima", "inoltrala a Giulia": le email appena mostrate.
            recentMails = items.rows.map { MailMessage(id: $0.id, subject: $0.title, sender: $0.subtitle, date: "") }
            recentMail = nil
            remember(items.digest)
            return .items(items, prompt: grounded(prompt, items.digest))

        case .file:
            let search = query ?? plan["argomento"] ?? prompt
            status("Cerco «\(search.prefix(40))» sul Mac…")
            var items = try await FileSearch.search(search)
            var data = items.digest
            if wantsContent, let path = items.rows.first(where: { !$0.title.hasPrefix("📁") })?.reference,
               let text = try? FileSearch.read(path) {
                items.rows[0].detail = String(text.prefix(300))
                data += "\n\nContenuto di \((path as NSString).lastPathComponent):\n\(text)"
            }
            remember(items.digest)
            return .items(items, prompt: grounded(prompt, data))

        case .messaggi:
            status("Leggo i Messaggi…")
            let items = try MessagesService.recent(matching: plan["destinatari"] ?? query)
            remember(items.digest)
            return .items(items, prompt: grounded(prompt, items.digest))

        case .invia_messaggio:
            status("Preparo il messaggio…")
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
            .required("testo", .string, Language.t("Testo del messaggio, breve e naturale, in prima persona come se lo scrivesse \(accountFirstName ?? "l'utente")",
                                                   "Text of the message, short and natural, in the first person as if \(accountFirstName ?? "the user") wrote it")),
        ])
    }

    func draftMessage(prompt: String, recipient: String?) async throws -> MessageDraft {
        let role = "Scrivi messaggi brevi e cordiali da mandare con iMessage. Non inventare orari, luoghi o impegni non indicati."
        let request = "Richiesta: \(prompt)" + (recipient.map { "\nDestinatario: \($0)" } ?? "")
        let fields = Language.t("\"destinatario\": nome, numero o email della persona come indicato dall'utente; \"testo\": il messaggio, breve e naturale, in prima persona come se lo scrivesse \(Self.accountFirstName ?? "l'utente")",
                                "\"destinatario\": name, number or email of the person as the user gave it; \"testo\": the message, short and natural, in the first person as if \(Self.accountFirstName ?? "the user") wrote it")
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
