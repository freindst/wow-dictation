import SwiftUI
import AppKit
import GameController
import ApplicationServices

@MainActor final class ControllerBridge: ObservableObject {
    @Published var enabled = false { didSet { if !enabled { delivery?.cancel(); delivery = nil; phase = "idle" } } }
    @Published var recordButton = "L3" { didSet { UserDefaults.standard.set(recordButton, forKey: "recordButton") } }
    @Published var sendButton = "R3" { didSet { UserDefaults.standard.set(sendButton, forKey: "sendButton") } }
    @Published var delay: Double = 1 { didSet { UserDefaults.standard.set(delay, forKey: "pasteDelay") } }
    @Published var controllerName = "No controller detected"
    @Published var lastInput = "No button pressed yet"
    @Published var status = "Enable controller bridge after preparing the English model."
    @Published var phase = "idle"
    weak var speech: LocalSpeech?
    private var observers: [NSObjectProtocol] = []
    private var delivery: Task<Void, Never>?
    private var lastPress: Double = 0
    private var hookedButtons: [GCControllerButtonInput] = []
    let choices = ["L3", "R3", "Options", "Menu", "Left Shoulder", "Right Shoulder", "A / Cross", "B / Circle", "X / Square", "Y / Triangle", "D-pad Up", "D-pad Down", "D-pad Left", "D-pad Right"]
    init() {
        recordButton = UserDefaults.standard.string(forKey: "recordButton") ?? "L3"
        sendButton = UserDefaults.standard.string(forKey: "sendButton") ?? "R3"
        if UserDefaults.standard.object(forKey: "pasteDelay") != nil { delay = min(3, max(0.1, UserDefaults.standard.double(forKey: "pasteDelay"))) }
        GCController.shouldMonitorBackgroundEvents = true
        for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        }
        refresh()
    }
    func attach(_ speech: LocalSpeech) {
        self.speech = speech
        speech.recordingStarted = { [weak self] in self?.recordingStarted() }
        speech.recordingStopped = { [weak self] in self?.recordingStopped() }
        speech.completed = { [weak self] text in self?.receive(text) }
        speech.failed = { [weak self] in self?.failed() }
    }
    func refresh() {
        for button in hookedButtons { button.pressedChangedHandler = nil }
        hookedButtons.removeAll()
        let controllers = GCController.controllers()
        controllerName = controllers.isEmpty ? "No controller detected — connect via Bluetooth or USB" : controllers.map { $0.vendorName ?? "Controller" }.joined(separator: ", ")
        for controller in controllers {
            guard let pad = controller.extendedGamepad else { continue }
            let bindings: [(String, GCControllerButtonInput?)] = [
                ("L3", pad.leftThumbstickButton), ("R3", pad.rightThumbstickButton),
                ("Options", pad.buttonOptions), ("Menu", pad.buttonMenu),
                ("Left Shoulder", pad.leftShoulder), ("Right Shoulder", pad.rightShoulder),
                ("A / Cross", pad.buttonA), ("B / Circle", pad.buttonB), ("X / Square", pad.buttonX), ("Y / Triangle", pad.buttonY),
                ("D-pad Up", pad.dpad.up), ("D-pad Down", pad.dpad.down), ("D-pad Left", pad.dpad.left), ("D-pad Right", pad.dpad.right)
            ]
            for (name, button) in bindings {
                if let button { hookedButtons.append(button) }
                button?.pressedChangedHandler = { [weak self] _, _, pressed in
                    guard pressed else { return }
                    Task { @MainActor in self?.pressed(name) }
                }
            }
        }
    }
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
    func notify(_ key: CGKeyCode) -> Bool {
        guard wowFrontmost, trusted else { return false }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return false }
        down.flags = [.maskControl, .maskShift]; up.flags = [.maskControl, .maskShift]
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }
    func pressed(_ name: String) {
        lastInput = name
        guard enabled else { return }
        guard recordButton != sendButton else { status = "Choose different Record and Send buttons."; return }
        guard name == recordButton || name == sendButton else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPress > 0.25 else { return }; lastPress = now
        guard wowFrontmost else { status = "Ignored controller action: WoW must be in front."; return }
        guard trusted else { status = "Accessibility permission is needed for the addon bridge."; return }
        guard let speech else { return }
        if name == recordButton {
            if speech.recording { speech.stop() }
            else if speech.busy { status = "Transcription is still running; wait for the preview." }
            else if !speech.ready { status = "Prepare the English model first." }
            else {
                delivery?.cancel(); delivery = nil
                Task { await speech.start() }
            }
        } else {
            guard phase == "preview" else { status = "Nothing ready to send. Wait for the preview."; return }
            if notify(106) { phase = "idle"; status = "Send key delivered to addon. Check the game's result." }
        }
    }
    func recordingStarted() {
        guard enabled else { return }
        delivery?.cancel(); phase = "recording"
        if notify(105) { status = "Recording — press \(recordButton) again to stop." }
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
            self.phase = "preview"; self.status = "Paste issued. Review in WoW; press \(self.sendButton) to submit."
        }
    }
    func failed() { guard enabled else { return }; delivery?.cancel(); phase = "idle"; _ = notify(64); status = "Recording/transcription cancelled or failed; press Record to retry." }
    func shutdown() {
        enabled = false
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
