# Prove del coding harness

Esegui `./test.sh --filter CodeHarnessEvaluationTests` per i quattro scenari di integrazione, oppure `./test.sh` per la suite intera. Lo script copia sorgenti e test in una directory temporanea prima di compilare: nella cartella Documenti sincronizzata con iCloud, Swift può perdere l'accesso ai file durante la build.

| Scenario | Verifica |
| --- | --- |
| Task isolata: modifica, aggiunta, cancellazione, diff, applicazione | La cartella originale resta intatta fino al comando di applicazione; il diff e i conteggi sono corretti; una modifica successiva alla revisione e una seconda applicazione sono bloccate. |
| Due task parallele | Ogni copia contiene il proprio cambiamento e l'originale resta invariato. |
| Progetto sporco o avanzato | Non si crea una copia da un progetto con modifiche locali e non si applica una copia sopra modifiche locali. |
| Task diretta | Il diff deriva dal punto di ripristino precedente alla richiesta. |

Queste prove usano repository Git temporanei e modifiche deterministiche. Verificano l'infrastruttura di isolamento e revisione, non la qualità delle risposte di Codex. Una valutazione del motore reale richiede task campione su progetti di app/siti, criteri di successo osservabili, tempi/costi e un ambiente di esecuzione controllato; non viene dichiarata come eseguita qui.
