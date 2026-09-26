import AVFoundation
import Foundation
import Observation
import Speech

/// Dettatura in italiano, riconosciuta sul dispositivo quando il Mac lo supporta.
@MainActor @Observable
final class Dictation {
    var isListening = false
    var transcript = ""
    var error: String?
    /// Livello audio 0…1 per l'animazione della forma d'onda.
    var level: Double = 0

    private final class Session: @unchecked Sendable {
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
    }

    private var session: Session?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "it-IT"))
    private var onFinish: ((String) -> Void)?

    func toggle(onFinish: @escaping (String) -> Void) {
        if isListening { stop() } else { Task { await start(onFinish: onFinish) } }
    }

    private func start(onFinish: @escaping (String) -> Void) async {
        error = nil
        let status = await Self.authorization()
        guard status == .authorized else {
            error = "Consenti il riconoscimento vocale in Impostazioni di Sistema › Privacy e sicurezza."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            error = "Il riconoscimento vocale in italiano non è disponibile."
            return
        }

        let session = Session()
        session.request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { session.request.requiresOnDeviceRecognition = true }

        let input = session.engine.inputNode
        Self.installTap(on: session) { [weak self] level in self?.level = level }
        do {
            session.engine.prepare()
            try session.engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.error = "Microfono non disponibile: \(error.localizedDescription)"
            return
        }

        transcript = ""
        self.onFinish = onFinish
        self.session = session
        isListening = true
        session.task = Self.recognize(session, with: recognizer) { [weak self] text, done in
            guard let self else { return }
            if let text { self.transcript = text }
            if done { self.stop() }
        }
    }

    // I callback di TCC, dell'audio e del riconoscimento arrivano su thread secondari:
    // le chiusure vanno create fuori dal MainActor, altrimenti Swift 6 termina l'app al primo richiamo.

    nonisolated private static func authorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    nonisolated private static func installTap(on session: Session, level: @escaping @MainActor @Sendable (Double) -> Void) {
        let input = session.engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            session.request.append(buffer)
            let value = rms(buffer)
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

    func stop() {
        guard let session else { return }
        self.session = nil
        session.engine.stop()
        session.engine.inputNode.removeTap(onBus: 0)
        session.request.endAudio()
        session.task?.finish()
        isListening = false
        level = 0
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onFinish?(text) }
        onFinish = nil
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return min(1, Double(sqrt(sum / Float(buffer.frameLength))) * 8)
    }
}
