# Banco di prova per la versione Swift di rizzo-pii: testi realistici e casi limite dei test originali.
LONG = (
    "Tribunale di Milano, Sezione Lavoro. R.G. n. 4521/2023. Ricorso ex art. 414 c.p.c. promosso da Giovanni Esposito, "
    "nato a Napoli il 14/05/1978, C.F. SPSGNN78E14F839X, residente in Via Toledo 256, 80134 Napoli (NA), rappresentato e difeso "
    "dall'avv. Francesca Marino del Foro di Milano, con studio in Corso Buenos Aires 45, 20124 Milano, PEC francesca.marino@pec.avvocati.it, "
    "tel. 02 8765 4321, contro Logistica Nord S.p.A., P.IVA 07643520567, in persona del legale rappresentante pro tempore Dott. Paolo Ferri. "
    "Il ricorrente è stato assunto il 01/09/2015 con qualifica di magazziniere e ha percepito una retribuzione mensile di € 1.850,00 lordi. "
    "In data 12 marzo 2023, alle ore 18:45, veniva comunicato il licenziamento a mezzo raccomandata. Il ricorrente chiede il pagamento di "
    "€ 23.450,00 a titolo di differenze retributive, da accreditare sull'IBAN IT40 S054 2811 1010 0000 0123 456. "
    "Si allega copia della carta d'identità n. CA12345AB e del libretto del veicolo targato FG 812 KL. "
    "Ulteriori comunicazioni potranno essere inviate a giovanni.esposito78@gmail.com oppure al cellulare +39 347 555 1234. "
    "Il giudice designato, dott.ssa Laura Conti, fissa l'udienza di discussione per il giorno 18/01/2024 alle ore 9:30, "
    "aula 5, piano terra. Milano, 20 novembre 2023. Firmato digitalmente dal cancelliere Marco Galli."
)
TEXTS = [
    "Il Sig. Mario Rossi, C.F. RSSMRA85H12F205Y, P.IVA 12345678903, è titolare dell'immobile al Foglio 12, particella 345, sub. 6.",
    "Gentile avv. Giulia Bianchi, le confermo l'udienza del 12/03/2025 alle ore 10:30 presso il Tribunale di Milano, R.G. 1234/2024.",
    "Bonifico di € 12.500,00 sull'IBAN IT60X0542811101000000123456 intestato a Edilnord S.r.l., via Garibaldi 24, 20121 Milano (MI).",
    "Per info scrivi a luca.verdi@studioverdi.it o chiama il 333 123 4567; targa del veicolo AB123CD, carta 4111 1111 1111 1111.",
    "La paziente Anna Neri, 45 anni, femmina, residente in Corso Vittorio Emanuele 10 a Torino, è stata visitata il 3 febbraio 2024.",
    "Ciao Marco, ci vediamo domani alle 18.30 davanti al bar di Piazza Navona? Porta il contratto firmato da Elena.",
    "Fattura n. 245/2024 del 15/06/2024 emessa da Studio Grafico Luna di Sara Colombo, P.IVA 01234567897, importo 1.220,00 €.",
    "Accredito su ES91 2100 0418 4502 0005 1332 come da mandato.",
    "Coordinate: IT60 X054 2811\n1010 0000 0123 456 presso la filiale.",
    "Codice IT99 X999 9999 9999 9999 9999 999 da verificare.",
    "Codice commessa GR14 0172 7402 1280 riferimento interno.",
    "C.F. RSSMRA85H12F2LRA del ricorrente.",
    "Codice fiscale BNCLCU90A41H50MO del richiedente.",
    "Carta 4111 1111 1111 1111 12/26 intestata.",
    "Carta 4111-1111-1111-1111 intestata al ricorrente.",
    "Carta 4111 1111 1111 1112.",
    "Codice pratica 1234567890123456789 del 2024.",
    "Cell. +39-333-123-4567 per contatti.",
    "Cell. 333-123-4567 per contatti, fisso 010-2471234.",
    "Accesso registrato alle 09:50:12.",
    "Deposito 28/02/2024 09:15 allo sportello.",
    "Deposito telematico: 2026-03-15T10:30:00 (ricevuta PEC).",
    "Contratto stipulato il 01-12-2020.",
    "Atto a repertorio 8891/2022 registrato.",
    "Prot. n. 456/2024 e Rep. 45 del notaio.",
    "Ai sensi dell'art. 2043 c.c. per euro 1.250,00.",
    "Cfr. pagg. 12-15, punti 3.4.5 e 6.7.8 della memoria.",
    "Aggiornata alla versione 2.3.55.987 del pacchetto.",
    "Connessione in ingresso da 8.8.8.8 registrata nel log; rete 192.168.1.0/24 e range 192.168.1.1-192.168.1.20.",
    "Vedi https://www.studiorossi.it/contatti. Oppure www.esempio.com e anche rossimoto.it per il listino.",
    "Come da mandato il 17 luglio 2008 conferito a Mario Rossi.",
    "Direzione Provinciale di Novara, ufficio del registro di Novara.",
    "Il sottoscritto Luca Bianchi, nato a Roma il 21/04/1990, CF BNCLCU90A41H50MO, dichiara di essere nubile.",
    "Scala 1:25, Giovanni 3:16, versione 1.30 del software, euro 10.30 di resto.",
    "Riunione con Martina Verdi di Rossi Moto S.r.l. alle ore 15:00 in via dei Mille 12, Roma: portare il preventivo da 3.400 €.",
    "Passaporto n. YA1234567 rilasciato alla signora Chiara Ricci; patente U1B23456789K.",
    "Email: m.rossi@studio.it; PEC: studio.rossi@legalmail.it; tel. 06 1234567.",
    "Ho parlato con Giuseppe e Francesca: il 20% dell'importo va a Giuseppe, il resto a Francesca Russo.",
    "Nessun dato personale in questa frase, solo un testo qualunque sul tempo di oggi.",
    "Il cliente 🚗 Andrea Gallo (età 32) ha lasciato un feedback: «ottimo servizio!» ✅ — tel. 345 678 9012.",
    "Righe di tabella:\nNome\tCognome\tTelefono\nMario\tRossi\t333 111 2222\nLuisa\tBianchi\t333 333 4444",
    "L'ing. Roberto Moretti, dello studio Moretti & Associati, ha visionato l'immobile in Via Roma 1, 10121 Torino (TO) il 5/5/2023.",
    LONG,
    LONG.replace("Giovanni Esposito", "Giovanni  Esposito").replace(". ", ".\n\n", 3),
]
