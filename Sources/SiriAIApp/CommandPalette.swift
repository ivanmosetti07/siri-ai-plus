import SiriCore
import SwiftUI

/// One keyboard entry point for destinations, projects and conversations.
struct CommandPalette: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var focused: Bool

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let action: () -> Void
    }

    private var entries: [Entry] {
        var items = [
            Entry(id: "new", title: "Nuova conversazione", subtitle: "Azione", symbol: "square.and.pencil") { state.newConversation(in: nil) },
            Entry(id: "home", title: "Home", subtitle: "Navigazione", symbol: "house") { state.section = .home },
            Entry(id: "agents", title: "Agenti", subtitle: "Navigazione", symbol: "person.2") { state.section = .agents },
            Entry(id: "schedule", title: "Programmazioni", subtitle: "Navigazione", symbol: "clock") { state.section = .schedule },
            Entry(id: "browser", title: "Browser", subtitle: "Navigazione", symbol: "safari") { state.section = .browser },
            Entry(id: "connectors", title: "Connettori", subtitle: "Navigazione", symbol: "puzzlepiece.extension") { state.section = .connectors },
            Entry(id: "settings", title: "Impostazioni", subtitle: "Navigazione", symbol: "gearshape") { state.openSettings() }
        ]
        items += state.sortedProjects.map { project in
            Entry(id: "p-\(project.id)", title: project.name, subtitle: "Progetto", symbol: "folder") { state.openProject(project) }
        }
        items += state.history.map { conversation in
            Entry(id: "c-\(conversation.id)", title: conversation.title, subtitle: "Conversazione", symbol: "bubble.left") {
                state.section = .home
                state.select(conversation)
            }
        }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(items.filter { search.isEmpty || $0.title.localizedStandardContains(search) || $0.subtitle.localizedStandardContains(search) }.prefix(40))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Cerca una chat, un progetto o un’azione", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { activate() }
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).iconHelp("Chiudi (Esc)")
            }
            .padding(20)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView.search(text: query).frame(height: 260)
            } else {
                List(entries, selection: $selection) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol).foregroundStyle(.secondary).frame(width: 24)
                        Text(item.title).lineLimit(1)
                        Spacer()
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                    .tag(item.id)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss(); item.action() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { dismiss(); item.action() }
                }
                .listStyle(.plain).frame(height: 320)
            }
            Divider()
            HStack {
                Text("↑ ↓ per scegliere · ↩ per aprire").foregroundStyle(.secondary)
                Spacer()
                Text("⌘K").foregroundStyle(.tertiary)
            }.font(.caption).padding(12)
        }
        .frame(width: 580)
        .onAppear { focused = true; selection = entries.first?.id }
        .onChange(of: query) { selection = entries.first?.id }
        .onMoveCommand { direction in
            guard let index = entries.firstIndex(where: { $0.id == selection }) else { selection = entries.first?.id; return }
            if direction == .down { selection = entries[min(entries.count - 1, index + 1)].id }
            if direction == .up { selection = entries[max(0, index - 1)].id }
        }
        .onExitCommand { dismiss() }
    }

    private func activate() {
        guard let entry = entries.first(where: { $0.id == selection }) ?? entries.first else { return }
        dismiss()
        entry.action()
    }
}
