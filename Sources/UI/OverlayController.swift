import AppKit
import Combine
import SwiftUI

/// Owns the overlay panels, the interaction state machine, and all keyboard
/// routing. The single place where key events become interaction-model
/// inputs and model commands become side effects.
@MainActor
final class OverlayController: ObservableObject {

    // Mirrored interaction state for SwiftUI.
    @Published private(set) var mode: OverlayMode = .hidden
    // Prompt pill.
    @Published var draftText: String = ""
    // Management panel.
    @Published var selectedIndex: Int = 0
    @Published var confirmingArchiveID: UUID?
    // Conversation.
    @Published var openSessionID: UUID?
    @Published var composerText: String = ""
    @Published private(set) var composerTranscribing = false

    let store: SessionStore
    let coordinator: AgentCoordinator
    let transcriber: Transcriber

    /// Gate: returns false when onboarding is incomplete; the overlay then
    /// defers to the settings window.
    var canUseOverlay: () -> Bool = { true }
    var onRequestSettings: () -> Void = {}

    private var model = OverlayInteractionModel()
    private var pillPanel: OverlayPanel?
    private var managementPanel: OverlayPanel?
    private var conversationPanel: OverlayPanel?
    private var keyMonitor: Any?
    private var activeScreen: NSScreen?
    private var composerBaseText: String = ""
    private var cancellables: Set<AnyCancellable> = []

    init(store: SessionStore, coordinator: AgentCoordinator, transcriber: Transcriber) {
        self.store = store
        self.coordinator = coordinator
        self.transcriber = transcriber

        // Live-mirror transcription into the conversation composer.
        transcriber.$partialText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] partial in
                guard let self, self.composerTranscribing else { return }
                let joiner = self.composerBaseText.isEmpty || self.composerBaseText.hasSuffix(" ") || partial.isEmpty ? "" : " "
                self.composerText = self.composerBaseText + joiner + partial
            }
            .store(in: &cancellables)
    }

    // MARK: - Entry points

    func handleHotkey(_ hotkey: HotkeyManager.Hotkey) {
        guard canUseOverlay() else {
            onRequestSettings()
            return
        }
        switch hotkey {
        case .promptEntry: feed(.promptHotkey)
        case .management: feed(.managementHotkey)
        }
    }

    /// Open an agent conversation directly (e.g. from the menu bar).
    func openConversation(sessionID: UUID) {
        guard canUseOverlay() else { return }
        openSessionID = sessionID
        model.forceMode(.conversation)
        mode = .conversation
        syncPanels()
    }

    // MARK: - Interaction model plumbing

    private func feed(_ input: OverlayInput) {
        let commands = model.handle(input)
        mode = model.mode
        for command in commands { execute(command) }
        syncPanels()
    }

    private func execute(_ command: OverlayCommand) {
        switch command {
        case .showPromptPill:
            activeScreen = ScreenshotCapturer.screenUnderMouse()
            draftText = ""

        case .startTranscription:
            transcriber.start()

        case .stopTranscription:
            if case .conversation = mode {
                stopComposerTranscription()
            } else {
                let transcript = transcriber.stop()
                if draftText.isEmpty { draftText = transcript }
            }

        case .beginEditing(let seed):
            var text = draftText.isEmpty ? transcriber.partialText : draftText
            if transcriber.isActive { _ = transcriber.stop() }
            if let seed {
                if !text.isEmpty && !text.hasSuffix(" ") { text += " " }
                text.append(seed)
            }
            draftText = text

        case .submitPrompt:
            submitPrompt()

        case .hideOverlay:
            stopComposerTranscription()
            openSessionID = nil
            confirmingArchiveID = nil

        case .showManagement:
            clampSelection()

        case .selectPrevious:
            moveSelection(-1)

        case .selectNext:
            moveSelection(1)

        case .openSelected:
            if let session = selectedSession() {
                openSessionID = session.id
                composerText = ""
                composerBaseText = ""
            } else {
                model.forceMode(.management(confirmingArchive: false))
                mode = model.mode
            }

        case .beginArchiveConfirmation:
            if let session = selectedSession() {
                confirmingArchiveID = session.id
            } else {
                model.forceMode(.management(confirmingArchive: false))
                mode = model.mode
            }

        case .confirmArchive:
            if let id = confirmingArchiveID {
                coordinator.archive(sessionID: id)
                clampSelection()
            }
            confirmingArchiveID = nil

        case .cancelArchiveConfirmation:
            confirmingArchiveID = nil

        case .closeConversation:
            stopComposerTranscription()
            openSessionID = nil

        case .toggleComposerTranscription:
            if composerTranscribing {
                stopComposerTranscription()
            } else {
                composerBaseText = composerText
                composerTranscribing = true
                transcriber.start()
            }
        }
    }

    private func stopComposerTranscription() {
        guard composerTranscribing else {
            if transcriber.isActive { _ = transcriber.stop() }
            return
        }
        composerTranscribing = false
        let partial = transcriber.stop()
        let joiner = composerBaseText.isEmpty || composerBaseText.hasSuffix(" ") || partial.isEmpty ? "" : " "
        composerText = composerBaseText + joiner + partial
        composerBaseText = composerText
    }

    // MARK: - Prompt submission

    private func submitPrompt() {
        var prompt = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty {
            prompt = transcriber.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        draftText = ""
        guard !prompt.isEmpty else { return }
        let screen = activeScreen
        // Hide the overlay first so the screenshot shows the user's actual
        // workspace, not our pill.
        hideAllPanels()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            let screenshotPath = await ScreenshotCapturer.captureActiveDisplay(screen: screen)
            self.coordinator.startAgent(prompt: prompt, screenshotPath: screenshotPath)
        }
    }

    // MARK: - Selection

    private func panelSessions() -> [AgentSessionMeta] { store.panelSessions }

    private func selectedSession() -> AgentSessionMeta? {
        let sessions = panelSessions()
        guard !sessions.isEmpty else { return nil }
        return sessions[min(selectedIndex, sessions.count - 1)]
    }

    private func moveSelection(_ delta: Int) {
        let count = panelSessions().count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func clampSelection() {
        let count = panelSessions().count
        if count == 0 { selectedIndex = 0 } else { selectedIndex = min(selectedIndex, count - 1) }
    }

    // MARK: - Panels

    private func screenForOverlay() -> NSScreen {
        activeScreen ?? ScreenshotCapturer.screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func syncPanels() {
        switch mode {
        case .hidden:
            hideAllPanels()
            if transcriber.isActive && !composerTranscribing { _ = transcriber.stop() }

        case .promptEntry:
            let screen = screenForOverlay()
            presentManagementPanel(on: screen, focused: false)
            presentPillPanel(on: screen)
            installKeyMonitorIfNeeded()

        case .management:
            let screen = screenForOverlay()
            pillPanel?.dismiss()
            conversationPanel?.dismiss()
            presentManagementPanel(on: screen, focused: true)
            installKeyMonitorIfNeeded()

        case .conversation:
            let screen = screenForOverlay()
            pillPanel?.dismiss()
            managementPanel?.dismiss()
            presentConversationPanel(on: screen)
            installKeyMonitorIfNeeded()
        }
    }

    private func hideAllPanels() {
        pillPanel?.dismiss()
        managementPanel?.dismiss()
        conversationPanel?.dismiss()
        removeKeyMonitor()
    }

    private func presentPillPanel(on screen: NSScreen) {
        let size = NSSize(width: 640, height: 160)
        let panel = pillPanel ?? OverlayPanel(size: size)
        pillPanel = panel
        panel.setRootView(
            PromptPillView()
                .environmentObject(self)
                .environmentObject(transcriber)
        )
        let frame = NSRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 48,
            width: size.width, height: size.height
        )
        panel.present(on: screen, frame: frame)
    }

    private func presentManagementPanel(on screen: NSScreen, focused: Bool) {
        let size = NSSize(width: 340, height: 440)
        let panel = managementPanel ?? OverlayPanel(size: size)
        managementPanel = panel
        panel.setRootView(
            AgentPanelView()
                .environmentObject(self)
                .environmentObject(store)
        )
        let frame = NSRect(
            x: screen.visibleFrame.minX + 20,
            y: screen.visibleFrame.maxY - size.height - 20,
            width: size.width, height: size.height
        )
        if focused {
            panel.present(on: screen, frame: frame)
        } else {
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
    }

    private func presentConversationPanel(on screen: NSScreen) {
        let size = NSSize(width: 760, height: 620)
        let panel = conversationPanel ?? OverlayPanel(size: size)
        conversationPanel = panel
        panel.setRootView(
            ConversationView()
                .environmentObject(self)
                .environmentObject(store)
                .environmentObject(transcriber)
        )
        let frame = NSRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2 + 20,
            width: size.width, height: size.height
        )
        panel.present(on: screen, frame: frame)
    }

    // MARK: - Key routing

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.route(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private enum Key {
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let tab: UInt16 = 48
        static let delete: UInt16 = 51
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    /// Returns true when the event was consumed.
    private func route(_ event: NSEvent) -> Bool {
        switch mode {
        case .hidden:
            return false

        case .promptEntry(let transcribing):
            switch event.keyCode {
            case Key.escape: feed(.escape); return true
            case Key.returnKey: feed(.returnKey); return true
            case Key.tab: feed(.tab); return true
            case Key.delete where transcribing:
                feed(.promptHotkey) // stop transcription, begin editing without a seed
                return true
            default:
                if transcribing, let c = typedCharacter(event) {
                    feed(.character(c))
                    return true
                }
                if event.modifierFlags.contains(.command) {
                    return handleEditingCommand(event)
                }
                return false // editing: let the text field handle it

            }

        case .management:
            switch event.keyCode {
            case Key.escape: feed(.escape); return true
            case Key.up: feed(.navUp); return true
            case Key.down: feed(.navDown); return true
            case Key.right, Key.returnKey: feed(.navOpen); return true
            case Key.left: feed(.navArchive); return true
            default:
                if let c = typedCharacter(event) { feed(.character(c)) }
                return true // swallow everything else; the panel has no text input

            }

        case .conversation:
            if event.keyCode == Key.escape { feed(.escape); return true }
            if event.modifierFlags.contains(.command) {
                let c = event.charactersIgnoringModifiers?.lowercased()
                if c == "y" || c == "n", let sessionID = openSessionID,
                   let request = coordinator.pendingPermissions(for: sessionID).first {
                    coordinator.respondToPermission(sessionID: sessionID, requestID: request.id, allow: c == "y")
                    return true
                }
                return handleEditingCommand(event)
            }
            if event.keyCode == Key.returnKey && !event.modifierFlags.contains(.shift) {
                sendComposerMessage()
                return true
            }
            return false // typing flows into the composer

        }
    }

    /// An LSUIElement app has no Edit menu, so the standard edit shortcuts
    /// have no menu item to land on — dispatch them to the field editor.
    private func handleEditingCommand(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        let selector: Selector?
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": selector = #selector(NSText.paste(_:))
        case "c": selector = #selector(NSText.copy(_:))
        case "x": selector = #selector(NSText.cut(_:))
        case "a": selector = #selector(NSText.selectAll(_:))
        default: selector = nil
        }
        guard let selector else { return false }
        return NSApp.sendAction(selector, to: nil, from: self)
    }

    private func typedCharacter(_ event: NSEvent) -> Character? {
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
              let characters = event.charactersIgnoringModifiers, let first = characters.first,
              !first.isNewline, first != "\t", first.asciiValue != 27
        else { return nil }
        // Ignore pure control/function characters (arrows arrive as private-use).
        if let scalar = first.unicodeScalars.first,
           scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
            return nil
        }
        return first
    }

    func sendComposerMessage() {
        stopComposerTranscription()
        guard let sessionID = openSessionID else { return }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composerText = ""
        composerBaseText = ""
        coordinator.send(text: text, to: sessionID)
    }
}
