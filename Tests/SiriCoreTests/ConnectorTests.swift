import Foundation
import Testing
@testable import SiriCore

/// Connettori MCP: quali strumenti partono da soli, come il modello legge i risultati, come si riconosce il servizio.
@Suite @MainActor struct ConnectorTests {
    func tool(_ name: String, server: String = "Demo CRM", description: String = "", readOnly: Bool? = nil, destructive: Bool? = nil) -> MCPToolInfo {
        MCPToolInfo(serverID: UUID(), serverName: server, name: name, description: description, inputSchema: .object(["type": .string("object")]),
                    readOnlyHint: readOnly, destructiveHint: destructive)
    }

    @Test func readOnlyFromAnnotationsAndNames() {
        // Dal nome: letture sì, tutto ciò che può cambiare qualcosa no (nel dubbio si chiede conferma).
        for name in ["search", "search_tools", "get_tool_schema", "describe_tool", "execute_read_tool", "list_my_agencies", "whoami", "fetch",
                     "list.clients", "listClients", "get_schedule", "cerca_clienti", "elenca-fatture"] {
            #expect(tool(name).isReadOnly, "\(name)")
        }
        for name in ["execute_write_tool", "execute_critical_tool", "switch_agency", "render_task_workbench", "create_task", "send_email",
                     "update_client", "schedule_meeting", "crea_task", "invia_fattura", "sync"] {
            #expect(!tool(name).isReadOnly, "\(name)")
        }
        // Le indicazioni del server contano più del nome.
        #expect(tool("sync_status", readOnly: true).isReadOnly)
        #expect(!tool("search", readOnly: false).isReadOnly)
        #expect(!tool("list_items", readOnly: true, destructive: true).isReadOnly)
    }

    @Test func oldSavedDataStillDecodes() throws {
        // Schede e configurazioni salvate prima delle indicazioni di sola lettura.
        let old = #"{"serverID":"8E1A2B3C-0000-0000-0000-000000000001","serverName":"Agency Os","name":"search","description":"","inputSchema":{"type":"object"}}"#
        let decoded = try JSONDecoder().decode(MCPToolInfo.self, from: Data(old.utf8))
        #expect(decoded.readOnlyHint == nil && decoded.isReadOnly)
        let config = #"{"id":"8E1A2B3C-0000-0000-0000-000000000002","name":"Agency Os","transport":"http","command":"","args":[],"env":{},"url":"https://example.com/mcp","headers":{},"enabled":true,"alwaysAllow":["search"]}"#
        let server = try JSONDecoder().decode(MCPServerConfig.self, from: Data(config.utf8))
        #expect(server.confirmReads == nil && server.alwaysAllow == ["search"])
    }

    @Test func resultsBecomeReadableLines() {
        let json = #"{"results":[{"id":"T-1","title":"Preparare il preventivo","due":"2026-09-28","status":"open","owner":null,"tags":[]},{"id":"T-2","title":"Rivedere la campagna","due":"2026-09-29","status":"open","client":{"name":"Bianchi Bike","id":"C-102"}}]}"#
        let text = Language.$scoped.withValue(.it) { ConnectorResult.readable(json) }
        #expect(text.contains("2 elementi"))
        #expect(text.contains("- Preparare il preventivo · status: open · due: 2026-09-28"))
        #expect(text.contains("client: Bianchi Bike"))
        #expect(!text.contains("owner") && !text.contains("tags") && !text.contains("null"))
        // Oggetti annidati: chiave e valore su righe, niente JSON.
        let detail = ConnectorResult.readable(#"{"name":"Rossi Arredamenti","contact":{"name":"Giulia Rossi","email":"g@example.com"},"value_eur":18400}"#)
        #expect(detail.contains("name: Rossi Arredamenti") && detail.contains("  email: g@example.com") && detail.contains("value_eur: 18400"))
        // Il testo che non è JSON resta com'è.
        #expect(ConnectorResult.readable("Nessun risultato.") == "Nessun risultato.")
    }

    @Test func longListsAreShortenedWithTheirCount() {
        let items = (1...80).map { #"{"name":"Cliente \#($0)","city":"Milano","notes":"\#(String(repeating: "x", count: 120))"}"# }.joined(separator: ",")
        let text = Language.$scoped.withValue(.it) { ConnectorResult.readable("[\(items)]", limit: 1500) }
        #expect(text.count <= 1500)
        #expect(text.hasPrefix("80 elementi"))
        #expect(text.contains("… e altri"))
        #expect(Language.$scoped.withValue(.en) { ConnectorResult.summary(#"{"tools":[{"name":"a"},{"name":"b"}]}"#) } == "2 items")
    }

    @Test func wordsMatchAcrossLanguagesAndEndings() {
        #expect(Assistant.sameStem("task", "tasks") && Assistant.sameStem("cliente", "clienti") && Assistant.sameStem("progetto", "progetti"))
        #expect(!Assistant.sameStem("data", "date") && !Assistant.sameStem("contratto", "contatto") && Assistant.sameStem("company", "companies"))
        #expect(Assistant.domainTranslations("fatture").contains("invoices"))
        #expect(Assistant.domainTranslations("customers").contains("clienti"))
        #expect(Assistant.domainTranslations("scadute").contains("overdue"))
    }

    @Test func connectorIsChosenByDomainWords() {
        let assistant = Assistant()
        var work = WorkContext()
        work.mcpTools = [
            tool("list_clients", description: "List the agency's clients with contact person, city and status: 'active' or 'paused'."),
            tool("list_tasks", description: "List tasks with due date, owner and client."),
            tool("create_task", description: "Create a new task for a client."),
        ]
        assistant.work = work
        #expect(assistant.strongServerMatch("quali clienti sono in pausa?") == "Demo CRM")
        #expect(assistant.strongServerMatch("which clients are paused?") == "Demo CRM")
        #expect(assistant.strongServerMatch("che tempo fa domani a roma?") == nil)
        // Una parola distintiva del nome basta; parole generiche no.
        #expect(assistant.namedServer("cerca rossi arredamenti nel crm") == "Demo CRM")
        #expect(assistant.namedServer("fammi una demo del sito") == nil)
        #expect(assistant.connectorSummary().hasPrefix("Demo CRM (clients, tasks"))
    }

    @Test func writesAndLookupsAreRecognized() {
        #expect(Assistant.asksToWrite("crea un task per verde bio") && Assistant.asksToWrite("create a task in demo crm"))
        #expect(Assistant.asksToWrite("aggiungi un cliente") && Assistant.asksToWrite("send the invoice"))
        #expect(!Assistant.asksToWrite("quali fatture sono scadute?") && !Assistant.asksToWrite("which clients are paused?"))
        #expect(Assistant.isLookup("cerca rossi arredamenti") && Assistant.isLookup("chi è il referente di bianchi bike?"))
        #expect(!Assistant.isLookup("scrivimi una poesia sull'autunno"))
    }

    @Test func schemaValuesAreNotInvented() {
        let schema = JSONValue.object(["type": .string("object"), "properties": .object([
            "status": .object(["type": .string("string"), "description": .string("'open' or 'done'")]),
            "kind": .object(["type": .string("string"), "enum": .array([.string("invoice"), .string("quote")])]),
            "toolset": .object(["type": .string("string")]),
        ])])
        #expect(Assistant.schemaOptions(schema["properties"]?["status"]) == ["open", "done"])
        let arguments = JSONValue.object(["status": .string("done"), "kind": .string("quote"), "toolset": .string("billing")])
        let kept = Assistant.dropInvented(arguments, schema: schema, evidence: "mostrami i task già completati")
        // Valori previsti dallo schema restano anche se la richiesta li dice in italiano; un filtro inventato no.
        #expect(kept["status"]?.string == "done" && kept["kind"]?.string == "quote" && kept["toolset"] == nil)
    }

    @Test func searchWordsLeaveOutTheServiceName() {
        let cleaned = Assistant.cleanedSearch(.object(["query": .string("overdue tasks Demo CRM"), "limit": .number(5)]), server: "Demo CRM")
        #expect(cleaned["query"]?.string == "overdue tasks" && cleaned["limit"]?.number == 5)
        // Se resta vuota si tiene com'era.
        #expect(Assistant.cleanedSearch(.object(["query": .string("demo crm")]), server: "Demo CRM")["query"]?.string == "demo crm")
    }

    @Test func bestToolFollowsTheRequest() {
        let tools = [tool("search"), tool("list_clients"), tool("list_tasks"), tool("get_client"), tool("create_task"), tool("create_client")]
        #expect(Assistant.bestTool(for: "quali task ho in scadenza?", among: tools, writing: false)?.name == "list_tasks")
        #expect(Assistant.bestTool(for: "quali clienti sono in pausa?", among: tools, writing: false)?.name == "list_clients")
        #expect(Assistant.bestTool(for: "crea un task per verde bio", among: tools, writing: true)?.name == "create_task")
        #expect(Assistant.bestTool(for: "add a new client called acme", among: tools, writing: true)?.name == "create_client")
        #expect(Assistant.bestTool(for: "che tempo fa?", among: tools, writing: false) == nil)
    }

    @Test func searchesWithoutTheModel() {
        let search = MCPToolInfo(serverID: UUID(), serverName: "Demo CRM", name: "search", description: "",
                                 inputSchema: .object(["type": .string("object"), "properties": .object(["query": .object(["type": .string("string")])]),
                                                       "required": .array([.string("query")])]))
        #expect(Assistant.fallbackArguments(for: search, prompt: "Who is the contact person at Bianchi Bike in Demo CRM?")?["query"]?.string == "Bianchi Bike")
        #expect(Assistant.fallbackArguments(for: search, prompt: "chi è il referente di rossi arredamenti")?["query"]?.string?.isEmpty == false)
        // Uno strumento che vuole altri campi obbligatori non si compila a caso.
        let create = MCPToolInfo(serverID: UUID(), serverName: "Demo CRM", name: "create_task", description: "",
                                 inputSchema: .object(["type": .string("object"), "properties": .object(["title": .object(["type": .string("string")]),
                                                                                                          "due": .object(["type": .string("string")])]),
                                                       "required": .array([.string("title"), .string("due")])]))
        #expect(Assistant.fallbackArguments(for: create, prompt: "crea un task") == nil)
        // Seconda ricerca nel catalogo con le parole del servizio.
        #expect(Assistant.catalogQuery("crea su demo os un preventivo per bianchi bike", language: .en) == "create quote")
        #expect(Assistant.catalogQuery("quali fatture sono scadute?", language: .en)?.contains("invoice") == true)
        #expect(Assistant.catalogQuery("che tempo fa?", language: .en) == nil)
        #expect(!Assistant.asksToWrite("mostrami i task già completati") && Assistant.asksToWrite("completa il task del preventivo"))
    }

    @Test func datesAndIdsReachTheArguments() throws {
        // Domenica 27 settembre 2026: «venerdì» è il 2 ottobre.
        let sunday = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 10)))
        let dates = Language.$scoped.withValue(.it) { Assistant.connectorDates("chiamare Sara venerdì", now: sunday) }
        #expect(dates.contains("2026-09-27") && dates.contains("2026-10-02"))
        // L'id trovato con la ricerca resta; uno inventato no.
        let schema = JSONValue.object(["type": .string("object"), "properties": .object([
            "title": .object(["type": .string("string")]), "client_id": .object(["type": .string("string")])]), "required": .array([.string("title")])])
        let evidence = "crea un task per verde bio {\"query\":\"Verde Bio\"} clients: - Verde Bio · id: C-103"
        #expect(Assistant.dropInvented(.object(["title": .string("Chiamare Sara"), "client_id": .string("C-103")]), schema: schema, evidence: evidence)["client_id"]?.string == "C-103")
        #expect(Assistant.dropInvented(.object(["title": .string("Chiamare Sara"), "client_id": .string("C-999")]), schema: schema, evidence: evidence)["client_id"] == nil)
        // La riga compatta conta gli elementi di tutti gli elenchi.
        #expect(Language.$scoped.withValue(.it) { ConnectorResult.summary(#"{"clients":[{"id":"C-103"}],"tasks":[{"id":"T-3"},{"id":"T-4"}]}"#) } == "3 elementi")
    }

    @Test func datesOnlyWhereTheyBelong() {
        func schema(_ keys: [String: JSONValue]) -> MCPToolInfo {
            MCPToolInfo(serverID: UUID(), serverName: "Demo CRM", name: "x", description: "",
                        inputSchema: .object(["type": .string("object"), "properties": .object(keys)]))
        }
        let text = JSONValue.object(["type": .string("string")])
        #expect(Assistant.wantsDates(schema(["status": text, "due_within_days": .object(["type": .string("integer")])])))
        #expect(Assistant.wantsDates(schema(["title": text, "startDate": text])))
        #expect(Assistant.wantsDates(schema(["when": .object(["type": .string("string"), "format": .string("date-time")])])))
        #expect(!Assistant.wantsDates(schema(["query": text])))
        // Una data che l'utente non ha scritto esce dalle parole di ricerca; una scritta resta.
        let cleaned = Assistant.cleanedSearch(.object(["query": .string("Bianchi Bike contact 2026-09-27")]), server: "Demo CRM", prompt: "Who is the contact at Bianchi Bike?")
        #expect(cleaned["query"]?.string == "Bianchi Bike contact")
        #expect(Assistant.cleanedSearch(.object(["query": .string("fattura 2026-09-15")]), server: "Demo OS", prompt: "la fattura del 2026-09-15")["query"]?.string == "fattura 2026-09-15")
    }

    @Test func serviceNameAndToolTextStayOut() {
        let schema = JSONValue.object(["type": .string("object"), "properties": .object([
            "status": .object(["type": .string("string")]), "client": .object(["type": .string("string")])])])
        let filtered = Assistant.withoutServiceValues(.object(["status": .string("overdue"), "client": .string("Demo OS")]), schema: schema, server: "Demo OS")
        #expect(filtered["status"]?.string == "overdue" && filtered["client"] == nil)
        let quote = MCPToolInfo(serverID: UUID(), serverName: "Demo OS", name: "quote_create",
                                description: "Create a quote (estimate) for a client with amount and description.", inputSchema: .object([:]))
        let texts = Assistant.cleanedTexts(.object([
            "description": .string("Create a quote (estimate) for a client with amount and description. Per il nuovo sito."),
            "title": .string("chiamare Sara venerdì demo os\n\nDescrizione: prova"), "amount_eur": .number(2000)]), tool: quote)
        #expect(texts["description"]?.string == "Per il nuovo sito." && texts["title"]?.string == "chiamare Sara venerdì" && texts["amount_eur"]?.number == 2000)
    }

    @Test func properNamesForLookups() {
        #expect(Assistant.properName("Crea un task su Demo CRM per Verde Bio: chiamare Sara venerdì", excluding: "Demo CRM") == "Verde Bio")
        #expect(Assistant.properName("Create a task for Sara on Friday in Demo CRM", excluding: "Demo CRM") == "Sara")
        #expect(Assistant.properName("crea un task per domani", excluding: "Demo CRM") == nil)
    }

    @Test func internalToolsOfCatalogs() throws {
        let executor = MCPToolInfo(serverID: UUID(), serverName: "Demo OS", name: "execute_write_tool", description: "",
                                   inputSchema: .object(["type": .string("object"), "properties": .object([
                                       "tool_name": .object(["type": .string("string")]), "arguments": .object(["type": .string("object")])])]))
        #expect(Assistant.freeKey(of: executor) == "arguments")
        // La risposta di get_tool_schema: un solo strumento con il suo schema.
        let schema = #"{"name":"quote_create","description":"Create a quote","inputSchema":{"type":"object","properties":{"client":{"type":"string"},"amount_eur":{"type":"number"}},"required":["client"]}}"#
        let quote = try #require(Assistant.internalTool(named: nil, in: schema, executor: executor))
        #expect(quote.name == "quote_create" && quote.inputSchema["properties"]?["amount_eur"] != nil && !quote.isReadOnly)
        // Una ricerca che dà più schemi (anche come testo JSON): vale quello scelto.
        let search = #"{"tools":[{"name":"invoices_list","input_schema":"{\"type\":\"object\",\"properties\":{\"status\":{\"type\":\"string\"}}}"},{"name":"projects_list","inputSchema":{"type":"object","properties":{"state":{"type":"string"}}}}]}"#
        #expect(Assistant.internalTool(named: "invoices_list", in: search, executor: executor)?.inputSchema["properties"]?["status"] != nil)
        #expect(Assistant.internalTool(named: nil, in: search, executor: executor) == nil)
        #expect(Assistant.internalTool(named: nil, in: #"{"tools":[{"name":"invoices_list","description":"List invoices"}]}"#, executor: executor) == nil)
        // La scheda mostra lo strumento interno e i suoi campi.
        let draft = MCPCallDraft(tool: executor, arguments: .object(["tool_name": .string("quote_create"), "arguments": .object(["client": .string("Bianchi Bike")])]), inner: quote)
        #expect(draft.displayName == "quote_create" && draft.displayArguments["client"]?.string == "Bianchi Bike")
        #expect(MCPCallDraft(tool: executor, arguments: .object([:])).displayName == "execute_write_tool")
    }

    @Test func callChecksOfTheBench() throws {
        let data = Data(#"[{"id":"x","domanda":"?","chiamate":["list_tasks","execute_read_tool:invoices_list"]},{"id":"y","domanda":"?","senza_chiamate":true}]"#.utf8)
        let cases = try JSONDecoder().decode([EvalCase].self, from: data)
        #expect(Evaluation.connectorFailures(cases[0], calls: ["list_tasks", "execute_read_tool:invoices_list"]).isEmpty)
        #expect(Evaluation.connectorFailures(cases[0], calls: ["search"]).count == 2)
        #expect(Evaluation.connectorFailures(cases[1], calls: ["search"]).count == 1)
        #expect(Evaluation.connectorFailures(cases[1], calls: []).isEmpty)
    }
}
