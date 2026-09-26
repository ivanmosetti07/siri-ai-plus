import AppKit
import AVFoundation
import SiriCore
import SwiftUI

// MARK: - Memo Vocali

struct VoiceMemosAppView: View {
    @Environment(AppState.self) private var state
    @Environment(\.appTabActive) private var tabActive
    @State private var memos = [VoiceMemo]()
    @State private var selectedID: String?
    @State private var search = ""
    @State private var readable = VoiceMemosStore.readable
    @State private var recorder = MemoRecorder()
    /// Registrazione appena fatta: si trascrive da sola.
    @State private var justRecorded: String?

    private var visible: [VoiceMemo] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return memos }
        return memos.filter { $0.title.localizedCaseInsensitiveContains(query) || ($0.preview ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(source: .voiceMemos, title: String(localized: "Memo Vocali"), subtitle: memos.count == 1 ? String(localized: "1 registrazione") : String(localized: "\(memos.count) registrazioni"),
                      search: $search, searchPrompt: String(localized: "Cerca nelle registrazioni"), onRefresh: { reload() }) {
                Button { toggleRecording() } label: {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.red)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.borderless)
                .iconHelp(recorder.isRecording ? String(localized: "Ferma la registrazione") : String(localized: "Nuova registrazione"))
                .disabled(!state.canWrite(.voiceMemos))
            }
            Divider()
            HStack(spacing: 0) {
                memoList.frame(width: 320)
                Divider()
                if let memo = memos.first(where: { $0.id == selectedID }) {
                    MemoDetail(memo: memo, canWrite: state.canWrite(.voiceMemos), autoTranscribe: justRecorded == memo.id,
                               onChanged: { renamedTo in reload(select: renamedTo) }, onDeleted: { selectedID = nil; reload() })
                        .id(memo.id)
                } else {
                    AppPlaceholder(symbol: "waveform", title: memos.isEmpty ? String(localized: "Nessuna registrazione") : String(localized: "Nessuna registrazione selezionata"),
                                   message: String(localized: "Ascolta, trascrivi e riassumi i tuoi memo vocali, o registrane uno nuovo con il pulsante rosso."),
                                   actionTitle: state.canWrite(.voiceMemos) ? String(localized: "Registra") : nil, action: toggleRecording)
                }
            }
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !readable, VoiceMemosStore.readable { reload() }
        }
        .onChange(of: selectedID, initial: true) { _, id in if id == nil { state.publish(.memos(memos), for: .app(.voiceMemos)) } }
        .onChange(of: memos) { _, list in if selectedID == nil { state.publish(.memos(list), for: .app(.voiceMemos)) } }
        // Con la scheda dietro la registrazione continua (come in Memo Vocali): la scheda mostra il puntino rosso.
        .onChange(of: recorder.isRecording) { _, recording in state.recordingVoiceMemo = recording }
        .onChange(of: tabActive) { _, active in if active { reload() } }
        .onDisappear {
            if recorder.isRecording { finishRecording() }
            state.recordingVoiceMemo = false
        }
    }

    private var memoList: some View {
        VStack(spacing: 0) {
            ListHeading(title: String(localized: "Tutte le registrazioni"), count: "\(visible.count)")
            if !readable {
                InlineBanner(symbol: "lock", tint: .orange, text: String(localized: "Per vedere le registrazioni di Memo Vocali serve l'accesso completo al disco.")) {
                    Button("Concedi") { PermissionCenter.openSettings(.fullDisk) }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            if visible.isEmpty {
                AppPlaceholder(symbol: search.isEmpty ? "waveform" : "magnifyingglass", title: search.isEmpty ? String(localized: "Nessuna registrazione") : String(localized: "Nessun risultato"))
            } else {
                List(selection: $selectedID) {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.memos) { memo in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        if memo.isOwn { Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(Color.accentColor).help("Registrata in Siri AI+") }
                                        Text(memo.isOwn ? memo.title : (memo.preview.map { Self.headline($0) } ?? memo.title))
                                            .font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                    }
                                    HStack {
                                        // Senza trascrizione il titolo è già la data.
                                        Text(memo.preview == nil && !memo.isOwn ? String(localized: "Senza trascrizione") : memo.date.listStamp)
                                        Spacer()
                                        Text(memo.durationText).monospacedDigit()
                                    }
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                                .tag(memo.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            if recorder.isRecording {
                RecordingBar(recorder: recorder) { finishRecording() }
            }
        }
    }

    /// Le prime parole della trascrizione fanno da titolo (Apple cifra i titoli dei memo).
    static func headline(_ preview: String) -> String {
        let words = preview.split(separator: " ").prefix(7).joined(separator: " ")
        return words.isEmpty ? preview : "«\(words)…»"
    }

    private var groups: [(title: String, memos: [VoiceMemo])] {
        var order: [String] = []
        var map: [String: [VoiceMemo]] = [:]
        let cal = Calendar.current
        for memo in visible {
            let key = cal.isDateInToday(memo.date) ? String(localized: "Oggi") : cal.isDateInYesterday(memo.date) ? String(localized: "Ieri")
                : memo.date.formatted(.dateTime.month(.wide).year().locale(Dates.locale)).capitalized
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(memo)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private func reload(select id: String? = nil) {
        readable = VoiceMemosStore.readable
        memos = VoiceMemosStore.memos()
        if let id { selectedID = id }
        if let selectedID, !memos.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        if AppTesting.selectFirst, selectedID == nil { selectedID = memos.first?.id }
    }

    private func toggleRecording() {
        if recorder.isRecording { finishRecording(); return }
        guard state.canWrite(.voiceMemos) else { return }
        Task {
            do {
                try await recorder.start()
            } catch {
                state.appFailed(.voiceMemos, String(localized: "Registrazione non avviata"), error)
            }
        }
    }

    private func finishRecording() {
        guard let url = recorder.stop() else { return }
        state.appDone(.voiceMemos, String(localized: "Registrazione salvata"), detail: url.lastPathComponent)
        let id = "own:" + url.lastPathComponent
        justRecorded = id
        reload(select: id)
    }
}

// MARK: - Barra di registrazione

private struct RecordingBar: View {
    let recorder: MemoRecorder
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(.red).frame(width: 10, height: 10)
            Text(VoiceMemo.format(recorder.elapsed)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
            // Livello del microfono.
            GeometryReader { geo in
                Capsule().fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.red.gradient).frame(width: max(4, geo.size.width * CGFloat(recorder.level)))
                    }
            }
            .frame(height: 6)
            Button(action: onStop) {
                Image(systemName: "stop.circle.fill").font(.system(size: 26)).foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .iconHelp(String(localized: "Ferma e salva"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - Dettaglio

private struct MemoDetail: View {
    @Environment(AppState.self) private var state
    let memo: VoiceMemo
    let canWrite: Bool
    let autoTranscribe: Bool
    let onChanged: (String?) -> Void
    let onDeleted: () -> Void
    @State private var player = MemoPlayer()
    @State private var transcript: String?
    @State private var transcribing = false
    @State private var error: String?
    @State private var name = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        if memo.isOwn {
                            TextField("Nome", text: $name)
                                .textFieldStyle(.plain)
                                .font(.system(size: 22, weight: .bold))
                                .onSubmit(rename)
                                .disabled(!canWrite)
                        } else {
                            Text(memo.preview.map { VoiceMemosAppView.headline($0) } ?? memo.title).font(.system(size: 22, weight: .bold))
                        }
                        let dateIsTitle = !memo.isOwn && memo.preview == nil
                        Text(dateIsTitle ? String(localized: "Durata \(memo.durationText)")
                             : String(localized: "\(memo.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute().locale(Dates.locale))) · \(memo.durationText)"))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        Text(memo.isOwn ? String(localized: "Registrata in Siri AI+") : String(localized: "Da Memo Vocali")).font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    playerControls
                    transcriptSection
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            InspectorFooter {
                if memo.isOwn {
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                        .iconHelp(String(localized: "Sposta nel Cestino")).disabled(!canWrite)
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([memo.url]) } label: { Image(systemName: "folder") }
                    .iconHelp(String(localized: "Mostra nel Finder"))
                if !memo.isOwn {
                    Button { SourceKind.voiceMemos.openSystemApp() } label: { Image(systemName: "arrow.up.forward.app") }
                        .iconHelp(String(localized: "Apri Memo Vocali"))
                }
            } trailing: {
                Button { createNote() } label: { Label("Crea nota", systemImage: "note.text.badge.plus") }
                    .disabled(transcript == nil || !state.canWrite(.notes))
                Button { summarize() } label: { Label("Riassumi", systemImage: "sparkle") }
                    .buttonStyle(.borderedProminent)
                    .disabled(transcript == nil)
            }
        }
        .task {
            name = memo.title
            player.load(memo.url)
            transcript = VoiceMemosStore.storedTranscript(id: memo.id, url: memo.url)
            if transcript == nil, autoTranscribe { await transcribe() }
        }
        .onDisappear { player.stop() }
        // Siri AI+ vede la registrazione aperta con la sua trascrizione: «riassumila», «crea una nota da questa registrazione».
        .onChange(of: transcript, initial: true) { _, transcript in state.publish(.memo(memo, transcript: transcript), for: .app(.voiceMemos)) }
        .confirmationDialog("Spostare «\(memo.title)» nel Cestino?", isPresented: $confirmDelete) {
            Button("Sposta nel Cestino", role: .destructive) {
                do {
                    player.stop()
                    try VoiceMemosStore.trash(memo)
                    state.appDone(.voiceMemos, String(localized: "Registrazione nel Cestino"), detail: memo.title)
                    onDeleted()
                } catch { state.appFailed(.voiceMemos, String(localized: "Registrazione non eliminata"), error) }
            }
        } message: {
            Text("Si recupera dal Cestino del Finder.")
        }
    }

    private var playerControls: some View {
        VStack(spacing: 10) {
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...max(0.1, player.duration))
                .controlSize(.small)
            HStack {
                Text(VoiceMemo.format(player.currentTime)).monospacedDigit()
                Spacer()
                Text("-" + VoiceMemo.format(max(0, player.duration - player.currentTime))).monospacedDigit()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            HStack(spacing: 26) {
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button(String(format: "%.2g×", rate)) { player.rate = Float(rate) }
                    }
                } label: { Text(String(format: "%.2g×", player.rate)).font(.system(size: 13, weight: .semibold)) }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
                .iconHelp(String(localized: "Velocità"))
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.system(size: 20)) }
                    .buttonStyle(.borderless).iconHelp(String(localized: "Indietro di 15 secondi"))
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 44))
                }
                .buttonStyle(.plain)
                .iconHelp(player.playing ? String(localized: "Pausa") : String(localized: "Ascolta"))
                Button { player.skip(15) } label: { Image(systemName: "goforward.15").font(.system(size: 20)) }
                    .buttonStyle(.borderless).iconHelp(String(localized: "Avanti di 15 secondi"))
                Color.clear.frame(width: 30, height: 1)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TRASCRIZIONE").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let transcript {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript, forType: .string)
                        state.showToast(String(localized: "Trascrizione copiata"), symbol: "doc.on.doc")
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).iconHelp(String(localized: "Copia la trascrizione"))
                }
            }
            if let transcript {
                Text(transcript).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if transcribing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Trascrivo sul Mac…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error ?? String(localized: "Questa registrazione non ha ancora una trascrizione. La faccio sul Mac, senza inviare l'audio a nessuno."))
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button { Task { await transcribe() } } label: { Label("Trascrivi", systemImage: "text.bubble") }
                }
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func transcribe() async {
        transcribing = true
        error = nil
        defer { transcribing = false }
        do {
            let text = try await VoiceMemosStore.transcribe(memo.url)
            guard !text.isEmpty else { error = String(localized: "Non ho sentito parole in questa registrazione."); return }
            VoiceMemosStore.saveTranscript(text, for: memo)
            transcript = text
            onChanged(nil)
        } catch {
            self.error = String(localized: "Trascrizione non riuscita: \(error.localizedDescription)")
        }
    }

    private func rename() {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard memo.isOwn, !clean.isEmpty, clean != memo.title else { return }
        do {
            player.stop()
            let url = try VoiceMemosStore.rename(memo, to: clean)
            state.appDone(.voiceMemos, String(localized: "Registrazione rinominata"), detail: clean)
            onChanged("own:" + url.lastPathComponent)
        } catch { state.appFailed(.voiceMemos, String(localized: "Registrazione non rinominata"), error) }
    }

    private func summarize() {
        guard let transcript else { return }
        let when = memo.date.formatted(.dateTime.day().month(.wide).hour().minute().locale(Dates.locale))
        state.send(String(localized: "Riassumi questo memo vocale del \(when) e dimmi se c'è qualcosa da fare:\n\n«\(transcript.prefix(6000))»"))
    }

    private func createNote() {
        guard let transcript else { return }
        let title = String(localized: "Memo vocale del ") + memo.date.formatted(.dateTime.day().month(.wide).year().locale(Dates.locale))
        Task {
            do {
                try await NotesStore.create(title: title, body: transcript, in: nil)
                state.appDone(.notes, String(localized: "Nota creata dalla trascrizione"), detail: title)
            } catch { state.appFailed(.notes, String(localized: "Nota non creata"), error) }
        }
    }
}

// MARK: - Riproduzione e registrazione

@MainActor @Observable
final class MemoPlayer {
    var playing = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var rate: Float = 1 { didSet { player?.rate = rate } }
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    func load(_ url: URL) {
        player = try? AVAudioPlayer(contentsOf: url)
        player?.enableRate = true
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            playing = false
            timer?.invalidate()
        } else {
            player.rate = rate
            player.play()
            playing = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let player = self.player else { return }
                    self.currentTime = player.currentTime
                    if !player.isPlaying { self.playing = false; self.timer?.invalidate() }
                }
            }
        }
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = max(0, min(time, duration))
        currentTime = player?.currentTime ?? 0
    }

    func skip(_ seconds: TimeInterval) { seek(to: (player?.currentTime ?? 0) + seconds) }

    func stop() {
        player?.stop()
        playing = false
        timer?.invalidate()
    }
}

@MainActor @Observable
final class MemoRecorder {
    var isRecording = false
    var elapsed: TimeInterval = 0
    var level: Float = 0
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?

    func start() async throws {
        // Il microfono lo chiede macOS la prima volta (poi lo ricorda).
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw NSError(domain: AppInfo.name, code: 31, userInfo: [NSLocalizedDescriptionKey: String(localized: "Siri AI+ non ha il permesso di usare il microfono: Impostazioni di Sistema › Privacy e sicurezza › Microfono.")])
        }
        let url = VoiceMemosStore.newRecordingURL()
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                                       AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw NSError(domain: AppInfo.name, code: 32, userInfo: [NSLocalizedDescriptionKey: String(localized: "Il microfono non è disponibile.")])
        }
        self.recorder = recorder
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.elapsed = recorder.currentTime
                // Da decibel (-60…0) a 0…1.
                self.level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 60) / 60))
            }
        }
    }

    /// Ferma e restituisce il file salvato.
    func stop() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        timer?.invalidate()
        isRecording = false
        level = 0
        self.recorder = nil
        return recorder.url
    }
}
