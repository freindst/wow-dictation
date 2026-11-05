import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var onShutdown: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        onShutdown?()
        onShutdown = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main struct ControllerSpeechApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var speech = LocalSpeech()
    @StateObject private var bridge = ControllerBridge()

    var body: some Scene {
        Window("Controller Speech", id: "main") {
            ContentView(b: speech, bridge: bridge)
                .onAppear {
                    delegate.onShutdown = {
                        bridge.shutdown()
                        speech.shutdown()
                    }
                }
        }
        .defaultSize(width: 940, height: 860)
    }
}
