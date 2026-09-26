import AVFoundation
import Foundation
import Observation
import Speech
import SwiftUI

/// Conversazione a voce continua, solo con componenti Apple: riconoscimento vocale sul dispositivo,
/// Apple Intelligence per la risposta e voci di sistema per parlare. Ascolta → risponde → riascolta.
@MainActor @Observable
final class VoiceMode {
    enum Phase: Equatable { case idle, listening, thinking, speaking }

    var active = false
    var phase: Phase = .idle
    var transcript = ""
    var reply = ""
    var level: Double = 0
    var error: String?
    var muted = false

    var voiceIdentifier: String = UserDefaults.standard.string(forKey: "voiceIdentifier") ?? "" {
        didSet { UserDefaults.standard.set(voiceIdentifier, forKey: "voiceIdentifier") }
    }
    var rate: Double = UserDefaults.standard.object(forKey: "voiceRate") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(rate, forKey: "voiceRate") }
    }

    private final class Session: @unchecked Sendable {
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
    }

    private var session: Session?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "it-IT"))
    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = SpeechDelegate()
    private weak var state: AppState?
    private var lastChange = Date.distantPast

    /// Voci italiane installate, dalla qualità migliore.
    static var italianVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("it") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality = switch voice.quality {
        case .premium: " (Premium)"
        case .enhanced: " (Migliorata)"
        default: ""
        }
        return voice.name + quality
    }

    func start(with state: AppState) {
        self.state = state
        active = true
        error = nil
        reply = ""
        synthesizer.delegate = delegate
        delegate.onFinish = { [weak self] in
            Task { @MainActor in
                guard let self, self.active, self.phase == .speaking else { return }
                self.listen()
            }
        }
        listen()
    }

    func close() {
        active = false
        stopListening()
        synthesizer.stopSpeaking(at: .immediate)
        phase = .idle
        transcript = ""
    }

    /// Tocca l'orb: interrompe la voce e torna ad ascoltare.
    func interrupt() {
        if phase == .speaking {
            synthesizer.stopSpeaking(at: .immediate)
            listen()
        } else if phase == .listening {
            finishUtterance()
        }
    }

    func toggleMute() {
        muted.toggle()
        if muted { stopListening(); phase = .idle } else { listen() }
    }

    // MARK: Ascolto

    private func listen() {
        guard active, !muted else { return }
        stopListening()
        transcript = ""
        phase = .listening
        Task {
            guard await Self.authorization() == .authorized else {
                error = "Consenti il riconoscimento vocale in Impostazioni di Sistema › Privacy e sicurezza."
                phase = .idle
                return
            }
            guard let recognizer, recognizer.isAvailable else {
                error = "Il riconoscimento vocale in italiano non è disponibile."
                phase = .idle
                return
            }
            let session = Session()
            session.request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { session.request.requiresOnDeviceRecognition = true }
            Self.installTap(on: session) { [weak self] level in self?.level = level }
            do {
                session.engine.prepare()
                try session.engine.start()
            } catch {
                session.engine.inputNode.removeTap(onBus: 0)
                self.error = "Microfono non disponibile: \(error.localizedDescription)"
                phase = .idle
                return
            }
            self.session = session
            lastChange = .now
            session.task = Self.recognize(session, with: recognizer) { [weak self] text, done in
                guard let self, self.phase == .listening else { return }
                if let text, text != self.transcript {
                    self.transcript = text
                    self.lastChange = .now
                }
                if done { self.finishUtterance() }
            }
            watchSilence()
        }
    }

    /// Dopo una pausa di circa 1,3 secondi la frase è finita e si invia.
    private func watchSilence() {
        Task {
            while active, phase == .listening {
                try? await Task.sleep(for: .milliseconds(250))
                if !transcript.isEmpty, Date.now.timeIntervalSince(lastChange) > 1.3 {
                    finishUtterance()
                    return
                }
            }
        }
    }

    private func stopListening() {
        guard let session else { return }
        self.session = nil
        session.engine.stop()
        session.engine.inputNode.removeTap(onBus: 0)
        session.request.endAudio()
        session.task?.cancel()
        level = 0
    }

    private func finishUtterance() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopListening()
        guard !text.isEmpty, let state else { listen(); return }
        phase = .thinking
        reply = ""
        state.send(text)
        Task { await waitForReply(after: text) }
    }

    // MARK: Risposta e voce

    private func waitForReply(after text: String) async {
        guard let state else { return }
        try? await Task.sleep(for: .milliseconds(300))
        while state.isResponding { try? await Task.sleep(for: .milliseconds(250)) }
        guard active else { return }
        let messages = state.current?.messages ?? []
        let start = messages.lastIndex { if case .user = $0.content { true } else { false } } ?? 0
        let answer = messages[start...].compactMap { message -> String? in
            if case .text(let text) = message.content { return text }
            return nil
        }.joined(separator: "\n")
        reply = answer.isEmpty ? "Ho preparato una scheda: controllala sullo schermo." : answer
        speak(Self.spoken(reply))
    }

    private func speak(_ text: String) {
        phase = .speaking
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) ?? Self.italianVoices.first ?? AVSpeechSynthesisVoice(language: "it-IT")
        utterance.rate = AVSpeechUtteranceMinimumSpeechRate + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * Float(rate)
        synthesizer.speak(utterance)
    }

    func preview() {
        let utterance = AVSpeechUtterance(string: "Ciao Ivan, sono Siri AI+. Come posso aiutarti?")
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) ?? Self.italianVoices.first
        utterance.rate = AVSpeechUtteranceMinimumSpeechRate + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * Float(rate)
        synthesizer.speak(utterance)
    }

    /// Testo da leggere: senza Markdown, link e rimandi alle fonti.
    static func spoken(_ text: String) -> String {
        var result = text
        for pattern in [#"\[(\d+)\]"#, #"\*\*|__|`|#+ "#, #"\((https?://[^)]+)\)"#, #"https?://\S+"#] {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: #"^\s*[-*•]\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n\n", with: "\n")
        return String(result.prefix(1800))
    }

    // MARK: Callback fuori dal MainActor (vedi Dictation)

    nonisolated private static func authorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    nonisolated private static func installTap(on session: Session, level: @escaping @MainActor @Sendable (Double) -> Void) {
        let input = session.engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            session.request.append(buffer)
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            let value = min(1, Double(sqrt(sum / Float(buffer.frameLength))) * 8)
            Task { @MainActor in level(value) }
        }
    }

    nonisolated private static func recognize(_ session: Session, with recognizer: SFSpeechRecognizer,
                                              update: @escaping @MainActor @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: session.request) { result, error in
            let text = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in update(text, done) }
        }
    }
}

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onFinish: (@Sendable () -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }
}

/// Schermata della modalità vocale sopra la finestra.
struct VoiceModeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let voice = state.voice
        ZStack {
            Rectangle().fill(.clear).glassEffect(.regular, in: .rect).ignoresSafeArea()
            VStack(spacing: 26) {
                HStack {
                    Label("Modalità vocale", systemImage: "waveform").font(DS.Fonts.bodyStrong)
                    Spacer()
                    Button { voice.close() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 22)) }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.escape, modifiers: [])
                        .iconHelp("Chiudi (Esc)")
                }
                Spacer()
                Button { voice.interrupt() } label: {
                    OrbView(state: orbState(voice.phase), size: 150)
                        .scaleEffect(1 + (voice.phase == .listening ? voice.level * 0.25 : 0))
                        .animation(.easeOut(duration: 0.12), value: voice.level)
                }
                .buttonStyle(.plain)
                .help(voice.phase == .speaking ? "Interrompi e parla" : "Tocca per inviare subito")
                Text(caption(voice)).font(DS.Fonts.body).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 14) {
                        if !voice.transcript.isEmpty {
                            Text(voice.transcript).font(.system(size: 20, weight: .medium)).multilineTextAlignment(.center)
                        }
                        if !voice.reply.isEmpty, voice.phase != .listening {
                            Text(voice.reply).font(DS.Fonts.message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        if let error = voice.error { Text(error).font(DS.Fonts.caption).foregroundStyle(.red) }
                    }
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: 220)
                Spacer()
                HStack(spacing: 18) {
                    Button { voice.toggleMute() } label: {
                        Image(systemName: voice.muted ? "mic.slash.fill" : "mic.fill").font(.system(size: 18)).frame(width: 48, height: 48)
                            .background(Color.primary.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(voice.muted ? "Riattiva il microfono" : "Silenzia il microfono")
                    Button { voice.close() } label: {
                        Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white).frame(width: 48, height: 48)
                            .background(Color.red, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .iconHelp("Termina")
                }
                Text("Tutto sul Mac: riconoscimento vocale e voce di sistema Apple.").font(DS.Fonts.caption).foregroundStyle(.tertiary)
            }
            .padding(30)
        }
        .transition(.opacity)
    }

    private func orbState(_ phase: VoiceMode.Phase) -> OrbState {
        switch phase {
        case .idle: .idle
        case .listening: .listening
        case .thinking: .thinking
        case .speaking: .done
        }
    }

    private func caption(_ voice: VoiceMode) -> String {
        if voice.muted { return "Microfono silenziato" }
        switch voice.phase {
        case .idle: return "Pronto"
        case .listening: return voice.transcript.isEmpty ? "Ti ascolto…" : "Ti ascolto… (fai una pausa per inviare)"
        case .thinking: return state.statusText.isEmpty ? "Sto pensando…" : state.statusText
        case .speaking: return "Sto parlando — tocca l'orb per interrompere"
        }
    }
}
