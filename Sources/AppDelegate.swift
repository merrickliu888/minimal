import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let store = SessionStore()
    let permissions = PermissionsManager()
    let codexProvider = CodexProvider()
    let claudeCodeProvider = ClaudeCodeProvider()
    let transcriber = Transcriber()
    lazy var providers: [AgentProvider] = [codexProvider, claudeCodeProvider]
    lazy var coordinator = AgentCoordinator(store: store, providers: providers)
    lazy var settingsModel = SettingsModel(providers: providers)
    lazy var minimalController = MinimalController(
        store: store, coordinator: coordinator, transcriber: transcriber
    )

    private let hotkeys = HotkeyManager()
    private var settingsWindow: NSWindow?
    private var providerConnected = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        permissions.refresh()

        minimalController.canUseMinimal = { [weak self] in
            guard let self else { return false }
            return self.permissions.allGranted && self.providerConnected
        }
        minimalController.onRequestSettings = { [weak self] in
            self?.showSettingsWindow()
        }

        hotkeys.onHotkey = { [weak self] hotkey in
            self?.minimalController.handleHotkey(hotkey)
        }
        hotkeys.start()

        Task { @MainActor in
            await settingsModel.checkAll()
            providerConnected = settingsModel.hasConnectedProvider
            if !permissions.allGranted || !providerConnected {
                showSettingsWindow()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.terminateAll()
        hotkeys.stop()
    }

    // MARK: - Settings window

    func showSettingsWindow() {
        if settingsWindow == nil {
            let view = SettingsView(settingsModel: settingsModel)
                .environmentObject(permissions)
            let hosting = NSHostingController(rootView: view)
            // Don't let SwiftUI size the window via constraints: the content
            // height changes as checks complete, and the resulting layout
            // feedback loop trips AppKit's constraint-pass limit (crash).
            hosting.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 540, height: 640))
            window.title = "Minimal"
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    NSApp.setActivationPolicy(.accessory)
                    // Re-evaluate the gate as the user leaves setup.
                    if let self {
                        await self.settingsModel.checkAll()
                        self.providerConnected = self.settingsModel.hasConnectedProvider
                    }
                }
            }
        }
        // LSUIElement app: give the settings window a real presence.
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Track connection state as checks complete while the window is open.
        Task { @MainActor in
            await settingsModel.checkAll()
            providerConnected = settingsModel.hasConnectedProvider
        }
    }
}
