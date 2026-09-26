import AppKit
import SiriCore
import SwiftUI
import UniformTypeIdentifiers

/// Home: conversazione a tutta larghezza; quando è vuota mostra la panoramica del giorno sul cielo animato.
struct HomeView: View {
    @Environment(AppState.self) private var state
    @Environment(\.chatNamespace) private var chatSpace
    @State private var showMigrationNotice = UserDefaults.standard.bool(forKey: "migrationNotice")

    private var showsDashboard: Bool { state.current.map { $0.messages.isEmpty } ?? true }

    var body: some View {
        Group {
            if showsDashboard {
                HomeDashboard()
                    .overlay(alignment: .top) { banners }
            } else if let conversation = state.current {
                VStack(spacing: 0) {
                    banners
                    ConversationThread(conversation: conversation)
                }
            }
        }
        // Il campo di scrittura galleggia sopra la Home: il cielo continua sotto di lui.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Composer(placeholder: String(localized: "Chiedi qualsiasi cosa a Siri AI+…"))
                .frame(maxWidth: DS.readingWidth)
                .frame(maxWidth: .infinity)
        }
        // Con una conversazione in corso è la stessa lastra della colonna destra: aprendo un documento scivola là.
        .modifier(ChatGeometry(namespace: showsDashboard ? nil : chatSpace))
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if showMigrationNotice {
                InlineBanner(symbol: "sparkles", tint: .purple,
                             text: String(localized: "SiriAI ora si chiama Siri AI+: i tuoi dati sono al loro posto. macOS chiederà di nuovo i permessi (Calendario, Promemoria, Automazione, Microfono, Contatti) perché l'app ha un nuovo identificatore.")) {
                    Button("Privacy…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!) }
                    Button("Ho capito") { UserDefaults.standard.set(false, forKey: "migrationNotice"); showMigrationNotice = false }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.top, DS.Space.md)
            }
            if let conversation = state.current, conversation.parentID != nil { ChildChatBanner(conversation: conversation) }
        }
    }
}
