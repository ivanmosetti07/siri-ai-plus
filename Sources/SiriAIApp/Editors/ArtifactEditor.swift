import AppKit
import ImagePlayground
import SiriCore
import SwiftUI

/// Collegamento tra la chat e gli editor aperti (inserimento di immagini generate, slide selezionata).
@MainActor
enum EditorBridge {
    static var selectedSlide: [UUID: Int] = [:]
    /// Slide da mostrare dopo una modifica fatta dalla chat.
    static var focusSlide: [UUID: Int] = [:]
    /// Foglio visibile di ogni spreadsheet aperto.
    static var sheetIndex: [UUID: Int] = [:]
    static weak var pagesTextView: NSTextView?
    static var pagesArtifactID: UUID?

    static func insertImage(_ url: URL, into artifact: ArtifactModel) {
        switch artifact.content {
        case .document(let text):
            if pagesArtifactID == artifact.id, let view = pagesTextView, let image = ArtifactFactory.imageAttachment(url) {
                view.insertText(image, replacementRange: view.selectedRange())
            } else if let image = ArtifactFactory.imageAttachment(url) {
                let updated = NSMutableAttributedString(attributedString: text)
                updated.append(image)
                artifact.content = .document(updated)
            }
        case .deck(var deck):
            guard !deck.slides.isEmpty else { return }
            let index = min(selectedSlide[artifact.id] ?? 0, deck.slides.count - 1)
            var element = SlideElement(kind: .image, x: 0.52, y: 0.22, width: 0.4, height: 0.6)
            element.imagePath = url.path
            deck.slides[index].elements.append(element)
            artifact.content = .deck(deck)
        case .sheet:
            break
        }
    }
}

/// Editor a tutta larghezza al centro, con la struttura comune ai tre tipi.
struct ArtifactEditor: View {
    @Environment(AppState.self) private var state
    @Bindable var artifact: ArtifactModel
    @State private var showVersions = false
    @State private var working = false
    @State private var message = String?.none
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch artifact.kind {
                case .pages: PagesEditor(artifact: artifact)
                case .numbers: NumbersEditor(artifact: artifact)
                case .keynote: KeynoteEditor(artifact: artifact)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let text = message {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(text).font(DS.Fonts.caption).lineLimit(2)
                    Spacer()
                    if let url = artifact.exportedURL {
                        Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(.link).font(DS.Fonts.caption)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Il documento su una lastra di vetro sospesa sull'aurora, come le app.
        .background(Color.canvas.opacity(0.55))
        .clipShape(.rect(cornerRadius: 26))
        .glassCard(radius: 26)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Tile(artifact.kind, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Titolo", text: $artifact.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                Text("\(artifact.kind.app) · \(artifact.summary) · \(artifact.stateLabel)").font(DS.Fonts.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)

            Button { showVersions = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .iconHelp("Cronologia versioni")
                .popover(isPresented: $showVersions) { versions }

            Menu {
                ForEach(ArtifactFactory.formats(for: artifact.kind)) { format in
                    Button(format.label) { exportWithPanel(format) }
                }
            } label: { Image(systemName: "square.and.arrow.down") }
            .menuIndicator(.hidden)
            .fixedSize()
            .iconHelp("Esporta")

            Button { share() } label: { Image(systemName: "square.and.arrow.up") }
                .iconHelp("Condividi")

            Button("Salva") {
                if let url = state.save(artifact) { notify("Salvato come \(url.lastPathComponent)") }
            }
            .keyboardShortcut("s")
            .help(state.projectFolder(for: artifact) == nil ? "Salva in Documenti/Siri AI+" : "Salva nella cartella del progetto")

            Button {
                openInApp()
            } label: {
                if working { ProgressView().controlSize(.small) } else { Text("Apri in \(artifact.kind.app)") }
            }
            .buttonStyle(.borderedProminent)
            .tint(artifact.kind.tint)
            .disabled(working)

            Button { state.closeArtifact() } label: { Image(systemName: "xmark") }
                .keyboardShortcut("w")
                .iconHelp("Chiudi (⌘W)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var versions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cronologia").font(DS.Fonts.bodyStrong)
            ForEach(artifact.versions) { version in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(version.label).font(DS.Fonts.body)
                        Text(version.date.formatted(date: .abbreviated, time: .shortened)).font(DS.Fonts.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Ripristina") {
                        artifact.restore(version)
                        showVersions = false
                    }
                    .controlSize(.small)
                }
            }
            Divider()
            Button("Salva questa versione") { artifact.snapshot("Versione manuale"); showVersions = false }
                .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func notify(_ text: String) {
        withAnimation { message = text }
        Task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation { if message == text { message = nil } }
        }
    }

    private func exportWithPanel(_ format: ArtifactFactory.ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(ArtifactFactory.safeName(artifact.title)).\(format.rawValue)"
        panel.directoryURL = state.projectFolder(for: artifact) ?? ArtifactFactory.defaultFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try ArtifactFactory.export(artifact, as: format, to: url)
            state.log(icon: "artifact:\(artifact.kind.rawValue)", title: "\(artifact.kind.noun) esportat\(artifact.kind.ending)", detail: url.lastPathComponent, status: .done)
            notify("Esportato come \(url.lastPathComponent)")
        } catch {
            notify("Esportazione non riuscita: \(error.localizedDescription)")
        }
    }

    /// Condividere coinvolge altre persone: il selettore di sistema è il passaggio di conferma.
    private func share() {
        guard let format = ArtifactFactory.formats(for: artifact.kind).first,
              let url = try? ArtifactFactory.export(artifact, as: format, folder: state.projectFolder(for: artifact)),
              let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        let point = view.convert(NSApp.keyWindow?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        picker.show(relativeTo: CGRect(origin: point, size: CGSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
        state.log(icon: "artifact:\(artifact.kind.rawValue)", title: "Condivisione preparata", detail: url.lastPathComponent, status: .done)
    }

    private func openInApp() {
        working = true
        Task {
            do {
                try await ArtifactFactory.openInApp(artifact, folder: state.projectFolder(for: artifact))
                state.log(icon: "artifact:\(artifact.kind.rawValue)", title: "Aperto in \(artifact.kind.app)", detail: artifact.title, status: .done)
                notify(artifact.exportedURL.map { "Salvato come \($0.lastPathComponent) e aperto in \(artifact.kind.app)" } ?? "Aperto in \(artifact.kind.app)")
            } catch {
                notify("Non riesco ad aprirlo in \(artifact.kind.app): \(error.localizedDescription)")
            }
            working = false
        }
    }
}

/// Barra strumenti degli editor, stile iWork.
struct EditorToolbar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // Con la colonna di Siri AI+ aperta lo spazio può mancare: la barra scorre invece di allargare l'editor.
        ScrollView(.horizontal) {
            HStack(spacing: 6) { content }
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct ToolbarDivider: View {
    var body: some View { Divider().frame(height: 18).padding(.horizontal, 4) }
}

/// Popover per generare un'immagine con Image Playground da un editor.
struct GenerateImagePopover: View {
    @Environment(AppState.self) private var state
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    let onImage: (URL) -> Void
    @State private var showSheet = false
    @State private var prompt = ""
    @State private var style = "illustrazione"
    @State private var working = false
    @State private var error = String?.none
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Genera un'immagine").font(DS.Fonts.bodyStrong)
            TextField("Descrivi l'immagine", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            Picker("Stile", selection: $style) {
                ForEach(ImageService.styles, id: \.id) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let message = error { Text(message).font(DS.Fonts.caption).foregroundStyle(.red) }
            HStack {
                Text("Image Playground, sul dispositivo").font(DS.Fonts.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    working = true
                    error = nil
                    Task {
                        do {
                            onImage(try await state.quickImage(prompt: prompt, style: style))
                        } catch ImageService.ServiceError.unavailable {
                            // macOS 27: si passa dal foglio di sistema con la descrizione già scritta.
                            if supportsImagePlayground { showSheet = true } else { self.error = ImageService.ServiceError.unavailable.localizedDescription }
                        } catch {
                            self.error = error.localizedDescription
                        }
                        working = false
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Genera") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(14)
        .frame(width: 320)
        .imagePlaygroundSheet(isPresented: $showSheet, concept: prompt) { url in
            if let saved = state.keepImage(url) { onImage(saved) }
        }
    }
}

extension Color {
    init?(hexString: String?) {
        guard let hexString, let value = UInt32(hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
        self.init(hex: value)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
