# Verifica del companion · 26 settembre 2026

Il banco di prova `companion-quotidiano.json`, eseguito con Apple Intelligence sul Mac e dati isolati, ha superato **9 casi su 9** nell'ultima esecuzione completa (tempo mediano: **3,9 s**). Un tentativo nel sandbox privo di accesso al servizio del modello ha restituito l'errore di sistema `ModelManagerError 1008`; con i permessi del sistema i nove casi sono riusciti.

| Categoria | Esito |
| --- | --- |
| Ragionamento | 2/2 |
| Contesto della conversazione | 2/2 |
| Lettura di un documento | 1/1 |
| Testo esterno con istruzione avversaria | 1/1 |
| Distinzione tra bozza e invio | 1/1 |
| Richiesta con bersaglio ambiguo | 1/1 |
| Istruzione di risposta scambiata per email | 1/1 |

La suite Swift ha superato **223 test in 43 gruppi**. Un collaudo sulla copia installata ha trovato una falsa bozza email per “Rispondi solo: prova riuscita.”; è stato aggiunto un test e corretto l'instradamento. Il bundle macOS nativo è stato compilato con Xcode; lo ZIP estratto ha superato `codesign --verify --deep --strict` e contiene i metadati delle azioni “Apri Siri AI+” e “Chiedi a Siri AI+”. Una prima firma locale rendeva le azioni visibili ma non eseguibili: i log di macOS indicavano l'assenza del Team ID. La build ora sceglie il certificato Apple Development disponibile; la copia in `/Applications/Siri AI+.app` è stata verificata con `codesign` (Team ID `59N39XDU3G`) e registrata in LaunchServices.

Nella chat rapida installata, la richiesta di prova in *Lavoro* ha restituito solo **«prova riuscita.»** e quella in *Personale* solo **«personale attivo.»**. Le due cronologie sono rimaste separate dopo “Esci” e la riapertura dell'app con gli stessi dati di test. La conferma ChatGPT ha mostrato per intero la richiesta e l'istruzione di servizio senza inviare dati; il pulsante è rimasto disattivato perché il motore di anonimizzazione non è installato. Il pannello e la conferma sono stati controllati visivamente dopo il riallineamento alla grafica blu e ai componenti della Home.

Con l'app firmata Apple già aperta sui dati di test, **“Apri Siri AI+”** eseguito da Comandi Rapidi ha mostrato il pannello. **“Chiedi a Siri AI+”** ha aggiunto nella chat *Lavoro* la richiesta sintetica e la risposta **«azione riuscita.»** senza errori. Nella build finale, dopo aver scelto *Personale* nel pannello, lo stesso comando ha inviato la nuova richiesta proprio alla chat *Personale*, che ha mostrato **«personale confermato.»**. **“Apri Siri AI+”** ha aperto il pannello anche con l'app completamente chiusa. È rimasto nella libreria un comando di prova chiamato **“Siri AI+ · Prova azioni”**, con entrambe le azioni e una richiesta sintetica; macOS avverte che eliminarlo lo rimuoverebbe da tutti i dispositivi iCloud, quindi il test non lo ha cancellato.

Questo campione verifica solo i casi sintetici elencati. Prima di dichiarare raggiunto il criterio del **100% sui bersagli personali**, occorrono prove con permessi concessi e negati, campi protetti e selezione cambiata. La simulazione di ⌥⌘K non ha prodotto un risultato osservabile: la scorciatoia va provata con la tastiera reale. Di Comandi Rapidi resta da provare soltanto **“Chiedi a Siri AI+”** con l'app chiusa e dati isolati. Restano anche il collaudo di risveglio e arresto degli agenti. Private Cloud Compute richiede un'autorizzazione Apple effettiva e un test con l'app firmata che la possiede.

Nell'ultima build è stato corretto anche il caso in cui il salvataggio della presa in carico di una routine fallisce: lo stato in memoria torna a quello precedente e l'agente non parte. La build Xcode e la verifica della firma installata sono riuscite dopo questa correzione; il collaudo sul risveglio reale resta aperto.

Il pulsante **Screenshot** apre il selettore di macOS; all'apertura della chat rapida non compare alcuna cattura. Il pannello resta visibile mentre il selettore è aperto. L'annullamento simulato tramite il controllo UI non equivale a premere Esc sul selettore di sistema: il ritorno al pannello dopo un annullamento fisico e la cattura scelta dall'utente restano da confermare.

## Prove manuali ancora da registrare

1. Usare ⌥⌘K e ⌥⌘V con la tastiera reale da un'altra app.
2. In un'app mai autorizzata selezionare testo: non deve essere letto. Autorizzarla esplicitamente, riprovare e controllare provenienza, anteprima e rimozione; ripetere in un campo protetto.
3. Proporre una sostituzione, confermarla e rileggere il campo. Ripetere cambiando la selezione prima della conferma: la seconda modifica deve fermarsi. In un campo non scrivibile deve comparire il testo da copiare.
4. Chiedere una cattura solo tramite il pulsante; ripetere l'anteprima ChatGPT o Claude con un motore di anonimizzazione disponibile e confrontare il testo effettivamente trasmesso con quello consentito.
5. Eseguire “Chiedi a Siri AI+” con l'app chiusa, su dati isolati. Provare risveglio e arresto con una routine di test, verificando lo storico senza duplicati.
