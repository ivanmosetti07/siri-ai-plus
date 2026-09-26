import Foundation
import Testing
@testable import SiriCore

/// Anonimizzazione verso ChatGPT e Claude (rizzo-pii sul Mac): regole con i codici di controllo, dizionario della chat,
/// ripristino tollerante, pagine web. I casi con il modello girano solo dove il motore è installato.
@Suite struct PrivacyTests {
    private func labels(_ text: String) -> [String] {
        let source = PIIText(text)
        return PIIDetectors.detect(source).sorted { $0.start < $1.start }.map { "\($0.label):\(source.slice($0.start, $0.end))" }
    }

    @Test func checksums() {
        #expect(PIIDetectors.cfOK("RSSMRA85H12F205Y") && !PIIDetectors.cfOK("RSSMRA85H12F205X"))
        #expect(PIIDetectors.cfOK("BNCLCU90A41H50MO"))                    // omocodia: cifre sostituite da lettere
        #expect(PIIDetectors.pivaOK("12345678903") && !PIIDetectors.pivaOK("12345678901"))
        #expect(PIIDetectors.ibanOK("IT60X0542811101000000123456") && PIIDetectors.ibanOK("IT60 X054 2811 1010 0000 0123 456"))
        #expect(!PIIDetectors.ibanOK("IT99X9999999999999999999999"))
        #expect(PIIDetectors.luhnOK("4111 1111 1111 1111") && !PIIDetectors.luhnOK("4111 1111 1111 1112"))
    }

    @Test func regexNetwork() {
        #expect(labels("Accredito su ES91 2100 0418 4502 0005 1332 come da mandato.") == ["IBAN:ES91 2100 0418 4502 0005 1332"])
        #expect(labels("Coordinate: IT60 X054 2811\n1010 0000 0123 456 presso la filiale.") == ["IBAN:IT60 X054 2811\n1010 0000 0123 456"])
        // La scadenza attaccata alla carta resta fuori; una carta con il Luhn sbagliato non è una carta.
        #expect(labels("Carta 4111 1111 1111 1111 12/26 intestata.").contains("CREDITCARDNUMBER:4111 1111 1111 1111"))
        #expect(!labels("Carta 4111 1111 1111 1112.").contains { $0.hasPrefix("CREDITCARDNUMBER") })
        #expect(labels("Cell. +39-333-123-4567 per contatti.") == ["TELEPHONENUM:+39-333-123-4567"])
        #expect(labels("Vedi https://www.studiorossi.it/contatti. Grazie").contains("URL:https://www.studiorossi.it/contatti"))
        #expect(labels("Aggiornata alla versione 2.3.55.987 del pacchetto.").isEmpty)
        #expect(labels("rete 192.168.1.0/24 e range 192.168.1.1-192.168.1.20") == ["IPADDR:192.168.1.0/24", "IPADDR:192.168.1.1-192.168.1.20"])
        #expect(labels("Prot. n. 456/2024 e Rep. 45 del notaio.") == ["DOCID:Prot. n. 456/2024", "DOCID:Rep. 45"])
        #expect(labels("Targa AB-123-CD e importo € 1.250,00").contains("TARGA:AB-123-CD"))
        #expect(labels("Targa AB-123-CD e importo € 1.250,00").contains("AMOUNT:€ 1.250,00"))
    }

    @Test func thePlaceholderIsTheSameForTheWholeChat() {
        var vault = PIIVault()
        func assign(_ label: String, _ value: String) -> String {
            let result = vault.placeholder(label: label, value: value)
            return result.placeholder + (result.isNew ? " nuovo" : "")
        }
        #expect(assign("FULLNAME", "Mario Rossi") == "[FULLNAME_1] nuovo")
        #expect(assign("FULLNAME", "  mario   ROSSI ") == "[FULLNAME_1]")
        #expect(assign("FULLNAME", "Anna Neri") == "[FULLNAME_2] nuovo")
        #expect(assign("CITY", "Roma") == "[CITY_1] nuovo")
        #expect(vault.entries.map(\.placeholder) == ["[CITY_1]", "[FULLNAME_1]", "[FULLNAME_2]"])
        let data = try? JSONEncoder().encode(vault)
        #expect(data.flatMap { try? JSONDecoder().decode(PIIVault.self, from: $0) } == vault)
    }

    @Test func revealIsTolerant() {
        var vault = PIIVault()
        _ = vault.placeholder(label: "FULLNAME", value: "Mario Rossi")
        _ = vault.placeholder(label: "CF", value: "RSSMRA85H12F205Y")
        func reveal(_ text: String) -> String { PrivacyShield.reveal(text, vault: vault) }
        #expect(reveal("Gentile [FULLNAME_1], il CF è [CF_1].") == "Gentile Mario Rossi, il CF è RSSMRA85H12F205Y.")
        // Grassetto mantenuto, parentesi con spazi, forma senza parentesi, lettera accentata attaccata.
        #expect(reveal("**[FULLNAME_1]**") == "**Mario Rossi**")
        #expect(reveal("[ FULLNAME_1 ] e FULLNAME_1 e CF_1è") == "Mario Rossi e Mario Rossi e CF_1è")
        // Un segnaposto inventato resta visibile (meglio di un valore sbagliato); FULLNAME_10 non è FULLNAME_1.
        #expect(reveal("[FULLNAME_9] e [FULLNAME_10]") == "[FULLNAME_9] e [FULLNAME_10]")
        let shield = PrivacyShield(vault: vault, destination: "Claude")
        #expect(shield.revealStreaming("Ciao [FULLNAME_1], il tuo codice è [CF_") == "Ciao Mario Rossi, il tuo codice è ")
        #expect(shield.reveal(JSONValue.object(["a": .string("[CF_1]"), "b": .array([.string("FULLNAME_1")])]))
                == .object(["a": .string("RSSMRA85H12F205Y"), "b": .array([.string("Mario Rossi")])]))
    }

    @Test func webPagesLoseOnlyTheChatsIdentities() {
        var vault = PIIVault()
        _ = vault.placeholder(label: "ORG", value: "Rossi Moto S.r.l.")
        _ = vault.placeholder(label: "FULLNAME", value: "Martina Verdi")
        _ = vault.placeholder(label: "FULLNAME", value: "Marco")
        _ = vault.placeholder(label: "CITY", value: "Roma")
        let page = "Rossi Moto S.r.l. di Roma: parla la titolare martina  verdi. Marco Bianchi commenta."
        // Di serie le aziende restano in chiaro (come nella chat): si nasconde solo chi è la persona.
        let shield = PrivacyShield(vault: vault, destination: "Claude")
        #expect(shield.mask(page) == "Rossi Moto S.r.l. di Roma: parla la titolare [FULLNAME_1]. Marco Bianchi commenta.")
        // Con le aziende tra le categorie da nascondere, anche senza «S.r.l.».
        let strict = PrivacyShield(vault: vault, destination: "Claude", labels: Set(PIICategory.sensitive).union(["ORG"]))
        #expect(strict.mask(page) == "[ORG_1] di Roma: parla la titolare [FULLNAME_1]. Marco Bianchi commenta.")
        #expect(strict.mask("Rossi Moto apre una sede a Milano.") == "[ORG_1] apre una sede a Milano.")
    }

    /// Solo i dati personali diventano segnaposto: importi, date, orari, città, aziende, siti e IP di casa restano in chiaro.
    @Test func onlyPersonalDataIsHidden() {
        let text = PIIText("Mario Rossi paga € 1.250,00 il 12/10/2026 alle 18.30 a Milano, via Garibaldi 24, a Edilnord S.r.l.; "
            + "server 192.168.1.10 e 8.8.8.8; link https://x.it/?u=anna@studio.it e 3 righe.")
        func entity(_ label: String, _ value: String) -> PIIEntity {
            let range = text.string.range(of: value)!
            let start = text.string.unicodeScalars.distance(from: text.string.unicodeScalars.startIndex, to: range.lowerBound)
            return PIIEntity(label: label, start: start, end: start + value.unicodeScalars.count, score: 0.9, validated: false, source: .model)
        }
        let found = [entity("FULLNAME", "Mario Rossi"), entity("AMOUNT", "€ 1.250,00"), entity("DATE", "12/10/2026"), entity("TIME", "18.30"),
                     entity("CITY", "Milano"), entity("STREET", "via Garibaldi"), entity("BUILDINGNUM", "24"), entity("ORG", "Edilnord S.r.l."),
                     entity("IPADDR", "192.168.1.10"), entity("IPADDR", "8.8.8.8"), entity("URL", "https://x.it/?u=anna@studio.it"),
                     entity("BUILDINGNUM", "3 ")]
        func hidden(_ labels: Set<String>) -> [String] {
            PrivacyShield.masked(found, in: text, labels: labels).map { "\($0.label):\(text.slice($0.start, $0.end))" }
        }
        #expect(hidden(Set(PIICategory.sensitive)) == ["FULLNAME:Mario Rossi", "STREET:via Garibaldi", "BUILDINGNUM:24", "IPADDR:8.8.8.8", "EMAIL:anna@studio.it"])
        // Scelti nelle Impostazioni: anche importi e aziende.
        #expect(hidden(Set(PIICategory.sensitive).union(["AMOUNT", "ORG"])).contains("AMOUNT:€ 1.250,00"))
        #expect(hidden(Set(PIICategory.sensitive).union(["AMOUNT", "ORG"])).contains("ORG:Edilnord S.r.l."))
        #expect(PrivacyShield.isLocalAddress("127.0.0.1") && PrivacyShield.isLocalAddress("172.20.0.5") && PrivacyShield.isLocalAddress("192.168.1.0/24"))
        #expect(!PrivacyShield.isLocalAddress("8.8.8.8") && !PrivacyShield.isLocalAddress("172.32.0.1"))
        #expect(Set(PIICategory.sensitive).isDisjoint(with: PIICategory.workingData))
    }

    @Test func paragraphsRejoinToTheSameText() {
        let text = String(repeating: "Riga di testo abbastanza lunga per superare la soglia. ", count: 8) + "\n\n  \nSecondo paragrafo.\n\nTerzo."
        #expect(PrivacyShield.paragraphs(text).joined() == text && PrivacyShield.paragraphs(text).count == 3)
    }

    // MARK: Con il motore installato

    /// Casi della pipeline Python originale (rizzo-pii 2.0.0, modello v1.5.0): il porting deve dare lo stesso testo.
    @Test(.enabled(if: PIIEngine.isInstalled)) func sameResultsAsTheOriginal() async throws {
        let cases = [
            ("Il Sig. Mario Rossi, C.F. RSSMRA85H12F205Y, P.IVA 12345678903, è titolare dell'immobile al Foglio 12, particella 345, sub. 6.",
             "Il Sig. [FULLNAME_1], C.F. [CF_1], P.IVA [PIVA_1], è titolare dell'immobile al Foglio [CATASTO_1], particella [CATASTO_2], sub. [CATASTO_3]."),
            ("Bonifico di € 12.500,00 sull'IBAN IT60X0542811101000000123456 intestato a Edilnord S.r.l., via Garibaldi 24, 20121 Milano (MI).",
             "Bonifico di [AMOUNT_1] sull'IBAN [IBAN_1] intestato a [ORG_1]., [STREET_1] [BUILDINGNUM_1], [ZIPCODE_1] [CITY_1] ([PROVINCE_1])."),
            ("Per info scrivi a luca.verdi@studioverdi.it o chiama il 333 123 4567; targa del veicolo AB123CD, carta 4111 1111 1111 1111.",
             "Per info scrivi a [EMAIL_1] o chiama il [TELEPHONENUM_1]; targa del veicolo [TARGA_1], carta [CREDITCARDNUMBER_1]."),
            ("Ciao Marco, ci vediamo domani alle 18.30 davanti al bar di Piazza Navona? Porta il contratto firmato da Elena.",
             "Ciao [FULLNAME_1], ci vediamo domani alle [TIME_1] davanti al bar di [STREET_1]? Porta il contratto firmato da [FULLNAME_2]."),
            ("Coordinate: IT60 X054 2811\n1010 0000 0123 456 presso la filiale.", "Coordinate: [IBAN_1] presso la filiale."),
            ("Connessione in ingresso da 8.8.8.8 registrata nel log; rete 192.168.1.0/24 e range 192.168.1.1-192.168.1.20.",
             "Connessione in ingresso da [IPADDR_1] registrata nel log; rete [IPADDR_2] e range [IPADDR_3]."),
        ]
        for (text, expected) in cases {
            let (result, _) = try await PIIEngine.shared.anonymize(text, vault: PIIVault())
            #expect(result.text == expected)
        }
    }

    /// Andata e ritorno con lo scudo: stessi segnaposto nella chat, data di oggi in chiaro, risposta ricostruita.
    @Test(.enabled(if: PIIEngine.isInstalled)) func roundTripThroughTheShield() async throws {
        let shield = PrivacyShield(vault: PIIVault(), destination: "Claude")
        let system = "Sei Siri AI+. Adesso è gio 2026-09-25 13:05. Prossimi giorni:\n- venerdì 2026-09-26 (domani)"
        let (safeSystem, _, prompt) = try await shield.protect(system: system, history: [],
                                                              prompt: "Scrivi a Mario Rossi (mario.rossi@studio.it) che il bonifico di € 1.250,00 su IT60X0542811101000000123456 è partito il 12/09/2026.")
        #expect(safeSystem.contains("Adesso è gio 2026-09-25 13:05") && safeSystem.contains("- venerdì 2026-09-26 (domani)"))
        #expect(!prompt.contains("Mario Rossi") && !prompt.contains("mario.rossi@studio.it") && !prompt.contains("IT60X0542811101000000123456"))
        #expect(prompt.contains("[FULLNAME_1]") && prompt.contains("[EMAIL_1]") && prompt.contains("[IBAN_1]"))
        // Importo e data servono all'AI: restano in chiaro.
        #expect(prompt.contains("€ 1.250,00") && prompt.contains("12/09/2026"))
        // Lo stesso nome più tardi ha lo stesso segnaposto; la risposta del modello torna leggibile.
        let later = try await shield.protect("Mario Rossi ha risposto?")
        #expect(later.hasPrefix("[FULLNAME_1]"))
        let answer = shield.learn(anonymized: "Ho scritto a **[FULLNAME_1]** all'indirizzo [EMAIL_1].")
        #expect(answer == "Ho scritto a **Mario Rossi** all'indirizzo mario.rossi@studio.it.")
        // La risposta ricostruita, quando torna nella cronologia, si rimanda com'era (senza rianalizzarla).
        #expect(try await shield.protect(answer) == "Ho scritto a **[FULLNAME_1]** all'indirizzo [EMAIL_1].")
        let report = try #require(shield.takeReport())
        #expect(report.counts["FULLNAME"] == 1 && report.counts["IBAN"] == 1 && report.values["[FULLNAME_1]"] == "Mario Rossi")
        #expect(shield.takeReport() == nil)
    }
}
