import SiriCore
import SwiftUI

/// Server MCP esterni: aggiunta, importazione da Claude Desktop, stato e strumenti.
struct ConnectorsView: View {
    @Environment(AppState.self) private var state
    @State private var editing = MCPServerConfig?.none
    @State private var importing = false
    var body: some View {
        let ready = state.mcp.servers.filter { if case .ready = state.mcp.status[$0.id] ?? .off { true } else { false } }
        GlassPage(maxWidth: 900) {
            PageHeader(eyebrow: String(localized: "Collega i tuoi strumenti"), title: String(localized: "Connettori"),
                       subtitle: String(localized: "Server MCP esterni: i loro strumenti diventano disponibili a Siri AI+ e ai Genius. Ogni esecuzione chiede conferma, a meno che tu non scelga «Consenti sempre» per uno strumento.")) {
                Button("Importa da Claude Desktop…") { importing = true }
                    .buttonStyle(.glass)
                Button {
                    editing = MCPServerConfig(name: "", transport: .stdio)
                } label: { Label("Aggiungi", systemImage: "plus") }
                .buttonStyle(.glassProminent)
            }
            if state.mcp.servers.isEmpty {
                GlassEmptyState(symbol: "puzzlepiece.extension.fill", title: String(localized: "Nessun connettore"),
                                message: String(localized: "Aggiungi un server locale (per esempio npx -y @modelcontextprotocol/server-filesystem ~/Documenti) o remoto via URL, oppure importa quelli di Claude Desktop."),
                                colors: Hue.indigo, actionTitle: String(localized: "Aggiungi un connettore")) { editing = MCPServerConfig(name: "", transport: .stdio) }
            } else {
                GlassPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        PanelLabel(text: String(localized: "Stato"), symbol: "puzzlepiece.extension")
                        MetricsGrid(metrics: [
                            DashMetric(label: String(localized: "Connettori"), value: "\(state.mcp.servers.count)", note: "configurati", tint: .indigo),
                            DashMetric(label: String(localized: "Collegati"), value: "\(ready.count)", note: ready.count == state.mcp.servers.count ? String(localized: "tutti attivi") : String(localized: "gli altri sono spenti"), tint: .green),
                            DashMetric(label: String(localized: "Strumenti"), value: "\(state.mcp.allTools.count)", note: String(localized: "a disposizione"), tint: Color(red: 0.4, green: 0.7, blue: 1)),
                        ])
                    }
                }
                GroupTitle(text: String(localized: "I tuoi connettori"))
                ForEach(state.mcp.servers) { server in
                    ServerCard(server: server) { editing = server }
                }
            }
        }
        .sheet(item: $editing) { server in
            ServerEditor(config: server) { saved in
                if let saved { state.mcp.save(saved) }
                editing = nil
            }
        }
        .sheet(isPresented: $importing) { ImportSheet() }
    }
}

struct ServerCard: View {
    @Environment(AppState.self) private var state
    let server: MCPServerConfig
    let edit: () -> Void

    private var status: MCPRegistry.Status { state.mcp.status[server.id] ?? .off }

    @State private var confirmRemove = false

    var body: some View {
        Card(title: server.name, subtitle: server.transport == .stdio ? ([server.command] + server.args).joined(separator: " ") : server.url) {
            Image(systemName: server.transport == .stdio ? "terminal" : "network")
                .font(.system(size: 15))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(status.label).font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(3)
                    Spacer()
                    switch status {
                    case .needsLogin:
                        Button("Accedi…") { state.mcp.login(server.id) }
                            .buttonStyle(.borderedProminent)
                            .help("Apre la pagina di accesso del servizio nel browser")
                    case .loggingIn:
                        ProgressView().controlSize(.small)
                        Button("Annulla") { state.mcp.cancelLogin(server.id) }
                    default:
                        EmptyView()
                    }
                    Toggle("Attivo", isOn: Binding(get: { server.enabled }, set: { enabled in
                        var updated = server
                        updated.enabled = enabled
                        state.mcp.save(updated)
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(server.enabled ? String(localized: "Disattiva il connettore") : String(localized: "Attiva il connettore"))
                    Menu {
                        Button("Riconnetti") { state.mcp.connect(server.id, interactive: true) }.disabled(!server.enabled)
                        Button("Modifica…", action: edit)
                        if server.transport == .http, state.mcp.hasLogin(server.id) {
                            Button("Esci dall'account") { state.mcp.logout(server.id) }
                        }
                        Divider()
                        Button("Rimuovi…", role: .destructive) { confirmRemove = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .iconHelp(String(localized: "Azioni del connettore"))
                }
                .confirmationDialog("Rimuovere «\(server.name)»?", isPresented: $confirmRemove) {
                    Button("Rimuovi", role: .destructive) { state.mcp.remove(server.id) }
                } message: { Text("Il connettore e il suo accesso verranno tolti. Puoi aggiungerlo di nuovo quando vuoi.") }
                .controlSize(.small)
                if status == .needsLogin || status == .loggingIn {
                    Text(status == .loggingIn
                         ? String(localized: "Completa l'accesso nella pagina aperta nel browser: Siri AI+ si collega da solo quando hai finito.")
                         : String(localized: "Questo servizio richiede l'accesso con il tuo account. Premi «Accedi…»: si apre la sua pagina di login e di autorizzazione."))
                        .font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                let tools = state.mcp.tools[server.id] ?? []
                if !tools.isEmpty {
                    Divider()
                    ForEach(tools) { tool in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tool.name).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                if !tool.description.isEmpty {
                                    Text(tool.description).font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer()
                            Toggle("Consenti sempre", isOn: Binding(get: { state.mcp.isAlwaysAllowed(tool) }, set: { state.mcp.setAlwaysAllow(tool, $0) }))
                                .toggleStyle(.checkbox)
                                .font(DS.Fonts.caption)
                        }
                    }
                }
            }
        }
    }

    private var color: Color {
        switch status {
        case .ready: .green
        case .connecting, .loggingIn: .yellow
        case .needsLogin: .orange
        case .failed: .red
        case .off: .gray
        }
    }
}

struct ServerEditor: View {
    let config: MCPServerConfig
    let done: (MCPServerConfig?) -> Void
    @State private var draft: MCPServerConfig
    @State private var argsText: String
    @State private var envText: String
    @State private var headersText: String

    init(config: MCPServerConfig, done: @escaping (MCPServerConfig?) -> Void) {
        self.config = config
        self.done = done
        _draft = State(initialValue: config)
        _argsText = State(initialValue: config.args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
        _envText = State(initialValue: config.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        _headersText = State(initialValue: config.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
    }

    var body: some View {
        let binding = $draft
        VStack(alignment: .leading, spacing: 14) {
            Text(config.name.isEmpty ? String(localized: "Nuovo connettore") : String(localized: "Modifica «\(config.name)»")).font(DS.Fonts.section)
            Form {
                TextField("Nome", text: binding.name)
                Picker("Tipo", selection: binding.transport) {
                    Text("Locale (comando)").tag(MCPServerConfig.Transport.stdio)
                    Text("Remoto (URL)").tag(MCPServerConfig.Transport.http)
                }
                if draft.transport == .stdio {
                    TextField("Comando", text: binding.command, prompt: Text("npx"))
                    TextField("Argomenti", text: $argsText, prompt: Text("-y @modelcontextprotocol/server-filesystem ~/Documenti"))
                    TextField("Variabili d'ambiente (una per riga, NOME=valore)", text: $envText, axis: .vertical)
                        .lineLimit(2...5)
                } else {
                    TextField("URL", text: binding.url, prompt: Text("https://esempio.com/mcp"))
                    TextField("Intestazioni (una per riga, Nome: valore)", text: $headersText, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annulla") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Salva e connetti") { done(finalConfig) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.isEmpty || (draft.transport == .stdio ? draft.command.isEmpty : draft.url.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var finalConfig: MCPServerConfig {
        var result = draft
        result.args = Self.splitArguments(argsText)
        result.env = Self.pairs(envText, separator: "=")
        result.headers = Self.pairs(headersText, separator: ":")
        result.enabled = true
        return result
    }

    static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for ch in text {
            if ch == "\"" { quoted.toggle(); continue }
            if ch == " " && !quoted {
                if !current.isEmpty { result.append(current); current = "" }
            } else { current.append(ch) }
        }
        if !current.isEmpty { result.append(current) }
        return result.map { ($0 as NSString).expandingTildeInPath }
    }

    static func pairs(_ text: String, separator: Character) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let index = line.firstIndex(of: separator) else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

struct ImportSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error = String?.none
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Importa da Claude Desktop").font(DS.Fonts.section)
            Text("Incolla il contenuto di claude_desktop_config.json (la sezione «mcpServers»).")
                .font(DS.Fonts.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.hairline))
            if let message = error { Text(message).font(DS.Fonts.caption).foregroundStyle(.red) }
            HStack {
                Button("Carica dal file di Claude") {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Claude/claude_desktop_config.json")
                    if let content = try? String(contentsOf: url, encoding: .utf8) { text = content } else { error = String(localized: "File di Claude Desktop non trovato.") }
                }
                Spacer()
                Button("Annulla") { dismiss() }
                Button("Importa") {
                    do {
                        let count = try state.mcp.importClaudeDesktop(text)
                        count > 0 ? dismiss() : (error = String(localized: "Nessun server trovato nel JSON."))
                    } catch {
                        self.error = String(localized: "JSON non valido: \(error.localizedDescription)")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
