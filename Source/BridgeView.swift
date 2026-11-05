import SwiftUI

struct BridgeView: View {
    @ObservedObject var bridge: ControllerBridge
    var body: some View {
        GroupBox("WoW Forever · controller bridge") {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Toggle("Enable controller bridge", isOn: $bridge.enabled); Spacer(); Button("Accessibility…") { bridge.requestAccessibility() }; Button("Refresh controller") { bridge.refresh() } }
                Text(bridge.controllerName + " · Last input: " + bridge.lastInput).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("Record / Stop", selection: $bridge.recordButton) { ForEach(bridge.choices, id: \.self) { Text($0) } }
                    Picker("Send", selection: $bridge.sendButton) { ForEach(bridge.choices, id: \.self) { Text($0) } }
                }.disabled(bridge.phase == "recording" || bridge.phase == "processing" || bridge.phase == "delivering")
                HStack { Text(String(format: "Preview → paste delay: %.1f s", bridge.delay)); Slider(value: $bridge.delay, in: 0.1...3, step: 0.1) }
                Text(bridge.status).font(.caption).textSelection(.enabled)
                Text("Reserve these controller buttons in WoW. Channel/recipient and Send are handled by the addon. Clipboard is replaced by each transcript.").font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
}
