import AppKit
import SiriCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Conversazione

struct ConversationThread: View {
    let conversation: Conversation
    @Environment(\.compactLayout) private var compact

    @State private var followsLatest = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scrollKey: String {
        guard let last = conversation.messages.last else { return "0" }
        let length: Int = if case .text(let text) = last.content { text.count } else { 0 }
        return "\(conversation.messages.count)-\(length)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: compact ? 14 : 18) {
                    ForEach(conversation.messages) { message in
                        MessageView(message: message).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: DS.readingWidth)
                .padding(.horizontal, compact ? 14 : 28)
                .padding(.top, compact ? 14 : 24)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 100
            } action: { _, nearBottom in followsLatest = nearBottom }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    Button {
                        followsLatest = true
                        withAnimation(reduceMotion ? nil : DS.Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: { Label("Ultimi messaggi", systemImage: "arrow.down") }
                    .buttonStyle(.bordered).glassEffect(.regular, in: .capsule).padding(16)
                }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: scrollKey) {
                guard followsLatest else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

struct SuggestionRow: View {
    let symbol: String
    let text: String
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(text).font(DS.Fonts.body).multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovered ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(hovered ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Messaggi

struct MessageView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var state
    @Environment(\.compactLayout) private var compact
    let message: Message

    var body: some View {
        switch message.content {
        case .user(let text, let sources, let attachments):
            HStack {
                Spacer(minLength: compact ? 36 : 80)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(text)
                        .font(DS.Fonts.message)
                        .textSelection(.enabled)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .modifier(UserBubble())
                    if !sources.isEmpty || !attachments.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(sources) { Tile($0, size: 14) }
                            if !sources.isEmpty { Text("Solo queste fonti").font(DS.Fonts.caption).foregroundStyle(.secondary) }
                            ForEach(attachments, id: \.self) { name in
                                Label(name, systemImage: "doc").font(DS.Fonts.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

        case .text(let text):
            AssistantRow {
                RichText(text: text)
            }
            .modifier(CopyOnHover(text: text))

        case .thinking(let text):
            HStack(spacing: 10) {
                OrbView(state: .thinking, size: 22)
                Text(text)
                    .font(DS.Fonts.body)
                    .foregroundStyle(.secondary)
                    .phaseAnimator(reduceMotion ? [1.0] : [0.45, 1]) { view, phase in view.opacity(phase) } animation: { _ in .easeInOut(duration: 0.9) }
            }

        case .notice(let text):
            Text(text).font(DS.Fonts.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center)

        case .agenda(let agenda): Indented { AgendaCard(agenda: agenda) }
        case .event(let model): Indented { EventCard(model: model) }
        case .reminders(let model): Indented { RemindersCard(model: model) }
        case .confirm(let model): Indented { ConfirmCard(model: model) }
        case .mail(let model): Indented { MailCard(model: model) }
        case .plan(let model): Indented { PlanCard(model: model) }
        case .artifact(let artifact): Indented { ArtifactChip(artifact: artifact) }
        case .unavailable(let model): Indented { UnavailableCard(model: model) }
        case .image(let model): Indented { ImageCard(model: model) }
        case .files(let paths): Indented { FilesCard(paths: paths) }
        case .web(let answer): Indented { WebSourcesCard(answer: answer) }
        case .taskPlan(let model): Indented { TaskPlanCard(model: model) }
        case .chatLink(let link): Indented { ChatLinkCard(link: link) }
        case .agentDraft(let model): Indented { AgentDraftCard(model: model) }
        case .website(let model): Indented { WebsiteCard(model: model) }
        case .items(let items): Indented { AppItemsCard(items: items) }
        case .note(let model): Indented { NoteDraftCard(model: model) }
        case .noteAppend(let model): Indented { NoteAppendCard(model: model) }
        case .forward(let model): Indented { MailForwardCard(model: model) }
        case .imessage(let model): Indented { MessageDraftCard(model: model) }
        case .fileWrite(let model): Indented { FileWriteCard(model: model) }
        case .fileOp(let model): Indented { FileOpCard(model: model) }
        case .mcp(let model): Indented { MCPCallCard(model: model) }
        case .trace(let trace): Indented { TraceRow(trace: trace) }
        case .privacy(let report): Indented { PrivacyRow(report: report) }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// Testo di una risposta. Il Markdown in linea (grassetti, link, codice) resta quello di sempre; in più titoli e tabelle,
/// che servono ai confronti e alle risposte ordinate.
struct RichText: View {
    let text: String

    enum Block: Hashable {
        case text(String), heading(String), table([[String]])
        /// Codice tra ``` (con il linguaggio, se c'è).
        case code(language: String, body: String)
        /// Riga di separazione (---).
        case rule
    }

    var body: some View {
        // Il caso comune (niente tabelle, titoli né codice) resta un solo testo selezionabile.
        if !text.contains("|") && !text.contains("#") && !text.contains("```") && !text.contains("\n---") {
            paragraph(text)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let part): paragraph(part)
                    case .heading(let title):
                        Text(MessageView.markdown(title)).font(DS.Fonts.bodyStrong).padding(.top, 2)
                    case .table(let rows): TableBlock(rows: rows)
                    case .code(let language, let body): CodeBlock(language: language, code: body)
                    case .rule: Divider().padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func paragraph(_ part: String) -> some View {
        Text(MessageView.markdown(part))
            .font(DS.Fonts.message)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var buffer: [String] = []
        func flush() {
            let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.text(joined)) }
            buffer = []
        }
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            // Codice: dalla riga ``` alla successiva (se il recinto non si chiude, fino in fondo).
            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language, body: body.joined(separator: "\n")))
                continue
            }
            // Tabella: riga d'intestazione con le barre e riga di separazione (| --- | --- |).
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isSeparator(lines[index + 1]) {
                flush()
                var rows = [cells(trimmed)]
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index]))
                    index += 1
                }
                blocks.append(.table(rows))
                continue
            }
            if trimmed.range(of: #"^(?:-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }
            if let heading = trimmed.range(of: #"^#{1,4}\s+"#, options: .regularExpression) {
                flush()
                blocks.append(.heading(String(trimmed[heading.upperBound...])))
                index += 1
                continue
            }
            buffer.append(lines[index])
            index += 1
        }
        flush()
        return blocks
    }

    static func isSeparator(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).range(of: #"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$"#, options: .regularExpression) != nil
    }

    static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Codice in una risposta: carattere a spaziatura fissa, righe lunghe che scorrono, pulsante per copiarlo.
struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? String(localized: "codice") : language).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? String(localized: "Copiato") : String(localized: "Copia"), systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05))
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
            .scrollIndicators(.automatic)
        }
        .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(Color.hairline.opacity(0.5)))
    }
}

/// Tabella Markdown resa con una griglia: intestazione in grassetto, righe allineate.
struct TableBlock: View {
    let rows: [[String]]

    var body: some View {
        let width = rows.map(\.count).max() ?? 0
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<width, id: \.self) { column in
                        Text(MessageView.markdown(column < row.count ? row[column] : ""))
                            .font(index == 0 ? DS.Fonts.bodyStrong : DS.Fonts.message)
                            // Le celle lunghe vanno a capo invece di essere troncate.
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
            }
        }
        .padding(12)
        .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .textSelection(.enabled)
    }
}

/// La bolla dell'utente: vetro con una punta del colore dell'app (un velo nel pannello di destra).
struct UserBubble: ViewModifier {
    @Environment(\.compactLayout) private var compact

    func body(content: Content) -> some View {
        if compact {
            content.background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            content.glassEffect(.regular.tint(Color.accentColor.opacity(0.22)), in: .rect(cornerRadius: 20))
        }
    }
}

struct AssistantRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            OrbView(state: .idle, size: 22, animated: false).padding(.top, 1)
            content
        }
    }
}

/// Allinea le schede al testo dell'assistente, sotto l'orb.
struct Indented<Content: View>: View {
    @Environment(\.compactLayout) private var compact
    @ViewBuilder var content: Content
    var body: some View { content.padding(.leading, compact ? 0 : 32) }
}

/// «Copia» che compare quando il mouse passa sulla risposta.
struct CopyOnHover: ViewModifier {
    let text: String
    @State private var hovered = false
    @State private var copied = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .overlay(alignment: .bottomTrailing) {
                if hovered || copied {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .contentTransition(.symbolEffect(.replace))
                            .padding(5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .iconHelp(copied ? String(localized: "Copiato") : String(localized: "Copia la risposta"))
                    .offset(y: 20)
                    .transition(.opacity)
                }
            }
            .animation(DS.Motion.quick, value: hovered)
    }
}
