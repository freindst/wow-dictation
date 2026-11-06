import SwiftUI
import AppKit
import GameController
import ApplicationServices
import Carbon.HIToolbox

/// A keyboard shortcut registered as a system-wide hot key.
struct KeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var name: String
}

enum BridgeAction: String, CaseIterable, Identifiable {
    case record, send
    var id: String { rawValue }
    var title: String { self == .record ? "Record / Stop" : "Send" }
}

/// Triggers for one action: a keyboard combination and/or a controller button combination.
struct ActionTriggers: Codable, Equatable {
    var key: KeyShortcut?
    var chord: [String] = []
}

/// The helper owns the Record and Send triggers. The WoW addon cannot call this app,
/// so the helper watches the keyboard/controller directly, records and transcribes,
/// then drives the addon with Control-Shift-F13…F17 and Command-V.
@MainActor final class ControllerBridge: ObservableObject {
    @Published var enabled = false {
        didSet {
            if !enabled { delivery?.cancel(); delivery = nil; phase = "idle" }
            updateHotKeys()
        }
    }
    @Published private(set) var triggers: [BridgeAction: ActionTriggers] = [:]
    @Published var delay: Double = 1 { didSet { UserDefaults.standard.set(delay, forKey: "pasteDelay") } }
    @Published var controllerName = "No controller detected"
    @Published var lastInput = "No button pressed yet"
    @Published var status = "Enable the bridge after preparing the English model."
    @Published var phase = "idle"
    /// Which action is being captured, and whether from the keyboard or the controller.
    @Published private(set) var captureAction: BridgeAction?
    @Published private(set) var captureController = false
    @Published private(set) var captureHeld: [String] = []
    /// Record / Stop keys set in the addon's Hotkeys panel (read from its saved file).
    @Published private(set) var inGame: InGameBindings?
    @Published private(set) var inGameTriggers: [WoWTrigger] = []
    @Published private(set) var inGameUnsupported: [String] = []
    private var inGameTimer: Timer?
    private var keyMonitor: Any?

    weak var speech: LocalSpeech?
    private var observers: [NSObjectProtocol] = []
    private var delivery: Task<Void, Never>?
    private var lastPress: Double = 0
    private var hookedButtons: [GCControllerButtonInput] = []
    private var held = Set<String>()
    private var captureSet = Set<String>()
    private var captureMonitor: Any?
    private let hotKeys: [BridgeAction: GlobalHotKey] = [.record: GlobalHotKey(id: 1), .send: GlobalHotKey(id: 2)]

    /// Controller buttons in display order.
    let buttonNames = ["L1", "R1", "L2", "R2", "L3", "R3", "A / Cross", "B / Circle", "X / Square", "Y / Triangle",
                       "D-pad Up", "D-pad Down", "D-pad Left", "D-pad Right", "Options", "Menu"]
    private static let storageKey = "bridgeTriggers.v2"
    private static let reservedKeyCodes: Set<UInt16> = [105, 107, 113, 106, 64] // F13…F17

    init() {
        if UserDefaults.standard.object(forKey: "pasteDelay") != nil { delay = min(3, max(0.1, UserDefaults.standard.double(forKey: "pasteDelay"))) }
        loadTriggers()
        GCController.shouldMonitorBackgroundEvents = true
        for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        }
        refresh()
        reloadInGameBindings()
        inGameTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadInGameBindings() }
        }
        // Passive watch for the in-game Record key: WoW also receives it (its binding does nothing).
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode, flags = event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue
            let isRepeat = event.isARepeat
            Task { @MainActor in self?.globalKey(code: code, flags: flags, isRepeat: isRepeat) }
        }
    }

    // MARK: In-game bindings (from the addon)

    func reloadInGameBindings() {
        guard let (url, date) = InGameBindingReader.newestFile() else {
            if inGame != nil { inGame = nil; inGameTriggers = []; inGameUnsupported = [] }
            return
        }
        if let inGame, inGame.file == url.path, inGame.modified == date { return }
        guard let bindings = InGameBindingReader.read(url, modified: date) else { return }
        inGame = bindings
        inGameTriggers = bindings.recordKeys.compactMap { InGameBindingReader.trigger($0, in: bindings) }
        inGameUnsupported = bindings.recordKeys.filter { InGameBindingReader.trigger($0, in: bindings) == nil }
    }

    var inGameLabel: String {
        guard let inGame else { return "Addon settings not found yet — log in with the addon enabled." }
        if inGame.recordKeys.isEmpty { return "Not set — bind Record / Stop in the addon's Hotkeys, then /reload." }
        var text = inGame.recordKeys.joined(separator: " or ")
        for trigger in inGameTriggers {
            if case let .gamepad(chord, name) = trigger { text = text.replacingOccurrences(of: name, with: "\(name) (\(chord.joined(separator: " + ")))") }
        }
        if !inGameUnsupported.isEmpty { text += " · not usable: " + inGameUnsupported.joined(separator: ", ") }
        return text
    }

    private func globalKey(code: UInt16, flags: NSEvent.ModifierFlags.RawValue, isRepeat: Bool) {
        guard !isRepeat, captureAction == nil else { return }
        for trigger in inGameTriggers {
            if case let .keyboard(keyCode, wantFlags, name) = trigger, keyCode == code, wantFlags == flags {
                lastInput = "In-game key \(name)"
                if enabled { fire(.record) }
                return
            }
        }
    }

    // MARK: Trigger storage

    private func loadTriggers() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: ActionTriggers].self, from: data) {
            for action in BridgeAction.allCases { triggers[action] = saved[action.rawValue] ?? ActionTriggers() }
            return
        }
        // First launch (or upgrade): keyboard defaults, plus any controller buttons chosen in older versions.
        var record = ActionTriggers(key: KeyShortcut(keyCode: 15, modifiers: UInt32(controlKey | optionKey), name: "⌃⌥R"))
        var send = ActionTriggers(key: KeyShortcut(keyCode: 1, modifiers: UInt32(controlKey | optionKey), name: "⌃⌥S"))
        if let old = defaults.string(forKey: "recordButton"), buttonNames.contains(old) { record.chord = [old] }
        if let old = defaults.string(forKey: "sendButton"), buttonNames.contains(old), old != record.chord.first { send.chord = [old] }
        triggers = [.record: record, .send: send]
        saveTriggers()
    }

    private func saveTriggers() {
        var out: [String: ActionTriggers] = [:]
        for (action, value) in triggers { out[action.rawValue] = value }
        if let data = try? JSONEncoder().encode(out) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }

    func trigger(_ action: BridgeAction) -> ActionTriggers { triggers[action] ?? ActionTriggers() }

    func keyLabel(_ action: BridgeAction) -> String { trigger(action).key?.name ?? "None" }

    func chordLabel(_ action: BridgeAction) -> String {
        let chord = trigger(action).chord
        return chord.isEmpty ? "None" : chord.joined(separator: " + ")
    }

    /// Human description used in status messages, e.g. "⌃⌥R or L1 + R1".
    func describe(_ action: BridgeAction) -> String {
        let t = trigger(action)
        var parts: [String] = action == .record ? (inGame?.recordKeys ?? []) : []
        if let key = t.key { parts.append(key.name) }
        if !t.chord.isEmpty { parts.append(chordLabel(action)) }
        return parts.isEmpty ? "(no \(action.title) trigger set)" : parts.joined(separator: " or ")
    }

    private func other(_ action: BridgeAction) -> BridgeAction { action == .record ? .send : .record }

    // MARK: Keyboard hot keys

    private func updateHotKeys() {
        for action in BridgeAction.allCases {
            guard let hotKey = hotKeys[action] else { continue }
            if enabled, captureAction == nil, let key = trigger(action).key {
                let ok = hotKey.register(keyCode: key.keyCode, carbonModifiers: key.modifiers) { [weak self] in
                    Task { @MainActor in self?.keyboardPressed(action) }
                }
                if !ok { status = "Could not register \(key.name) for \(action.title); another app may use it. Choose a different combination." }
            } else {
                hotKey.unregister()
            }
        }
    }

    private func keyboardPressed(_ action: BridgeAction) {
        lastInput = "Keyboard \(keyLabel(action))"
        guard enabled else { return }
        fire(action)
    }

    // MARK: Capture (keyboard and controller)

    func beginKeyCapture(_ action: BridgeAction) {
        cancelCapture()
        captureAction = action; captureController = false
        updateHotKeys() // release hot keys so the new combination reaches this window
        status = "Press the new keyboard combination for \(action.title) (Esc cancels)."
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.handleKeyCapture(event)
            return nil
        }
    }

    private func handleKeyCapture(_ event: NSEvent) {
        guard let action = captureAction else { return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 && flags.isEmpty { cancelCapture(); status = "\(action.title) key unchanged."; return }
        if flags.isEmpty && GlobalHotKey.functionKeys[event.keyCode] == nil {
            status = "Add Control, Option or Command (or use an F-key): a plain key would stop that key typing in every app."
            return
        }
        if Self.reservedKeyCodes.contains(event.keyCode) && flags == [.control, .shift] {
            status = "Control-Shift-F13…F17 are reserved for the addon bridge. Choose another combination."
            return
        }
        let shortcut = KeyShortcut(keyCode: UInt32(event.keyCode), modifiers: GlobalHotKey.carbonModifiers(flags),
                                   name: GlobalHotKey.displayName(keyCode: event.keyCode, flags: flags, characters: event.charactersIgnoringModifiers))
        if let otherKey = trigger(other(action)).key, otherKey.keyCode == shortcut.keyCode, otherKey.modifiers == shortcut.modifiers {
            status = "\(shortcut.name) is already used for \(other(action).title). Choose a different combination."
            return
        }
        triggers[action, default: ActionTriggers()].key = shortcut
        saveTriggers()
        endCapture()
        status = "\(action.title) keyboard combination set to \(shortcut.name)."
    }

    func beginChordCapture(_ action: BridgeAction) {
        cancelCapture()
        captureAction = action; captureController = true
        captureSet.removeAll(); captureHeld = []
        updateHotKeys()
        status = held.isEmpty
            ? "Hold the controller buttons for \(action.title) together, then release them all."
            : "Release all controller buttons first, then hold the new combination."
    }

    private func finishChordCapture() {
        guard let action = captureAction else { return }
        let chord = buttonNames.filter { captureSet.contains($0) }
        captureSet.removeAll(); captureHeld = []
        if Set(chord) == Set(trigger(other(action)).chord) {
            status = "That combination is already used for \(other(action).title). Hold a different one."
            return // stay in capture mode
        }
        triggers[action, default: ActionTriggers()].chord = chord
        saveTriggers()
        endCapture()
        status = chord.count == 1
            ? "\(action.title) set to \(chord[0]). A single button also runs its normal WoW action; a combination is safer."
            : "\(action.title) controller combination set to \(chordLabel(action))."
    }

    func clearKey(_ action: BridgeAction) {
        cancelCapture()
        triggers[action, default: ActionTriggers()].key = nil
        saveTriggers(); updateHotKeys()
        status = "\(action.title) keyboard combination removed."
    }

    func clearChord(_ action: BridgeAction) {
        cancelCapture()
        triggers[action, default: ActionTriggers()].chord = []
        saveTriggers()
        status = "\(action.title) controller combination removed."
    }

    func cancelCapture() {
        guard captureAction != nil else { return }
        endCapture()
    }

    private func endCapture() {
        if let captureMonitor { NSEvent.removeMonitor(captureMonitor) }
        captureMonitor = nil
        captureAction = nil; captureController = false
        captureSet.removeAll(); captureHeld = []
        updateHotKeys()
    }

    // MARK: Controller input

    func refresh() {
        for button in hookedButtons { button.pressedChangedHandler = nil }
        hookedButtons.removeAll()
        held.removeAll()
        let controllers = GCController.controllers()
        controllerName = controllers.isEmpty ? "No controller detected — connect via Bluetooth or USB" : controllers.map { $0.vendorName ?? "Controller" }.joined(separator: ", ")
        for controller in controllers {
            guard let pad = controller.extendedGamepad else { continue }
            let bindings: [(String, GCControllerButtonInput?)] = [
                ("L1", pad.leftShoulder), ("R1", pad.rightShoulder), ("L2", pad.leftTrigger), ("R2", pad.rightTrigger),
                ("L3", pad.leftThumbstickButton), ("R3", pad.rightThumbstickButton),
                ("A / Cross", pad.buttonA), ("B / Circle", pad.buttonB), ("X / Square", pad.buttonX), ("Y / Triangle", pad.buttonY),
                ("D-pad Up", pad.dpad.up), ("D-pad Down", pad.dpad.down), ("D-pad Left", pad.dpad.left), ("D-pad Right", pad.dpad.right),
                ("Options", pad.buttonOptions), ("Menu", pad.buttonMenu)
            ]
            for (name, button) in bindings {
                guard let button else { continue }
                hookedButtons.append(button)
                button.pressedChangedHandler = { [weak self] _, _, pressed in
                    Task { @MainActor in self?.button(name, pressed: pressed) }
                }
            }
        }
    }

    private func button(_ name: String, pressed: Bool) {
        if pressed { held.insert(name) } else { held.remove(name) }
        let current = buttonNames.filter { held.contains($0) }
        lastInput = current.isEmpty ? "\(name) released" : current.joined(separator: " + ")

        if captureAction != nil && captureController {
            if pressed { captureSet.insert(name); captureHeld = buttonNames.filter { captureSet.contains($0) } }
            else if held.isEmpty && !captureSet.isEmpty { finishChordCapture() }
            return
        }
        guard pressed, enabled, captureAction == nil else { return }
        // Fire the action whose combination was just completed by this press.
        // If both match (one combination contains the other), the longer one wins.
        var candidates: [(BridgeAction, [String])] = BridgeAction.allCases.map { ($0, trigger($0).chord) }
        for t in inGameTriggers { if case let .gamepad(chord, _) = t { candidates.append((.record, chord)) } }
        let matches = candidates.filter { !$0.1.isEmpty && $0.1.contains(name) && Set($0.1).isSubset(of: held) }
        if let best = matches.max(by: { $0.1.count < $1.1.count }) { fire(best.0) }
    }

    // MARK: Actions

    var wowFrontmost: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let name = app.localizedName?.lowercased() ?? ""
        let id = app.bundleIdentifier?.lowercased() ?? ""
        return name == "wow" || name.contains("world of warcraft") || id.hasPrefix("com.blizzard.worldofwarcraft")
    }
    var trusted: Bool { AXIsProcessTrusted() }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        status = trusted ? "Accessibility allowed." : "Allow Controller Speech in System Settings → Privacy & Security → Accessibility."
    }
    func attach(_ speech: LocalSpeech) {
        self.speech = speech
        speech.recordingStarted = { [weak self] in self?.recordingStarted() }
        speech.recordingStopped = { [weak self] in self?.recordingStopped() }
        speech.completed = { [weak self] text in self?.receive(text) }
        speech.failed = { [weak self] in self?.failed() }
    }
    func notify(_ key: CGKeyCode) -> Bool {
        guard wowFrontmost, trusted else { return false }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return false }
        down.flags = [.maskControl, .maskShift]; up.flags = [.maskControl, .maskShift]
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }

    private func fire(_ action: BridgeAction) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPress > 0.25 else { return }; lastPress = now
        guard wowFrontmost else { status = "Ignored \(action.title): WoW must be in front."; return }
        guard trusted else {
            status = "Accessibility permission is missing. In System Settings → Privacy & Security → Accessibility, remove Controller Speech (−) and add it again (+). Each rebuild of the app resets this."
            return
        }
        guard let speech else { return }
        switch action {
        case .record:
            if speech.recording { speech.stop() }
            else if speech.busy { status = "Transcription is still running; wait for the preview." }
            else if !speech.ready {
                status = "Loading the English model, then recording…"
                Task {
                    await speech.prepare()
                    if speech.ready { await speech.start() } else { self.status = "English model is not ready: \(speech.status)" }
                }
            }
            else {
                delivery?.cancel(); delivery = nil
                Task { await speech.start() }
            }
        case .send:
            if phase == "recording" || phase == "processing" || phase == "delivering" {
                status = "Nothing ready to send yet. Wait for the preview."; return
            }
            // The addon validates the draft and destination itself, so a typed message can be sent too.
            if notify(106) { phase = "idle"; status = "Send delivered to the addon. Check the game's result." }
        }
    }
    func recordingStarted() {
        guard enabled else { return }
        delivery?.cancel(); phase = "recording"
        if notify(105) { status = "Recording — press \(describe(.record)) again to stop." }
        else { status = "Recording locally; addon notification failed. Keep WoW in front and check Accessibility." }
    }
    func recordingStopped() {
        guard enabled else { return }
        phase = "processing"; _ = notify(107); status = "Transcribing locally…"
    }
    func receive(_ text: String) {
        guard enabled else { return }
        guard !text.isEmpty else { failed(); status = "No speech recognized; retry."; return }
        phase = "delivering"
        delivery = Task { [weak self] in
            guard let self else { return }
            guard self.notify(113) else { self.phase = "idle"; self.status = "Text is ready in the helper. Delivery stopped because WoW is not focused or Accessibility is denied."; return }
            self.status = String(format: "Opening addon preview; pasting in %.1f s…", self.delay)
            do { try await Task.sleep(for: .seconds(self.delay)) } catch { return }
            guard !Task.isCancelled, self.enabled, self.wowFrontmost, self.trusted else { self.phase = "idle"; self.status = "Paste cancelled: keep WoW in front."; return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { self.phase = "idle"; return }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            self.phase = "preview"; self.status = "Paste issued. Review in WoW; press \(self.describe(.send)) to send."
        }
    }
    func failed() { guard enabled else { return }; delivery?.cancel(); phase = "idle"; _ = notify(64); status = "Recording/transcription cancelled or failed; press Record to retry." }
    func shutdown() {
        enabled = false
        inGameTimer?.invalidate(); inGameTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        cancelCapture()
        for hotKey in hotKeys.values { hotKey.unregister() }
        delivery?.cancel(); delivery = nil
        for button in hookedButtons { button.pressedChangedHandler = nil }
        hookedButtons.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        GCController.shouldMonitorBackgroundEvents = false
        speech?.recordingStarted = nil
        speech?.recordingStopped = nil
        speech?.completed = nil
        speech?.failed = nil
        speech = nil
    }
}
