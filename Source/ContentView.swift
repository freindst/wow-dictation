import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var b: LocalSpeech
    @ObservedObject var bridge: ControllerBridge
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Controller Speech").font(.largeTitle.bold()); Spacer(); Text("ON DEVICE").font(.caption.bold()).padding(8).background(.green.opacity(0.15)).clipShape(Capsule()) }
            Text("Apple SpeechAnalyzer · English (US) · No API key · No TypeWhisper").foregroundStyle(.secondary)
            HStack {
                Button(b.ready ? "Recheck English Model" : "Prepare English Model") { Task { await b.prepare() } }.disabled(b.busy || b.recording)
                if b.downloading { ProgressView(value: b.progress).frame(width: 180) }
                if b.busy { ProgressView().controlSize(.small) }
            }
            Text(b.status).textSelection(.enabled).frame(minHeight: 44, alignment: .leading)
            HStack {
                Button(b.recording ? "Stop & Transcribe" : "Start Recording") { if b.recording { b.stop() } else { Task { await b.start() } } }
                    .keyboardShortcut("r", modifiers: .command).buttonStyle(.borderedProminent).tint(b.recording ? .red : .accentColor).disabled(!b.ready || b.busy)
                Button("Open Audio File…") { b.openAudio() }.disabled(!b.ready || b.busy || b.recording)
                if b.busy && !b.downloading && b.ready { Button("Cancel") { b.cancel() } }
                Spacer()
                Text(String(format: "%.1f s", b.elapsed)).monospacedDigit()
                ProgressView(value: b.level).frame(width: 120).help("Microphone level")
            }
            BridgeView(bridge: bridge)
            Text("Transcript preview").font(.headline)
            TextEditor(text: $b.transcript).font(.system(size: 17)).padding(8).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 10)).frame(minHeight: 150)
            HStack { Button("Copy Text") { b.copy() }.disabled(b.transcript.isEmpty); Spacer(); Button("Export Measurements…") { b.export() }.disabled(b.runs.isEmpty) }
            Text("Measurements").font(.headline)
            List(b.runs) { run in
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(String(format: "%.0f ms", run.latency * 1000)).font(.title3.bold()).monospacedDigit(); Text("Stop → final result").foregroundStyle(.secondary); Spacer(); Text(String(format: "%.1f s audio", run.duration)) }
                    Text(run.text.isEmpty ? "(No speech detected)" : run.text).lineLimit(2)
                }.padding(.vertical, 5)
            }.frame(height: 160)
            Text("Transcription starts after Stop. Timing includes audio finalization and full-clip processing; it excludes speaking time and WoW delivery. First use may be slower. Recording is temporary and removed after processing. No live text while recording.").font(.caption).foregroundStyle(.secondary)
        }.padding(24) }.frame(minWidth: 860, minHeight: 780).onAppear { bridge.attach(b); Task { await b.prepareIfInstalled() } }
    }
}
