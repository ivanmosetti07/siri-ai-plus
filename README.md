<p align="center">
  <img src="Support/AppIcon.png" width="140" alt="Siri AI+">
</p>

<h1 align="center">Siri AI+</h1>

<p align="center">
  <b>The Siri AI that Apple should have shipped.</b><br>
  An AI assistant for the Mac built on Apple Intelligence, wired into your Apple apps, local first and privacy safe.<br>
  <sub>A hobby project, made in Italy 🇮🇹 on a Sunday and a few evenings.</sub>
</p>

<p align="center">
  <a href="https://github.com/ivanmosetti07/siri-ai-plus/releases/latest"><img src="https://img.shields.io/github/v/release/ivanmosetti07/siri-ai-plus?label=download&color=0A84FF" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-27-000000?logo=apple&logoColor=white" alt="macOS 27">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/Apple%20Intelligence-on%20device-8E44AD" alt="Apple Intelligence on device">
  <a href="LICENSE.md"><img src="https://img.shields.io/badge/license-PolyForm%20Noncommercial-2EA44F" alt="License: PolyForm Noncommercial"></a>
  <a href="https://github.com/ivanmosetti07/siri-ai-plus/stargazers"><img src="https://img.shields.io/github/stars/ivanmosetti07/siri-ai-plus?style=social" alt="GitHub stars"></a>
</p>

<p align="center">
  <a href="https://github.com/ivanmosetti07/siri-ai-plus/releases/latest"><b>⬇️ Download</b></a> ·
  <a href="#-english">English</a> ·
  <a href="#-italiano">Italiano</a> ·
  <a href="https://github.com/ivanmosetti07/siri-ai-plus/issues/new">🐛 Report a bug</a> ·
  <a href="https://github.com/ivanmosetti07/siri-ai-plus/discussions">💬 Discussions</a>
</p>

<p align="center">
  ⭐ <b>If you like it, leave a star!</b> It's free and helps other people find it.<br>
  ⭐ <b>Se ti piace, lascia una stella!</b> È gratis e aiuta altre persone a trovarlo.
</p>

> [!NOTE]
> Siri AI+ is an independent hobby project. It is not affiliated with, endorsed by, or sponsored by Apple Inc. Siri, Apple Intelligence, Xcode, Safari, Pages, Numbers and Keynote are trademarks of Apple Inc.
>
> 🙏 *Dear Apple, please don't sue me. Copy it, buy it… nah, just don't sue me: I only made it for fun. I'm just a pirate, a little hungry and a little foolish 🏴‍☠️😅*<br>
> 🙏 *Ti prego Apple, non denunciarmi. Copiala, comprala… na, non denunciarmi: l'ho fatta solo per gioco. Sono solo un pirata, un po' affamato e un po' folle ahahah 🏴‍☠️😅*

---

## 🇬🇧 English

### What is this?

Picture the Siri we've all been waiting for. It actually reads your calendar, answers your email, keeps your notes tidy, works inside your project folders, builds apps with Xcode, and chats like the best desktop AI apps. That's Siri AI+. 🪄

The goal: publish the Siri AI that Apple should have launched. It's fully integrated with the Apple apps, Xcode included, and has the basic features you expect from the best AI apps like Claude or ChatGPT Desktop. Above all, it **brings AI to everyone** with local AI, on the Mac you already own.

It runs on **Apple Intelligence**, right on your Mac: no account, no subscription, and nothing leaves your computer. When Apple's small on-device model isn't enough, you can plug in bigger brains. Local ones like Gemma 4 and ds4 stay on your Mac. With your own Claude or ChatGPT subscription, a privacy shield anonymizes your personal data before anything leaves the Mac.

> [!IMPORTANT]
> The interface speaks **Italian** for now 🇮🇹. Translations are very welcome!

### What it can do

- 💬 **Chat like the big ones.**
  - Chats, projects, side-by-side chats (up to 4) and child chats.
  - ⌘K search, voice mode and dictation.
  - File and image attachments, and web search with numbered sources.
  - Memory, skills, and a "How I worked" trace under every answer.
- 🍎 **Your Apple apps, inside the chat.**
  - Calendar, Reminders, Mail, Notes, Messages, Contacts, Voice Memos, Files and a built-in Safari.
  - They open as tabs next to the chat, and every chat keeps its own open apps.
  - Say "move tomorrow's meeting to 4 pm" or "reply to Mario that Thursday works" and you get a card to confirm. **Nothing is written or sent without your OK**, and you can undo for 10 minutes.
- 📄 **Documents, sheets and slides.** Editors in the style of Pages, Numbers and Keynote that the AI can write and change ("add a slide on next steps", "make a pie chart").
- 📁 **Projects.**
  - Link a folder and the chat uses it as context: AGENTS.md or CLAUDE.md, file maps, daily logs.
  - An Obsidian-style graph shows your notes as a brain.
- 🛠️ **Coding space, Xcode included.**
  - Create websites, web apps and SwiftUI apps for Mac and iPhone with any model.
  - Live preview in the session's own Safari, showing console errors, with a "Fix" button.
  - Restore points, a diff review, and "Open in Xcode" for native apps.
- 🤖 **Agents.**
  - Give them a name, a goal and a schedule.
  - They plan, use sub-agents, ask before important actions and keep a log.
  - At night they "dream" to learn from their mistakes.
- 🧩 **MCP connectors.** Local or remote servers (with OAuth login), which you can import from Claude Desktop.
- 🧠 **A harness built for small models.**
  - A sub-agent picks the right tools for every request.
  - Complex tasks become plans that sub-agents run in parallel.
  - Sub-agents compact long conversations.
  - Code, not the model, does exact math (dates, times, totals).

### The models

| Model | Where it runs | Privacy | Notes |
|---|---|---|---|
| **Apple Intelligence** | On your Mac | 🔒 Nothing leaves the Mac | The default, free. Small model (about 4K tokens of context on my M2 Pro), so Siri AI+ squeezes every drop out of it |
| **Gemma 4** | On your Mac (llama.cpp) | 🔒 Nothing leaves the Mac | Pick the size for your memory: E2B (any Mac), E4B (12 GB+), 12B (16 GB+), 26B A4B (32 GB+), 31B (48 GB+) |
| **ds4** by [@antirez](https://github.com/antirez) | On your Mac | 🔒 Nothing leaves the Mac | Very powerful models (DeepSeek V4 Flash) on high-end hardware: 96 GB or more of unified memory |
| **ChatGPT** | OpenAI cloud, with your subscription (Codex CLI) | 🛡️ Personal data anonymized first | Pick version and reasoning for each chat |
| **Claude** | Anthropic cloud, with your subscription (Claude Code CLI) | 🛡️ Personal data anonymized first | Pick version and reasoning for each chat |

Every chat remembers its model. Whatever model answers, Apple Intelligence picks the tools for each request, on your Mac and for free.

#### 🙏 A note on ds4

Confession: my computer isn't powerful enough for [ds4](https://github.com/antirez/ds4), so I've never been able to test it inside Siri AI+. If you try it, please let me know how it goes (an issue is perfect). Maybe even you, Salvatore ([@antirez](https://github.com/antirez))… *famme sape'!* 😄

### 🛡️ The privacy shield, thanks to rizzo-pii

Claude and ChatGPT are great, but your text ends up on someone else's servers, so privacy isn't guaranteed. Apple would never approve 😅. That's why Siri AI+ has a privacy shield. It's built on [rizzo-pii](https://github.com/Rizzo-AI-Academy/rizzo-pii), the open source anonymizer by Simone Rizzo ([@simone-rizzo](https://github.com/simone-rizzo)) and Rizzo AI Academy.

Whenever personal data is detected, the Mac swaps it for a placeholder before the text goes to Claude or ChatGPT. When the answer comes back, the real data is put back in. A real run (the app speaks Italian):

```text
You write:        Scrivi a Mario Rossi (mario.rossi@studio.it) che la fattura da 1.200 € scade il 15 ottobre, IBAN IT60X0542811101000000123456
What leaves:      Scrivi a [FULLNAME_1] ([EMAIL_1]) che la fattura da 1.200 € scade il 15 ottobre, IBAN [IBAN_1]
What you read:    the answer, with the real name, email and IBAN put back on your Mac
```

- **Hidden:** names, emails, phone numbers, tax and VAT codes, ID documents, IBANs, cards, home addresses, license plates, land registry data and public IP addresses.
- **Kept readable:** amounts, dates, times, cities, companies and websites. Without them the AI couldn't do its job. You can hide them too in Settings.
- **Everything is covered:** your messages, chat history, memory, project instructions, files, email and tool results.
- **The dictionary stays on your Mac.** If the anonymizer isn't installed or fails, **nothing is sent** and Apple Intelligence answers instead.
- **It runs locally with Core ML.** The rizzo-pii model is converted to Core ML and its rules are rewritten in Swift, with the same results as the original. It takes about 40 ms for every 120 words.
- **Not covered yet:** the coding space, where Codex and Claude Code read your project files directly.

### 🇪🇺 Why Europe, and why it matters

In June 2026 Apple announced that [the new Siri AI won't ship in the EU on iPhone, iPad and Apple Watch](https://www.apple.com/newsroom/2026/06/due-to-dma-siri-ai-delayed-in-eu-for-ios-27-and-ipados-27/) because of the **Digital Markets Act (DMA)**.

- **What the DMA asks:** Apple is a "gatekeeper", so it must open its platform to other services.
- **Apple's reading:** it would have to give any third-party assistant the same deep access to your messages, data and apps that Siri AI has, and Apple sees that as a privacy and security risk.
- **Apple's proposal:** a middle layer called a "Trusted System Agent". The European Commission said no, and [replied](https://www.euronews.com/next/2026/06/11/the-eus-dma-fines-delayed-features-and-unclear-benefits) that "absolutely nothing in the DMA prohibits Apple from introducing new products in the EU".
- **The result:** there is no date for iPhone and iPad. On the Mac, Siri AI is available in the EU.

Apps like this one get Apple's small on-device model. Apple's bigger model on Private Cloud Compute needs a special permission from Apple. Siri AI+ is already usable as it is. We're just waiting for the more powerful models to be unlocked here in Europe too, and then it will be even more complete.

My two cents: Siri AI+ is open to other models, both local and cloud. Personal data is anonymized on the Mac before it leaves, and nothing happens without your confirmation. Maybe this is how openness and privacy can live together, and how Apple could land in Europe without any drama. Apple, call me 😄

### ⬇️ Download and install

**Requirements:**
- a Mac with Apple silicon;
- **macOS 27**;
- Apple Intelligence turned on (System Settings › Apple Intelligence & Siri).

**Option 1: the ready-made app**

1. Download `Siri-AI-Plus-macOS.zip` from the [latest release](https://github.com/ivanmosetti07/siri-ai-plus/releases/latest).
2. Unzip it and drag **Siri AI+** into **Applications**.
3. The app isn't notarized by Apple, because that takes a paid developer account, so macOS blocks it the first time. Open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**. Or use Terminal:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Siri AI+.app"
   ```

**Option 2: build it yourself** (needs Xcode 27)

```bash
git clone https://github.com/ivanmosetti07/siri-ai-plus.git
cd siri-ai-plus
./build.sh
cp -R "Siri AI+.app" /Applications/
```

`build.sh` signs the app with the first code signing certificate on your Mac. Without one it uses an ad hoc signature, and then macOS asks for the permissions again after every build.

### 🚀 How to use it

1. **First launch.** Choose which sources Siri AI+ can use (Calendar, Reminders, Mail, Notes…) and whether it can only read them or also edit. macOS asks for each permission once. Messages and Voice Memos need Full Disk Access, and Mail is much faster with it.
2. **Just ask**, in Italian for now:
   - «Cosa ho domani?» (what's on tomorrow?)
   - «Ricordami di chiamare il commercialista venerdì» (remind me to call the accountant on Friday)
   - «Rispondi a Mario che giovedì va bene» (reply to Mario that Thursday works)
   - «Crea una presentazione sul lancio del prodotto» (make a presentation about the product launch)
   - «Cerca sul web le ultime notizie su Apple» (search the web for the latest Apple news)
3. **Confirm.** Anything that writes, sends or deletes shows up as a card, and you decide.
4. **Shortcuts:**

   | Shortcut | Action |
   |---|---|
   | ⌘N | New chat |
   | ⌘K | Search |
   | ⌥⌘A | Apps in tabs |
   | ⌥⌘N | Side-by-side chats |
   | ⇧⌘N | Child chat |
   | ⌥⌘V | Voice mode |
   | ⌥⌘S | Show or hide the side chat |

5. **Spaces.** Switch between Personal, Work and Coding next to the name in the sidebar. Each space has its own chats, projects, agents, calendars and model.
6. **Change model** from the model panel in the text field. Every chat keeps its own model, version and reasoning level.

**Optional extras**, in Settings › Models:

- **Gemma 4:** installs llama.cpp with Homebrew and downloads the version recommended for your Mac.
- **ds4:** on Macs with 96 GB or more, it downloads and builds [antirez/ds4](https://github.com/antirez/ds4), then downloads the model.
- **ChatGPT and Claude:** install the official Codex and Claude Code CLIs, then log in with your own subscription in the browser.
- **The privacy shield**, required for ChatGPT and Claude. Run it once from the repository folder. It needs [pipx](https://pipx.pypa.io) (`brew install pipx`) and Xcode:

  ```bash
  Support/rizzo-pii/install.sh
  ```

For developers, the technical guide is in Italian: [docs/GUIDA-TECNICA.md](docs/GUIDA-TECNICA.md). It covers the architecture, the test benches and the diagnostic flags. To run the tests: `./test.sh`.

### 🐛 Known issues

I built this on a Sunday and a few evenings, just for fun, so there are bugs. The ones I know about:

- The interface is in Italian only.
- Apple's small on-device model still trips on trick questions and very long texts. The harness helps a lot, but it's a 3-billion-parameter model.
- The release isn't notarized, so macOS complains the first time.
- The privacy shield doesn't cover the coding space.
- ds4 is untested (see above 🙏).

Found something? Open an [issue](https://github.com/ivanmosetti07/siri-ai-plus/issues). Pull requests are welcome.

### ⭐ Support the project

- ⭐ **Star the repo** with the button at the top right. It's free, it motivates me, and it helps other people find Siri AI+.
- 👀 **Watch › Custom › Releases** to get a notification when a new version comes out.
- 🐛 **Found a bug?** [Open an issue](https://github.com/ivanmosetti07/siri-ai-plus/issues/new).
- 💡 **Got an idea or a question?** Join the [Discussions](https://github.com/ivanmosetti07/siri-ai-plus/discussions).
- 🍴 **Fork it** and experiment, for non-commercial use (see the license). Pull requests are welcome, starting with an English translation!
- 📣 **Share it** on [X](https://twitter.com/intent/tweet?text=Siri%20AI%2B%3A%20the%20Siri%20AI%20Apple%20should%20have%20shipped%20%F0%9F%8D%8E&url=https%3A%2F%2Fgithub.com%2Fivanmosetti07%2Fsiri-ai-plus) or [LinkedIn](https://www.linkedin.com/sharing/share-offsite/?url=https%3A%2F%2Fgithub.com%2Fivanmosetti07%2Fsiri-ai-plus).
- 👤 **Follow me** on GitHub: [@ivanmosetti07](https://github.com/ivanmosetti07).

### 📜 License

The license is [PolyForm Noncommercial 1.0.0](LICENSE.md). You can use, study, change and share Siri AI+ for free, for any **non-commercial** purpose: personal use, study, research, hobbies, schools, non-profits. You **can't** sell it or use it to make money. That makes it *source available* rather than "open source" in the OSI sense. For commercial use, get in touch.

Third-party credits and licenses are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

### ❤️ Thanks

- Apple, for the Foundation Models framework.
- Salvatore Sanfilippo ([@antirez](https://github.com/antirez)), for [ds4](https://github.com/antirez/ds4).
- Simone Rizzo ([@simone-rizzo](https://github.com/simone-rizzo)) and Rizzo AI Academy, for [rizzo-pii](https://github.com/Rizzo-AI-Academy/rizzo-pii).
- Google, for [Gemma](https://ai.google.dev/gemma), and [ggml-org](https://github.com/ggml-org/llama.cpp), for llama.cpp.
- [Open-Meteo](https://open-meteo.com), for the weather data.
- OpenAI Codex and Anthropic Claude Code, for letting your subscription do the heavy lifting.

---

## 🇮🇹 Italiano

### Cos'è?

Immagina il Siri che tutti aspettavamo. Legge davvero il tuo calendario, risponde alle email, tiene in ordine le note, lavora nelle cartelle dei tuoi progetti, crea app con Xcode e chatta come le migliori app di AI per desktop. Ecco Siri AI+. 🪄

Lo scopo: pubblicare il Siri AI che Apple avrebbe dovuto lanciare. È completamente integrato con le app Apple, Xcode incluso, e ha le funzioni di base delle migliori app come Claude o ChatGPT Desktop. Soprattutto, **porta l'AI a tutti** con l'AI locale, sul Mac che hai già.

Funziona con **Apple Intelligence**, direttamente sul tuo Mac: niente account, niente abbonamenti, e niente esce dal computer. Quando il modello piccolo di Apple non basta, puoi collegare cervelli più grandi. Quelli locali, come Gemma 4 e ds4, restano sul Mac. Con il tuo abbonamento a Claude o ChatGPT, uno scudo per la privacy anonimizza i tuoi dati personali prima che escano dal Mac.

> [!IMPORTANT]
> Per ora l'interfaccia è in **italiano** 🇮🇹. Le traduzioni sono benvenute!

### Cosa sa fare

- 💬 **Chatta come le app più famose.**
  - Chat, progetti, chat affiancate (fino a 4) e chat figlie.
  - Ricerca con ⌘K, modalità vocale e dettatura.
  - Allegati di file e immagini, e ricerca sul web con le fonti numerate.
  - Memoria, skill e, sotto ogni risposta, il riquadro «Come ho lavorato».
- 🍎 **Le tue app Apple, dentro la chat.**
  - Calendario, Promemoria, Mail, Note, Messaggi, Contatti, Memo Vocali, File e un Safari integrato.
  - Si aprono in schede accanto alla chat, e ogni chat ha le sue app aperte.
  - Chiedi «sposta la riunione di domani alle 16» o «rispondi a Mario che giovedì va bene» e ti arriva una scheda da confermare. **Niente viene scritto o inviato senza il tuo OK**, e puoi annullare per 10 minuti.
- 📄 **Documenti, fogli e presentazioni.** Editor in stile Pages, Numbers e Keynote, che l'AI sa scrivere e modificare («aggiungi una slide sui prossimi passi», «fai un grafico a torta»).
- 📁 **Progetti.**
  - Colleghi una cartella e la chat la usa come contesto: AGENTS.md o CLAUDE.md, mappe dei file, registri del giorno.
  - Un grafo in stile Obsidian mostra le tue note come un cervello.
- 🛠️ **Spazio di programmazione, Xcode incluso.**
  - Siti, app web e app SwiftUI per Mac e iPhone, con qualunque modello.
  - Anteprima dal vivo nel Safari della sessione, con gli errori della console e il pulsante «Correggi».
  - Punti di ripristino, revisione delle modifiche e «Apri in Xcode» per le app native.
- 🤖 **Agenti.**
  - Hanno un nome, un obiettivo e degli orari.
  - Fanno un piano, usano i sub-agent, chiedono prima delle azioni importanti e scrivono un registro.
  - Di notte «sognano» per imparare dagli errori.
- 🧩 **Connettori MCP.** Server locali o remoti (con login OAuth), che puoi importare da Claude Desktop.
- 🧠 **Un harness pensato per i modelli piccoli.**
  - Un sub-agent sceglie gli strumenti giusti per ogni richiesta.
  - I compiti complessi diventano piani eseguiti dai sub-agent in parallelo.
  - I sub-agent compattano le conversazioni lunghe.
  - I conti esatti (date, orari, totali) li fa il codice, non il modello.

### I modelli

| Modello | Dove gira | Privacy | Note |
|---|---|---|---|
| **Apple Intelligence** | Sul tuo Mac | 🔒 Niente esce dal Mac | Quello predefinito, gratis. Modello piccolo (circa 4.000 token di contesto sul mio M2 Pro): Siri AI+ ne spreme ogni goccia |
| **Gemma 4** | Sul tuo Mac (llama.cpp) | 🔒 Niente esce dal Mac | La versione dipende dalla memoria: E2B (qualsiasi Mac), E4B (12 GB+), 12B (16 GB+), 26B A4B (32 GB+), 31B (48 GB+) |
| **ds4** di [@antirez](https://github.com/antirez) | Sul tuo Mac | 🔒 Niente esce dal Mac | Modelli molto potenti (DeepSeek V4 Flash) su hardware di fascia alta: servono 96 GB o più di memoria unificata |
| **ChatGPT** | Cloud di OpenAI, con il tuo abbonamento (CLI Codex) | 🛡️ Dati personali anonimizzati prima | Versione e ragionamento per ogni chat |
| **Claude** | Cloud di Anthropic, con il tuo abbonamento (CLI Claude Code) | 🛡️ Dati personali anonimizzati prima | Versione e ragionamento per ogni chat |

Ogni chat ricorda il suo modello. Qualunque modello risponda, gli strumenti per ogni richiesta li sceglie Apple Intelligence, sul Mac e gratis.

#### 🙏 Una nota su ds4

Confessione: purtroppo non ho un computer abbastanza potente, quindi [ds4](https://github.com/antirez/ds4) non l'ho mai potuto provare dentro Siri AI+. Se qualcuno lo prova, mi fa sapere com'è andata? Basta aprire una issue. Magari te, Salvatore ([@antirez](https://github.com/antirez))… *famme sape'!* 😄

### 🛡️ Lo scudo per la privacy, grazie a rizzo-pii

Claude e ChatGPT sono potentissimi, ma il testo finisce sui server di qualcun altro, quindi la privacy non è sicura. Apple non approverebbe mai 😅. Per questo Siri AI+ ha uno scudo per la privacy. È basato su [rizzo-pii](https://github.com/Rizzo-AI-Academy/rizzo-pii), l'anonimizzatore open source di Simone Rizzo ([@simone-rizzo](https://github.com/simone-rizzo)) e della Rizzo AI Academy.

Ogni volta che trova un dato personale, il Mac lo sostituisce con un segnaposto prima che il testo parta verso Claude o ChatGPT. Quando arriva la risposta, rimette i dati veri. Una prova vera:

```text
Scrivi:           Scrivi a Mario Rossi (mario.rossi@studio.it) che la fattura da 1.200 € scade il 15 ottobre, IBAN IT60X0542811101000000123456
Parte:            Scrivi a [FULLNAME_1] ([EMAIL_1]) che la fattura da 1.200 € scade il 15 ottobre, IBAN [IBAN_1]
Leggi:            la risposta, con nome, email e IBAN veri rimessi al loro posto sul Mac
```

- **Nascosti:** nomi, email, telefoni, codici fiscali, partite IVA, documenti, IBAN, carte, indirizzi di casa, targhe, dati catastali e indirizzi IP pubblici.
- **Restano leggibili:** importi, date, orari, città, aziende e siti. Senza, l'AI non riuscirebbe a lavorare bene. Puoi nascondere anche questi dalle Impostazioni.
- **Vale per tutto:** i tuoi messaggi, la cronologia, la memoria, le istruzioni dei progetti, i file, le email e i risultati degli strumenti.
- **Il dizionario resta sul Mac.** Se l'anonimizzatore non è installato o non riesce, **non parte niente** e risponde Apple Intelligence.
- **Gira sul Mac con Core ML.** Il modello di rizzo-pii è convertito in Core ML e le sue regole sono riscritte in Swift, con gli stessi risultati dell'originale. Ci mette circa 40 ms ogni 120 parole.
- **Non ancora coperto:** lo spazio di programmazione, dove Codex e Claude Code leggono direttamente i file del progetto.

### 🇪🇺 Perché l'Europa, e perché conta

A giugno 2026 Apple ha annunciato che [la nuova Siri AI non arriverà nell'UE su iPhone, iPad e Apple Watch](https://www.apple.com/newsroom/2026/06/due-to-dma-siri-ai-delayed-in-eu-for-ios-27-and-ipados-27/) a causa del **Digital Markets Act (DMA)**.

- **Cosa chiede il DMA:** Apple è un «gatekeeper», quindi deve aprire la sua piattaforma agli altri servizi.
- **Come lo legge Apple:** dovrebbe dare a qualsiasi assistente di terze parti lo stesso accesso profondo a messaggi, dati e app che ha Siri AI, e per Apple questo è un rischio per privacy e sicurezza.
- **La proposta di Apple:** uno strato intermedio, un «Trusted System Agent». La Commissione europea ha detto no e [ha risposto](https://www.euronews.com/next/2026/06/11/the-eus-dma-fines-delayed-features-and-unclear-benefits) che nel DMA non c'è assolutamente nulla che impedisca ad Apple di lanciare nuovi prodotti nell'UE.
- **Il risultato:** nessuna data per iPhone e iPad. Sul Mac, invece, Siri AI è disponibile anche nell'UE.

Le app come questa ricevono il modello piccolo di Apple che gira sul Mac. Il modello più grande di Apple, su Private Cloud Compute, richiede un permesso speciale di Apple. Siri AI+ è già usabile così. Aspettiamo solamente che sblocchino i modelli più potenti anche qui in Europa, e allora sarà ancora più completa.

Il mio parere: Siri AI+ è aperta agli altri modelli, locali e cloud. I dati personali però vengono anonimizzati sul Mac prima di partire, e niente succede senza la tua conferma. Forse è proprio così che apertura e privacy possono convivere, e che Apple potrebbe entrare in Europa senza alcun problema. Apple, chiamami 😄

### ⬇️ Scaricare e installare

**Requisiti:**
- un Mac con Apple silicon;
- **macOS 27**;
- Apple Intelligence attiva (Impostazioni di Sistema › Apple Intelligence e Siri).

**Opzione 1: l'app pronta**

1. Scarica `Siri-AI-Plus-macOS.zip` dall'[ultima release](https://github.com/ivanmosetti07/siri-ai-plus/releases/latest).
2. Decomprimilo e trascina **Siri AI+** in **Applicazioni**.
3. L'app non è autenticata da Apple, perché serve un account sviluppatore a pagamento, quindi la prima volta macOS la blocca. Apri **Impostazioni di Sistema › Privacy e sicurezza**, scorri in basso e fai clic su **Apri comunque**. Oppure dal Terminale:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Siri AI+.app"
   ```

**Opzione 2: compilala tu** (serve Xcode 27)

```bash
git clone https://github.com/ivanmosetti07/siri-ai-plus.git
cd siri-ai-plus
./build.sh
cp -R "Siri AI+.app" /Applications/
```

`build.sh` firma l'app con il primo certificato di firma che trova sul Mac. Se non ne hai, usa una firma ad hoc, e allora macOS richiede i permessi dopo ogni compilazione.

### 🚀 Come si usa

1. **Primo avvio.** Scegli quali fonti può usare Siri AI+ (Calendario, Promemoria, Mail, Note…) e se può solo leggerle o anche modificarle. macOS chiede ogni permesso una volta sola. Messaggi e Memo Vocali richiedono l'Accesso completo al disco, e con quello anche Mail diventa molto più veloce.
2. **Chiedi e basta:**
   - «Cosa ho domani?»
   - «Ricordami di chiamare il commercialista venerdì»
   - «Rispondi a Mario che giovedì va bene»
   - «Crea una presentazione sul lancio del prodotto»
   - «Cerca sul web le ultime notizie su Apple»
3. **Conferma.** Tutto ciò che scrive, invia o cancella arriva come una scheda, e decidi tu.
4. **Scorciatoie:**

   | Scorciatoia | Azione |
   |---|---|
   | ⌘N | Nuova chat |
   | ⌘K | Cerca |
   | ⌥⌘A | App in schede |
   | ⌥⌘N | Chat affiancate |
   | ⇧⌘N | Chat figlia |
   | ⌥⌘V | Modalità vocale |
   | ⌥⌘S | Mostra o nasconde la chat laterale |

5. **Spazi.** Passa tra Personale, Lavoro e Programmazione accanto al nome, nella barra laterale. Ogni spazio ha le sue chat, i suoi progetti, agenti e calendari, e il suo modello.
6. **Cambia modello** dal pannello dei modelli nel campo di scrittura. Ogni chat tiene il suo modello, la versione e il livello di ragionamento.

**Extra facoltativi**, in Impostazioni › Modelli:

- **Gemma 4:** installa llama.cpp con Homebrew e scarica la versione consigliata per il tuo Mac.
- **ds4:** sui Mac con 96 GB o più, scarica e compila [antirez/ds4](https://github.com/antirez/ds4), poi scarica il modello.
- **ChatGPT e Claude:** installano le CLI ufficiali Codex e Claude Code, poi fai il login con il tuo abbonamento nel browser.
- **Lo scudo per la privacy**, che serve per ChatGPT e Claude. Si lancia una volta dalla cartella del repository. Servono [pipx](https://pipx.pypa.io) (`brew install pipx`) e Xcode:

  ```bash
  Support/rizzo-pii/install.sh
  ```

Per chi sviluppa c'è la guida tecnica: [docs/GUIDA-TECNICA.md](docs/GUIDA-TECNICA.md). Spiega l'architettura, i banchi di prova e le opzioni di diagnostica. Per i test: `./test.sh`.

### 🐛 Bug noti

L'ho fatto una domenica e qualche sera, per hobby, quindi ci sono alcuni bug. Quelli che conosco:

- L'interfaccia è solo in italiano.
- Il modello piccolo di Apple ogni tanto inciampa sugli indovinelli e sui testi molto lunghi. L'harness aiuta tanto, ma resta un modello da 3 miliardi di parametri.
- La release non è autenticata da Apple, quindi macOS si lamenta la prima volta.
- Lo scudo per la privacy non copre lo spazio di programmazione.
- ds4 non è mai stato provato (vedi sopra 🙏).

Hai trovato qualcosa? Apri una [issue](https://github.com/ivanmosetti07/siri-ai-plus/issues). Le pull request sono benvenute.

### ⭐ Supporta il progetto

- ⭐ **Metti una stella** al repository con il pulsante in alto a destra. È gratis, mi motiva e aiuta altre persone a trovare Siri AI+.
- 👀 **Watch › Custom › Releases** per ricevere un avviso quando esce una nuova versione.
- 🐛 **Hai trovato un bug?** [Apri una issue](https://github.com/ivanmosetti07/siri-ai-plus/issues/new).
- 💡 **Hai un'idea o una domanda?** Scrivila nelle [Discussions](https://github.com/ivanmosetti07/siri-ai-plus/discussions).
- 🍴 **Fai un fork** e sperimenta, per usi non commerciali (vedi la licenza). Le pull request sono benvenute, a partire dalla traduzione in inglese!
- 📣 **Condividilo** su [X](https://twitter.com/intent/tweet?text=Siri%20AI%2B%3A%20il%20Siri%20AI%20che%20Apple%20avrebbe%20dovuto%20lanciare%20%F0%9F%8D%8E&url=https%3A%2F%2Fgithub.com%2Fivanmosetti07%2Fsiri-ai-plus) o su [LinkedIn](https://www.linkedin.com/sharing/share-offsite/?url=https%3A%2F%2Fgithub.com%2Fivanmosetti07%2Fsiri-ai-plus).
- 👤 **Seguimi** su GitHub: [@ivanmosetti07](https://github.com/ivanmosetti07).

### 📜 Licenza

La licenza è [PolyForm Noncommercial 1.0.0](LICENSE.md). Puoi usare, studiare, modificare e condividere Siri AI+ gratis, per qualsiasi scopo **non commerciale**: uso personale, studio, ricerca, hobby, scuole, associazioni no profit. **Non** puoi venderlo né usarlo per guadagnarci. Per questo è *source available* e non «open source» nel senso dell'OSI. Per usi commerciali, scrivimi.

Crediti e licenze dei componenti di terzi sono in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

### ❤️ Grazie

- Ad Apple, per il framework Foundation Models.
- A Salvatore Sanfilippo ([@antirez](https://github.com/antirez)), per [ds4](https://github.com/antirez/ds4).
- A Simone Rizzo ([@simone-rizzo](https://github.com/simone-rizzo)) e alla Rizzo AI Academy, per [rizzo-pii](https://github.com/Rizzo-AI-Academy/rizzo-pii).
- A Google, per [Gemma](https://ai.google.dev/gemma), e a [ggml-org](https://github.com/ggml-org/llama.cpp), per llama.cpp.
- A [Open-Meteo](https://open-meteo.com), per i dati del meteo.
- A OpenAI Codex e Anthropic Claude Code, che fanno lavorare il tuo abbonamento.

---

## ⭐ Star history

<a href="https://star-history.com/#ivanmosetti07/siri-ai-plus&Date">
  <img src="https://api.star-history.com/svg?repos=ivanmosetti07/siri-ai-plus&type=Date" alt="Star history chart" width="600">
</a>

<p align="center"><sub>Made with ❤️, Apple Intelligence and too much coffee ☕ · Fatto con ❤️, Apple Intelligence e troppo caffè ☕</sub></p>
