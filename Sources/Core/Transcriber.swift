import AVFoundation
import Combine
import Foundation
import Speech

/// Streaming speech-to-text via Apple's Speech framework. Publishes the full
/// hypothesis (replace semantics — Apple re-emits the whole string on each
/// partial) plus a normalized audio level for the waveform.
@MainActor
final class Transcriber: NSObject, ObservableObject {

    @Published private(set) var partialText: String = ""
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var isActive = false
    @Published private(set) var lastError: String?

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // Adaptive level normalization (simplified from Freeflow's approach):
    // track a slow-moving floor/ceiling in dB so the waveform reads well at
    // any mic gain.
    private var floorDB: Float = -55
    private var ceilingDB: Float = -30

    func start() {
        guard !isActive else { return }
        lastError = nil
        partialText = ""

        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            lastError = "Speech recognition is unavailable for this language/device."
            return
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            lastError = "No usable microphone input."
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.rmsLevel(buffer: buffer)
            Task { @MainActor [weak self] in self?.updateLevel(rms: level) }
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.partialText = result.bestTranscription.formattedString
                }
                if let error, self.isActive {
                    // "No speech detected" style errors arrive on cancel too;
                    // only surface them while we're supposed to be listening.
                    let ns = error as NSError
                    if ns.domain != "kAFAssistantErrorDomain" || ns.code != 216 { // 216 = canceled
                        self.lastError = error.localizedDescription
                    }
                    self.stopEngineOnly()
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isActive = true
        } catch {
            lastError = "Could not start audio capture: \(error.localizedDescription)"
            input.removeTap(onBus: 0)
            task?.cancel()
            task = nil
            self.request = nil
        }
    }

    /// Stop listening and return the text recognized so far.
    @discardableResult
    func stop() -> String {
        let text = partialText
        stopEngineOnly()
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        return text
    }

    private func stopEngineOnly() {
        guard isActive || audioEngine.isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isActive = false
        audioLevel = 0
    }

    // MARK: - Metering

    private nonisolated static func rmsLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frames { sum += channelData[i] * channelData[i] }
        return sqrt(sum / Float(frames))
    }

    private func updateLevel(rms: Float) {
        let db = 20 * log10(max(rms, 1e-6))
        // Slow-adapting floor and ceiling.
        floorDB = db < floorDB ? floorDB * 0.88 + db * 0.12 : floorDB * 0.98 + db * 0.02
        ceilingDB = db > ceilingDB ? ceilingDB * 0.45 + db * 0.55 : ceilingDB * 0.96 + db * 0.04
        let span = max(ceilingDB - floorDB, 18)
        let normalized = max(0, min(1, (db - floorDB) / span))
        // Attack fast, release slow, and keep a small floor while speaking so
        // the bars never fully collapse mid-utterance.
        let smoothed = normalized > audioLevel
            ? audioLevel * 0.55 + normalized * 0.45
            : audioLevel * 0.88 + normalized * 0.12
        audioLevel = smoothed < 0.05 ? 0 : max(smoothed, 0.12)
    }
}
