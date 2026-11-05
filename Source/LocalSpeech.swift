import SwiftUI
import AVFoundation
import Speech
import AppKit

struct Measurement: Identifiable {
    let id = UUID()
    let date = Date()
    let latency: Double
    let duration: Double
    let text: String
}
@MainActor final class LocalSpeech: ObservableObject {
    var recordingStarted: (() -> Void)?
    var recordingStopped: (() -> Void)?
    var completed: ((String) -> Void)?
    var failed: (() -> Void)?
    @Published var status = "Click Prepare English Model to check or download Apple's on-device model."
    @Published var ready = false
    @Published var busy = false
    @Published var recording = false
    @Published var transcript = ""
    @Published var level: Double = 0
    @Published var elapsed: Double = 0
    @Published var progress: Double = 0
    @Published var downloading = false
    @Published var runs: [Measurement] = []
    private var module: SpeechTranscriber?
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var timer: Timer?
    private var started: Double = 0
    private var analyzer: SpeechAnalyzer?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var assetProgress: Progress?
    func prepare() async {
        busy = true; ready = false
        defer { busy = false; downloading = false; timer?.invalidate(); timer = nil }
        do {
            guard SpeechTranscriber.isAvailable else { throw failure("SpeechTranscriber is unavailable on this Mac.") }
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { throw failure("English (US) is not supported by this system.") }
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            let state = await AssetInventory.status(forModules: [transcriber])
            guard state != .unsupported else { throw failure("English model is unsupported.") }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                downloading = true; status = "Downloading English model from Apple. This one-time setup needs internet…"
                assetProgress = request.progress
                timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.progress = self?.assetProgress?.fractionCompleted ?? 0 }
                }
                try await request.downloadAndInstall()
            }
            module = transcriber; ready = true
            status = "English model ready · fully on-device · Start Recording or open an audio file."
        } catch { status = "Setup failed: \(error.localizedDescription)" }
    }
    func failure(_ message: String) -> NSError { NSError(domain: "LocalSpeechDemo", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func start() async {
        guard ready, !busy, !recording else { return }
        busy = true; defer { busy = false }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            status = "Microphone denied. Open System Settings → Privacy & Security → Microphone and allow Local Speech Demo."; return
        }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("local-speech-\(UUID().uuidString).wav")
            let r = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            r.isMeteringEnabled = true
            guard r.record() else { throw failure("Microphone recording could not start.") }
            recorder = r; audioURL = url; started = ProcessInfo.processInfo.systemUptime
            elapsed = 0; transcript = ""; recording = true
            recordingStarted?()
            status = "Recording. The meter should move as you speak. Press Stop & Transcribe when finished."
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.recorder?.updateMeters()
                    self.level = min(1, max(0, Double((self.recorder?.averagePower(forChannel: 0) ?? -60) + 60) / 60))
                    self.elapsed = ProcessInfo.processInfo.systemUptime - self.started
                }
            }
        } catch { status = "Recording failed: \(error.localizedDescription)"; failed?() }
    }
    func stop() {
        guard recording, let url = audioURL else { return }
        let stamp = ProcessInfo.processInfo.systemUptime
        let duration = stamp - started
        recorder?.stop(); recorder = nil; recording = false; timer?.invalidate(); timer = nil; level = 0; audioURL = nil
        recordingStopped?()
        transcribe(url, duration: duration, stamp: stamp, deleteAfter: true)
    }
    func openAudio() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribe(url, duration: 0, stamp: ProcessInfo.processInfo.systemUptime, deleteAfter: false)
    }
    func transcribe(_ url: URL, duration: Double, stamp: Double, deleteAfter: Bool) {
        busy = true; transcript = ""; status = "Transcribing locally… First use may take longer."
        let job = UUID(); generation = job
        operation = Task {
            defer { if deleteAfter { try? FileManager.default.removeItem(at: url) }; if generation == job { busy = false; analyzer = nil } }
            do {
                guard let module else { throw failure("Prepare English Model first.") }
                let file = try AVAudioFile(forReading: url)
                guard file.length > 0 else { throw failure("The audio file is empty. Please record a message or choose a nonempty audio file.") }
                let length = duration > 0 ? duration : Double(file.length) / file.processingFormat.sampleRate
                let engine = SpeechAnalyzer(modules: [module]); analyzer = engine
                let resultTask = Task { @MainActor () throws -> String in
                    var output = ""
                    for try await result in module.results {
                        try Task.checkCancellation()
                        guard generation == job else { throw CancellationError() }
                        output += String(result.text.characters)
                        transcript = output
                    }
                    return output
                }
                do {
                    if let last = try await engine.analyzeSequence(from: file) { try await engine.finalizeAndFinish(through: last) }
                    else { await engine.cancelAndFinishNow() }
                    let text = try await resultTask.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    try Task.checkCancellation()
                    guard generation == job else { return }
                    let latency = ProcessInfo.processInfo.systemUptime - stamp
                    transcript = text
                    completed?(text)
                    runs.insert(Measurement(latency: latency, duration: length, text: text), at: 0)
                    status = text.isEmpty ? "No speech recognized. Check the microphone meter, then try a longer sentence." : String(format: "Done · Stop → result %.0f ms · audio %.1f s", latency * 1000, length)
                } catch { resultTask.cancel(); await engine.cancelAndFinishNow(); throw error }
                // A result stream is single-use. Create a fresh module for the next run.
                self.module = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
            } catch {
                guard generation == job else { return }
                self.module = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
                failed?()
                status = error is CancellationError ? "Cancelled." : "Transcription failed: \(error.localizedDescription)"
            }
        }
    }
    func cancel() {
        generation = UUID(); operation?.cancel(); operation = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil; busy = false
        module = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
        status = "Cancelled. Ready for another recording."
        failed?()
    }
    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(transcript, forType: .string) }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "local-speech-results.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows: [[String: Any]] = runs.map { ["date": ISO8601DateFormatter().string(from: $0.date), "engine": "Apple SpeechAnalyzer / SpeechTranscriber", "locale": "en-US", "stop_to_result_ms": $0.latency * 1000, "audio_seconds": $0.duration, "text": $0.text] }
        do { try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: url) } catch { status = error.localizedDescription }
    }
    func shutdown() {
        generation = UUID()
        recorder?.stop(); recorder = nil
        timer?.invalidate(); timer = nil
        operation?.cancel(); operation = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
    }
}
