import Foundation
import FoundationModels
import SiriCore

// MARK: - Ponte MCP per ChatGPT e Claude (avviato dall'app, non dall'utente)

if CommandLine.arguments.contains("--mcp-bridge") {
    await MCPBridge.run()
    exit(0)
}

// MARK: - Valutazione della qualità delle risposte (nessun permesso richiesto, nessuna modifica ai dati)

if let index = CommandLine.arguments.firstIndex(of: "--eval") {
    exit(await Evaluation.main(Array(CommandLine.arguments.dropFirst(index + 1))))
}

// MARK: - Banco degli strumenti per modello (dati inventati, cartella dati temporanea) e confronto fra modelli

if let index = CommandLine.arguments.firstIndex(of: "--banco-strumenti") {
    exit(await ToolBench.main(Array(CommandLine.arguments.dropFirst(index + 1))))
}
if let index = CommandLine.arguments.firstIndex(of: "--banco-confronto") {
    exit(ToolBench.compare(Array(CommandLine.arguments.dropFirst(index + 1))))
}

// MARK: - Guida di un progetto: quali file aprirebbe la chat per ogni richiesta (solo lettura)

if let index = CommandLine.arguments.firstIndex(of: "--guida-progetto"), index + 2 < CommandLine.arguments.count {
    let guide = ProjectGuide.shared(for: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    let started = Date.now
    await guide.prepare()
    print("Istruzioni: \(guide.instructionFileNames.joined(separator: ", ")) · righe della mappa: \(guide.routes.count) · albero in \(String(format: "%.1f", Date.now.timeIntervalSince(started))) s")
    for prompt in CommandLine.arguments[index + 2].components(separatedBy: "||") {
        let picks = guide.relevant(to: prompt)
        print("\n«\(prompt)»")
        for pick in picks { print("  \(pick.score) · \(pick.path) — \(pick.reason)") }
        if picks.isEmpty { print("  (nessun file)") }
    }
    exit(0)
}

// Diagnostica: `--anonimizza "testo"` (rizzo-pii sul Mac) e `--anonimizza-prova riferimento.json [cpu|gpu|ane]`
// (confronto con la pipeline Python originale).
if let index = CommandLine.arguments.firstIndex(of: "--anonimizza"), index + 1 < CommandLine.arguments.count {
    do { print(try await PIIDiagnostics.anonymize(CommandLine.arguments[index + 1])) } catch { print("Errore: \(error.localizedDescription)") }
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--anonimizza-prova"), index + 1 < CommandLine.arguments.count {
    let units = index + 2 < CommandLine.arguments.count ? CommandLine.arguments[index + 2] : nil
    do { print(try await PIIDiagnostics.compare(reference: URL(fileURLWithPath: CommandLine.arguments[index + 1]), units: units)) }
    catch { print("Errore: \(error.localizedDescription)") }
    exit(0)
}

// Decisioni rapide (rizzo-flow): `--decidi richiesta.json` (formato nativo di rizzo-flow) e
// `--decisioni-smoke [file.jsonl]` (le fixture di rizzo-flow, per controllare il port).
if let index = CommandLine.arguments.firstIndex(of: "--decidi"), index + 1 < CommandLine.arguments.count {
    print(await DecisionDiagnostics.decide(file: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--decisioni-smoke") {
    let path = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "Support/eval/rizzo-flow-smoke.jsonl"
    print(await DecisionDiagnostics.smoke(file: URL(fileURLWithPath: path)))
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--decisioni-banco"), index + 1 < CommandLine.arguments.count {
    print(await DecisionDiagnostics.routing(file: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--decisioni-auto") {
    let path = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "Support/eval/decisioni-auto.json"
    print(await DecisionDiagnostics.auto(file: URL(fileURLWithPath: path)))
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--decisioni-memoria") {
    let path = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "Support/eval/decisioni-memoria.json"
    print(await DecisionDiagnostics.memory(file: URL(fileURLWithPath: path)))
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--decisioni-anonimizza") {
    let path = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "Support/eval/decisioni-anonimizza.json"
    print(await DecisionDiagnostics.privacy(manifest: URL(fileURLWithPath: path)))
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--anonimizza-tempi"), index + 1 < CommandLine.arguments.count {
    print(await DecisionDiagnostics.privacyTiming(file: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
    exit(0)
}

// Diagnostica: `--grafo <cartella> [sottocartella]` costruisce il grafo delle note (solo lettura) e ne misura i tempi.
if let index = CommandLine.arguments.firstIndex(of: "--grafo"), index + 1 < CommandLine.arguments.count {
    let guide = ProjectGuide.shared(for: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    let folder = index + 2 < CommandLine.arguments.count ? CommandLine.arguments[index + 2] : nil
    var started = Date.now
    await guide.prepare()
    let tree = Date.now.timeIntervalSince(started)
    started = Date.now
    let graph = await guide.graph(folder: folder)
    let total = Date.now.timeIntervalSince(started)
    var again = graph
    started = Date.now
    GraphLayout.brain(&again)
    let layout = Date.now.timeIntervalSince(started)
    print("Note: \(graph.nodes.count) su \(graph.totalNotes) · collegamenti: \(graph.edges.count) su \(graph.totalLinks) · aree: \(graph.groups.map { $0.isEmpty ? "(principale)" : $0 }.joined(separator: ", "))")
    print(String(format: "Albero %.2f s · lettura dei collegamenti %.2f s · disposizione %.2f s", tree, max(0, total - layout), layout))
    for node in graph.nodes.sorted(by: { $0.degree > $1.degree }).prefix(12) { print("  \(node.degree) · \(node.title) — \(node.path)") }
    let outside = graph.nodes.filter { !GraphLayout.inside($0.x, $0.y) }.count
    print("Fuori dalla sagoma: \(outside)")
    exit(0)
}

// MARK: - Argomenti da riga di comando

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func takeFlag(_ names: String...) -> Bool {
    let found = args.contains { names.contains($0) }
    args.removeAll { names.contains($0) }
    return found
}

if takeFlag("-h", "--help") {
    print("""
    Siri AI+ — assistente locale con Apple Intelligence (on-device), Calendario e Promemoria.

    Uso:
      siriai                     avvia la chat interattiva
      siriai "cosa ho domani?"   esegue una sola richiesta ed esce
    Opzioni:
      -y, --yes       approva automaticamente creazioni/modifiche
      --eval [file]   valuta la qualità delle risposte (Support/eval/qualita.json)
                      --provider apple|gemma, --solo <id o categoria>, --senza-web
      --banco-strumenti [file]  strumenti e connettori per modello (Support/eval/strumenti-modelli.json)
                      --provider apple|gemma|chatgpt|claude|auto, --model, --effort, --etichetta prima|dopo,
                      --solo-smistamento, --ferma-dopo-errori N, --web-reale
      --banco-confronto [strumenti-modelli] [--etichetta prima|dopo]  tabella fra modelli
    """)
    exit(0)
}
Config.autoApprove = takeFlag("-y", "--yes")
let oneShotPrompt = args.isEmpty ? nil : args.joined(separator: " ")

// MARK: - Modello e permessi

if let problem = Agent.availabilityProblem {
    print("❌ \(problem)")
    exit(1)
}

let access = await Agent.requestAccess()
var enabled: Set<SourceKind> = [.mail, .notes, .files, .messages]
if access.calendar { enabled.insert(.calendar) } else {
    print("⚠️  Accesso al Calendario negato: Impostazioni di Sistema › Privacy e sicurezza › Calendari.")
}
if access.reminders { enabled.insert(.reminders) } else {
    print("⚠️  Accesso ai Promemoria negato: Impostazioni di Sistema › Privacy e sicurezza › Promemoria.")
}

let assistant = Assistant()

@MainActor func confirm(_ question: String) async -> Bool {
    Config.autoApprove ? true : await Hooks.confirm(question)
}

@MainActor func stream(_ prompt: String, allowRetry: Bool = true) async {
    do {
        var printed = ""
        let fitted = await assistant.fitPrompt(prompt)
        _ = try await assistant.answer(fitted.prompt) { text in
            print(text.hasPrefix(printed) ? String(text.dropFirst(printed.count)) : "\n" + text, terminator: "")
            printed = text
            fflush(stdout)
        }
        print()
    } catch let error as LanguageModelSession.GenerationError {
        if case .exceededContextWindowSize = error, allowRetry {
            assistant.reset(clearMemory: false)
            await stream(prompt, allowRetry: false)
        } else {
            print("\n❌ \(error.localizedDescription)")
        }
    } catch {
        print("\n❌ \(error.localizedDescription)")
    }
}

@MainActor func ask(_ prompt: String) async {
    // Risposta nella lingua in cui si scrive, anche per il testo che arriva dopo la scelta dell'azione.
    await Language.$scoped.withValue(assistant.language(for: prompt)) {
        await show(await assistant.handle(prompt, enabled: enabled, picked: []) { _ in })
    }
}

@MainActor func show(_ outcome: Outcome) async {
    do {
        switch outcome {
        case .reply(let text):
            await stream(text)
        case .agenda(_, let text):
            await stream(text)
        case .message(let text):
            print(text)
        case .unavailable(let source, let reason):
            print(reason == .comingSoon ? "\(source.label) non è ancora supportato." : "Serve l'accesso a \(source.label).")
        case .eventDraft(let draft):
            if await confirm("Creo «\(draft.title)» \(Dates.format(draft.start)) in «\(draft.calendar)»") {
                try EventKitService.save(draft); print("✅ Evento creato.")
            } else { print("Annullato.") }
        case .reminderDrafts(let drafts, let list):
            let titles = drafts.map(\.title).joined(separator: ", ")
            if await confirm("Aggiungo a «\(list)»: \(titles)") {
                try EventKitService.save(drafts, list: list); print("✅ Promemoria aggiunti.")
            } else { print("Annullato.") }
        case .confirm(let action):
            if await confirm(action.title) { try EventKitService.perform(action); print("✅ Fatto.") } else { print("Annullato.") }
        case .eventEdit(let edit):
            print("📅 «\(edit.before.title)» \(Dates.format(edit.before.start)) → «\(edit.after.title)» \(Dates.format(edit.after.start))–\(Dates.format(edit.after.end).suffix(5))\(edit.after.location.isEmpty ? "" : " · \(edit.after.location)")")
            if await confirm("Salvo la modifica dell'evento?") {
                try EventKitService.update(identifier: edit.identifier, start: edit.originalStart, to: edit.after); print("✅ Evento modificato.")
            } else { print("Annullato.") }
        case .reminderEdit(let edit):
            let due = edit.after.due.map { Dates.format($0, time: edit.after.dueHasTime) } ?? "nessuna scadenza"
            print("☑️ «\(edit.before.title)» → «\(edit.after.title)» · \(due) · lista \(edit.afterList)\(edit.after.highPriority ? " · importante" : "")")
            if await confirm("Salvo la modifica del promemoria?") {
                try EventKitService.update(reminder: edit.identifier, to: edit.after, list: edit.afterList); print("✅ Promemoria modificato.")
            } else { print("Annullato.") }
        case .noteAppend(let draft):
            print("🗒 Nota «\(draft.title)» — aggiungo:\n" + draft.lines.map { "  + \($0)" }.joined(separator: "\n"))
            if draft.manual {
                print("La nota ha liste o allegati che Note perderebbe: aggiungi il testo dall'app Note.")
            } else if await confirm("Aggiungo alla nota?") {
                let snapshot = try await NotesService.snapshot(id: draft.noteID)
                guard NotesService.canAppendSafely(snapshot.html) else { print("La nota è cambiata: ora ha liste o allegati."); return }
                _ = try await NotesService.append(id: draft.noteID, lines: draft.lines, expectedHTML: snapshot.html); print("✅ Aggiunto.")
            } else { print("Annullato.") }
        case .mailReply(let reply):
            print("A: \(reply.to)\nOggetto: \(reply.subject)\n\n\(reply.body)\n\n\(reply.quote.prefix(400))")
            if await confirm("Apro la risposta in Mail?") { try await MailComposer.reply(to: reply.messageID, body: reply.body + "\n\n" + reply.quote, replyAll: reply.replyAll); print("✅ Risposta aperta in Mail: inviala da lì.") } else { print("Annullato.") }
        case .mailForward(let forward):
            print("Inoltro «\(forward.subject)» (da \(forward.from), \(forward.date)) a \(forward.recipientName) \(forward.recipientAddress.isEmpty ? "(indirizzo da completare)" : "<\(forward.recipientAddress)>")")
            if await confirm("Apro l'inoltro in Mail?") { try await MailComposer.forward(forward.messageID, to: forward.recipientAddress, name: forward.recipientName); print("✅ Inoltro aperto in Mail: invialo da lì.") } else { print("Annullato.") }
        case .mailDraft(let mail):
            print("A: \(mail.recipients.joined(separator: ", "))\nOggetto: \(mail.subject)\n\n\(mail.body)")
        case .document(let doc):
            if let body = doc.body { print(body) } else {
                print("# \(doc.title)\n\(doc.subtitle)\n" + doc.sections.map { "\n## \($0.title)\n\($0.body)" }.joined())
            }
        case .writeDocument(let topic):
            let doc = try await assistant.streamDocument(topic: topic) { _ in }
            print("# \(doc.title)\n\(doc.subtitle)\n" + doc.sections.map { "\n## \($0.title)\n\($0.body)" }.joined())
        case .sheet(let sheet):
            print(sheet.title + "\nVoce\t" + sheet.columns.joined(separator: "\t"))
            for row in sheet.rows { print(row.label + "\t" + row.values.map { String(format: "%.0f", $0) }.joined(separator: "\t")) }
        case .deck(let deck):
            print("🎞  \(deck.title) — \(deck.subtitle)")
            for (i, slide) in deck.slides.enumerated() { print("\(i + 2). \(slide.title)\n   • " + slide.bullets.joined(separator: "\n   • ")) }
        case .plan(let plan):
            print(plan.summary)
            for step in plan.steps { print("• [\(step.kind.rawValue)] \(step.title)\(step.when.map { " · \($0)" } ?? "") — \(step.detail)") }
            print("(Esegui il piano dall'app Siri AI+.)")
        case .remembered(let fact, _):
            print("🧠 Ricorderò: \(fact)")
        case .web(let answer, let text):
            await stream(text)
            for (i, source) in answer.sources.enumerated() { print("  [\(i + 1)] \(source.title) — \(source.url)") }
        case .website(let site):
            print("🌐 \(site.title) → \(site.folder)/ (\(site.files.keys.sorted().joined(separator: ", ")))")
        case .agentDraft(let agent):
            print("🤖 Agente «\(agent.name)» — \(agent.goal) — \(agent.scheduleLabel)\(agent.projectName.map { " — progetto \($0)" } ?? "")")
        case .newChat(let request):
            print("💬 Nuova chat «\(request.title)»\(request.project.map { " nel progetto \($0)" } ?? "")\(request.child ? " (figlia)" : "")\(request.firstMessage.map { " — primo messaggio: \($0)" } ?? "")")
        case .taskPlan(let plan):
            print("🧠 " + plan.thoughts.joined(separator: " "))
            for (i, step) in plan.steps.enumerated() { print("\(i + 1). \(step.title)\(step.parallel ? " (in parallelo)" : "") — \(step.instruction)") }
            print("(I sub-agent eseguono il piano nell'app Siri AI+.)")
        case .browse:
            print("Il browser integrato si usa dall'app Siri AI+.")
        case .items(let items, let text):
            for row in items.rows.prefix(10) { print("• \(row.title) — \(row.subtitle)") }
            await stream(text)
        case .noteDraft(let note):
            if await confirm("Creo la nota «\(note.title)»") { try await NotesService.create(note); print("✅ Nota creata.") } else { print("Annullato.") }
        case .messageDraft(let message):
            print("A: \(message.recipient) \(message.handle.isEmpty ? "(recapito non trovato)" : "<\(message.handle)>")\n\(message.text)\n(L'invio si conferma dall'app Siri AI+.)")
        case .combined(let items):
            for item in items { await show(item) }
        case .image, .files, .fileWrite, .fileOp, .mcpCall, .artifactEdit:
            print("Questa richiesta si usa dall'app Siri AI+ (immagini, progetti, connettori e documenti).")
        }
    } catch {
        print("❌ \(error.localizedDescription)")
    }
}

// MARK: - Esecuzione

if let oneShotPrompt {
    await ask(oneShotPrompt)
    exit(0)
}

print("\u{1B}[1m🎙️  Siri AI+\u{1B}[0m — Apple Intelligence on-device\nComandi: /reset  /exit")

while true {
    print("\n\u{1B}[36m›\u{1B}[0m ", terminator: "")
    fflush(stdout)
    guard let line = readLine() else { break }
    let input = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if input.isEmpty { continue }
    switch input.lowercased() {
    case "/exit", "/quit", "esci": exit(0)
    case "/reset": assistant.reset(); print("🧹 Nuova conversazione.")
    default: await ask(input)
    }
}
