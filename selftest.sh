#!/bin/zsh
# Regressione end-to-end del pianificatore con il modello vero: ogni richiesta deve scegliere l'azione attesa.
# Uso: ./selftest.sh   (l'app deve essere compilata; non modifica dati: SIRIAI_PLAN_ONLY=1)
set -uo pipefail
cd "$(dirname "$0")"
APP="Siri AI+.app"
LOG="$HOME/Library/Logs/Siri AI+.log"
touch "$LOG"

# Progetto finto per le richieste sui file.
PROJECT="$(mktemp -d)/Progetto test"
mkdir -p "$PROJECT/4_Archivio" "$PROJECT/2_Aree/linkedin/29-quattro-errori-file-stato"
print "# Stato" > "$PROJECT/STATE.md"; print "# Leggimi" > "$PROJECT/README.md"; print -r -- "- [ ] uno" > "$PROJECT/TASKS.md"
print "# Obiettivi Q3" > "$PROJECT/OBJECTIVES.md"

# richiesta|azione attesa (più azioni ammesse separate da /)
CASES=(
  "ciao come stai?|rispondi"
  "spiegami la fotosintesi in due righe|rispondi"
  "cosa ho domani?|agenda/eventi"
  "che impegni ho questa settimana?|agenda/eventi"
  "fissa una riunione con Marco domani alle 15|crea_evento"
  "ricordami di chiamare il commercialista venerdì|crea_promemoria"
  "ricordati che preferisco le riunioni al mattino|ricorda"
  "scrivi un'email a Giulia per spostare la call a lunedì|scrivi_email"
  "ho nuove email da Mario?|mail_leggi"
  "cerca nelle note la lista della spesa|note"
  "crea una presentazione sul lancio del prodotto|crea_presentazione"
  "prepara un foglio con il budget del viaggio a Lisbona|crea_foglio"
  "cerca su internet le ultime notizie su Apple|cerca_web"
  "chi ha vinto l'ultimo Gran Premio di Monza?|cerca_web/rispondi"
  "apri il sito apple.com|naviga"
  "disegna un gatto astronauta|genera_immagine"
  "crea un agente che ogni mattina mi riassume le email|crea_agente"
  "apri una nuova chat sulle vacanze|nuova_chat"
  "crea una landing page per una pizzeria|crea_sito"
  "quali file ci sono nel progetto?|file_elenca"
  "leggi il file degli obiettivi|file_leggi"
  "riassumi TASKS.md|file_leggi"
  "sposta README.md nella cartella 4_Archivio|file_sposta"
  "rinomina STATE.md in stato|file_sposta"
  "aggiungi a TASKS.md il task: chiamare il commercialista|file_scrivi"
)

PROMPTS=""
for c in "${CASES[@]}"; do PROMPTS+="${c%%|*}||"; done
PROMPTS="${PROMPTS%||}"

START=$(wc -l < "$LOG" 2>/dev/null || echo 0)
open -W -n --env SIRIAI_PLAN_ONLY=1 --env "SIRIAI_TEST_PROJECT=$PROJECT" "$APP" --args --selftest "$PROMPTS"

pass=0; fail=0
lines=("${(@f)$(tail -n +$((START + 1)) "$LOG")}")
for c in "${CASES[@]}"; do
  prompt="${c%%|*}"; expected="${c##*|}"
  chosen=""
  found=0
  for line in "${lines[@]}"; do
    if [[ "$line" == *"PROMPT: $prompt" ]]; then found=1; continue; fi
    if (( found )) && [[ "$line" == *"PIANO: "* ]]; then chosen="${${line##*PIANO: }%% *}"; break; fi
  done
  if [[ "/$expected/" == *"/$chosen/"* ]]; then
    pass=$((pass + 1)); print "✅ $prompt → $chosen"
  else
    fail=$((fail + 1)); print "❌ $prompt → ${chosen:-nessun piano} (atteso $expected)"
  fi
done
print "Errori del pianificatore: $(tail -n +$((START + 1)) "$LOG" | grep -c "ERRORE PIANIFICATORE")"
print "Risultato: $pass passati, $fail falliti"
(( fail == 0 ))
