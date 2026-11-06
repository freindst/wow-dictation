import SwiftUI

struct BridgeView: View {
    @ObservedObject var bridge: ControllerBridge
    private var busy: Bool { bridge.phase == "recording" || bridge.phase == "processing" || bridge.phase == "delivering" }

    var body: some View {
        GroupBox("WoW Forever · dictation bridge") {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Toggle("Enable bridge", isOn: $bridge.enabled); Spacer(); Button("Accessibility…") { bridge.requestAccessibility() }; Button("Refresh controller") { bridge.refresh() } }
                Text(bridge.controllerName + " · Last input: " + bridge.lastInput).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text("In-game Record / Stop:").bold()
                    Text(bridge.inGameLabel).textSelection(.enabled)
                    Spacer()
                    Button("Reread") { bridge.reloadInGameBindings() }
                }
                Text("Set it in WoW: /ld keys → Record / Stop, then /reload. The helper reads it from the addon's saved settings. The keyboard and controller settings below are optional extras.").font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Action").font(.caption.bold())
                        Text("Keyboard combination").font(.caption.bold())
                        Text("Controller combination").font(.caption.bold())
                    }
                    ForEach(BridgeAction.allCases) { action in
                        GridRow {
                            Text(action.title).frame(width: 100, alignment: .leading)
                            HStack {
                                badge(isCapturing(action, controller: false) ? "Press keys…" : bridge.keyLabel(action), active: isCapturing(action, controller: false))
                                Button("Change…") { bridge.beginKeyCapture(action) }
                                Button("Clear") { bridge.clearKey(action) }.disabled(bridge.trigger(action).key == nil)
                            }
                            HStack {
                                badge(chordText(action), active: isCapturing(action, controller: true))
                                if isCapturing(action, controller: true) {
                                    Button("Cancel") { bridge.cancelCapture() }
                                } else {
                                    Button("Set combo…") { bridge.beginChordCapture(action) }
                                }
                                Button("Clear") { bridge.clearChord(action) }.disabled(bridge.trigger(action).chord.isEmpty)
                            }
                        }
                    }
                }.disabled(busy)
                HStack { Text(String(format: "Preview → paste delay: %.1f s", bridge.delay)); Slider(value: $bridge.delay, in: 0.1...3, step: 0.1) }
                Text(bridge.status).font(.caption).textSelection(.enabled)
                Text("These triggers are caught by this app, not by WoW. Keyboard combinations are taken before WoW sees them. Controller combinations are only observed, so WoW still gets the buttons: choose a combination WoW doesn't use (for example L1 + R1 + A). The addon handles channel and whisper target, and Enter also sends from the preview. Each transcript replaces the clipboard.").font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }

    private func isCapturing(_ action: BridgeAction, controller: Bool) -> Bool {
        bridge.captureAction == action && bridge.captureController == controller
    }

    private func chordText(_ action: BridgeAction) -> String {
        guard isCapturing(action, controller: true) else { return bridge.chordLabel(action) }
        return bridge.captureHeld.isEmpty ? "Hold buttons…" : bridge.captureHeld.joined(separator: " + ")
    }

    private func badge(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.body.monospaced())
            .padding(.horizontal, 8).padding(.vertical, 2)
            .frame(minWidth: 120, alignment: .leading)
            .background(active ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
