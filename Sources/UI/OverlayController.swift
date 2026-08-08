import AppKit
import Combine
import SwiftTerm
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
    /// Directory the next agent will work in; nil = Settings default.
    /// Persisted so the choice survives overlay toggles and app restarts.
    @Published var draftWorkingDirectory: String? {
        didSet {
            UserDefaults.standard.set(draftWorkingDirectory, forKey: Self.pickedDirectoryKey)
        }
    }
    private static let pickedDirectoryKey = "agentPickedWorkingDirectory"
    /// Model alias for the next agent; nil = CLI default. Persisted.
    @Published var draftModel: String? {
        didSet { UserDefaults.standard.set(draftModel, forKey: Self.pickedModelKey) }
    }
    private static let pickedModelKey = "agentPickedModel"
    // Management panel.
    @Published var selectedIndex: Int = 0
    @Published var confirmingArchiveID: UUID?
    // Conversation.
    @Published var openSessionID: UUID?
    @Published var composerText: String = ""
    @Published private(set) var composerTranscribing = false
    /// Git branch of the open session's working directory (nil = not a repo).
    @Published private(set) var sessionBranch: String?
    private var branchTimer: Timer?
    // Terminal pane (Ctrl+`).
    @Published private(set) var terminalVisible = false
    @Published private(set) var activeTerminal: LocalProcessTerminalView?
    private let terminalPaneWidth: CGFloat = 440 // pane 424 + HStack spacing 16

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
    /// Draft text present when pill transcription started; partials append
    /// to this instead of replacing typed text.
    private var pillBaseText: String = ""
    private var cancellables: Set<AnyCancellable> = []

    init(store: SessionStore, coordinator: AgentCoordinator, transcriber: Transcriber) {
        self.store = store
        self.coordinator = coordinator
        self.transcriber = transcriber
        // Restore the last-picked directory, dropping it if it vanished.
        if let saved = UserDefaults.standard.string(forKey: Self.pickedDirectoryKey) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: saved, isDirectory: &isDirectory), isDirectory.boolValue {
                draftWorkingDirectory = saved
            }
        }
        if let savedModel = UserDefaults.standard.string(forKey: Self.pickedModelKey),
           ClaudeCodeLauncher.modelOptions.contains(savedModel) {
            draftModel = savedModel
        }

        // Live-mirror transcription into whichever field is listening.
        transcriber.$partialText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] partial in
                guard let self else { return }
                if self.composerTranscribing {
                    self.composerText = Self.joined(self.composerBaseText, partial)
                } else if case .promptEntry(transcribing: true) = self.mode {
                    self.draftText = Self.joined(self.pillBaseText, partial)
                }
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
            activeScreen = Self.screenUnderMouse()
            // The draft intentionally survives overlay toggles; it's only
            // cleared when a prompt is submitted.

        case .startTranscription:
            // Voice appends to whatever is already typed.
            pillBaseText = draftText
            transcriber.start()

        case .stopTranscription:
            if case .conversation = mode {
                stopComposerTranscription()
            } else {
                let transcript = transcriber.stop()
                draftText = Self.joined(pillBaseText, transcript)
            }

        case .beginEditing(let seed):
            if transcriber.isActive {
                let transcript = transcriber.stop()
                draftText = Self.joined(pillBaseText, transcript)
            }
            if let seed {
                if !draftText.isEmpty && !draftText.hasSuffix(" ") { draftText += " " }
                draftText.append(seed)
            }
            pillPanel?.focusFirstTextInput()

        case .submitPrompt:
            submitPrompt()

        case .hideOverlay:
            stopComposerTranscription()
            collapseTerminal()
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
                terminalVisible = false
                activeTerminal = nil
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
                TerminalCache.shared.terminate(sessionID: id)
                clampSelection()
            }
            confirmingArchiveID = nil

        case .cancelArchiveConfirmation:
            confirmingArchiveID = nil

        case .closeConversation:
            stopComposerTranscription()
            collapseTerminal()
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

    // MARK: - Terminal pane

    /// Ctrl+`: show/hide a shell terminal beside the conversation, scoped to
    /// the agent's working directory. The window widens to make room.
    private func toggleTerminal() {
        guard case .conversation = mode,
              let panel = conversationPanel,
              let sessionID = openSessionID,
              let meta = store.session(id: sessionID)
        else { return }

        var frame = panel.frame
        if terminalVisible {
            terminalVisible = false
            frame.size.width -= terminalPaneWidth
            panel.setFrame(frame, display: true)
            panel.focusFirstTextInput()
        } else {
            let terminal = TerminalCache.shared.view(for: sessionID, workingDirectory: meta.workingDirectory)
            activeTerminal = terminal
            terminalVisible = true
            frame.size.width += terminalPaneWidth
            if let screen = panel.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                if frame.maxX > visible.maxX {
                    frame.origin.x = max(visible.minX, visible.maxX - frame.width)
                }
            }
            panel.setFrame(frame, display: true)
            // Focus once SwiftUI has mounted the pane.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak panel, weak terminal] in
                guard let panel, let terminal else { return }
                panel.makeFirstResponder(terminal)
            }
        }
    }

    /// Shrink the window back before hiding so the autosaved frame (and next
    /// open) never includes the terminal pane's width.
    private func collapseTerminal() {
        if terminalVisible, let panel = conversationPanel {
            var frame = panel.frame
            frame.size.width -= terminalPaneWidth
            panel.setFrame(frame, display: false)
        }
        terminalVisible = false
    }

    private static func joined(_ base: String, _ addition: String) -> String {
        if base.isEmpty || addition.isEmpty || base.hasSuffix(" ") { return base + addition }
        return base + " " + addition
    }

    private func stopComposerTranscription() {
        guard composerTranscribing else {
            if transcriber.isActive { _ = transcriber.stop() }
            return
        }
        composerTranscribing = false
        let partial = transcriber.stop()
        composerText = Self.joined(composerBaseText, partial)
        composerBaseText = composerText
    }

    // MARK: - Prompt submission

    private func submitPrompt() {
        var prompt = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty {
            prompt = transcriber.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        draftText = ""
        guard !prompt.isEmpty else {
            // Nothing to submit: close the overlay instead of opening an
            // empty conversation.
            model.forceMode(.hidden)
            mode = .hidden
            return
        }
        openSessionID = coordinator.startAgent(
            prompt: prompt, workingDirectory: draftWorkingDirectory, model: draftModel
        )
        composerText = ""
        composerBaseText = ""
    }

    /// Display string for the pill's model indicator.
    var pillModelDisplay: String {
        draftModel ?? "default"
    }

    /// ⌘M in the pill: cycle through the model options.
    private func cycleModel() {
        let options = ClaudeCodeLauncher.modelOptions
        let currentIndex = options.firstIndex(of: draftModel) ?? 0
        draftModel = options[(currentIndex + 1) % options.count]
    }

    /// ⌘M in the conversation: switch the open session's model live. Cycles
    /// concrete aliases only — a live session can't return to "CLI default".
    private func cycleSessionModel() {
        guard let sessionID = openSessionID, let meta = store.session(id: sessionID) else { return }
        let options = ClaudeCodeLauncher.modelOptions.compactMap { $0 }
        let next: String
        if let current = meta.model, let index = options.firstIndex(of: current) {
            next = options[(index + 1) % options.count]
        } else {
            next = options[0]
        }
        coordinator.setModel(next, for: sessionID)
    }

    /// Display string for the pill: the directory the next agent will use.
    var pillWorkingDirectoryDisplay: String {
        ((draftWorkingDirectory ?? coordinator.defaultWorkingDirectory) as NSString).abbreviatingWithTildeInPath
    }

    /// ⌘P: pick the directory the agent is scoped to. Uses the system open
    /// panel (keyboard-navigable; ⌘⇧G accepts a typed path).
    private func pickWorkingDirectory() {
        let pillWasVisible = pillPanel?.isVisible ?? false
        let managementWasVisible = managementPanel?.isVisible ?? false
        // Order out (not dismiss) so the pill's state/hierarchy survives.
        pillPanel?.orderOut(nil)
        managementPanel?.orderOut(nil)

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose the directory this agent will work in"
        panel.prompt = "Use Directory"
        panel.directoryURL = URL(
            fileURLWithPath: draftWorkingDirectory ?? coordinator.defaultWorkingDirectory,
            isDirectory: true
        )
        if panel.runModal() == .OK, let url = panel.url {
            draftWorkingDirectory = url.path
        }
        NSApp.deactivate()

        if case .promptEntry = mode {
            if managementWasVisible { managementPanel?.orderFrontRegardless() }
            if pillWasVisible {
                pillPanel?.orderFrontRegardless()
                pillPanel?.makeKey()
                pillPanel?.focusFirstTextInput()
            }
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

    /// The screen the user is working on — where the mouse pointer is.
    static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func screenForOverlay() -> NSScreen {
        activeScreen ?? Self.screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens[0]
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
            // The pill and the panel are one overlay: the pill stays visible
            // (unfocused) alongside the panel so Tab can cycle focus to it and
            // the draft is always in view. Present it first so the management
            // panel is the one that ends up key.
            conversationPanel?.dismiss()
            presentPillPanel(on: screen, focused: false)
            presentManagementPanel(on: screen, focused: true)
            installKeyMonitorIfNeeded()

        case .conversation:
            let screen = screenForOverlay()
            pillPanel?.dismiss()
            managementPanel?.dismiss()
            presentConversationPanel(on: screen)
            conversationPanel?.focusFirstTextInput()
            installKeyMonitorIfNeeded()
        }

        if case .conversation = mode {
            startBranchPolling()
        } else {
            stopBranchPolling()
        }
    }

    // MARK: - Git branch display

    /// The branch can change under a working agent, so poll it (cheaply)
    /// while the conversation is visible.
    private func startBranchPolling() {
        refreshBranch()
        guard branchTimer == nil else { return }
        branchTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in self.refreshBranch() }
        }
    }

    private func stopBranchPolling() {
        branchTimer?.invalidate()
        branchTimer = nil
        sessionBranch = nil
    }

    private func refreshBranch() {
        guard let sessionID = openSessionID,
              let directory = store.session(id: sessionID)?.workingDirectory
        else {
            sessionBranch = nil
            return
        }
        Task.detached(priority: .utility) {
            let branch = GitInfo.currentBranch(at: directory)
            await MainActor.run { [weak self] in
                guard let self, self.openSessionID == sessionID else { return }
                self.sessionBranch = branch
            }
        }
    }

    private func hideAllPanels() {
        pillPanel?.dismiss()
        managementPanel?.dismiss()
        conversationPanel?.dismiss()
        removeKeyMonitor()
    }

    private func presentPillPanel(on screen: NSScreen, focused: Bool = true) {
        // Tall enough for a 5-line draft plus shadow falloff above the card.
        let size = NSSize(width: 640, height: 280)
        let panel = pillPanel ?? OverlayPanel(size: size)
        pillPanel = panel
        if panel.isVisible {
            // Already showing: the SwiftUI view tracks @Published state, so
            // rebuilding the hosting view would only destroy field focus.
            if focused { panel.makeKey() }
            return
        }
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
        if focused {
            panel.present(on: screen, frame: frame)
        } else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    private func presentManagementPanel(on screen: NSScreen, focused: Bool) {
        // Card is 340 wide + 20 shadow margin on each side.
        let size = NSSize(width: 380, height: 500)
        let panel = managementPanel ?? OverlayPanel(size: size)
        managementPanel = panel
        if panel.isVisible {
            if focused { panel.makeKey() }
            return
        }
        panel.setRootView(
            AgentPanelView()
                .environmentObject(self)
                .environmentObject(store)
        )
        let frame = NSRect(
            x: screen.visibleFrame.minX + 4,
            y: screen.visibleFrame.maxY - size.height - 4,
            width: size.width, height: size.height
        )
        if focused {
            panel.present(on: screen, frame: frame)
        } else {
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
    }

    private static let conversationFrameKey = "AssistantConversationFrame"

    private func presentConversationPanel(on screen: NSScreen) {
        let defaultSize = NSSize(width: 808, height: 668)
        let panel: OverlayPanel
        if let existing = conversationPanel {
            panel = existing
        } else {
            panel = OverlayPanel(size: defaultSize, movableByBackground: true)
            panel.minSize = NSSize(width: 560, height: 440)
            conversationPanel = panel
        }
        if panel.isVisible {
            panel.makeKey()
            return
        }
        panel.setRootView(
            ConversationView()
                .environmentObject(self)
                .environmentObject(store)
                .environmentObject(transcriber)
        )
        // Restore wherever the user last dragged/sized it; center on first use.
        if !panel.setFrameUsingName(Self.conversationFrameKey) {
            panel.setFrame(NSRect(
                x: screen.visibleFrame.midX - defaultSize.width / 2,
                y: screen.visibleFrame.midY - defaultSize.height / 2 + 20,
                width: defaultSize.width, height: defaultSize.height
            ), display: true)
        }
        panel.setFrameAutosaveName(Self.conversationFrameKey)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
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
        static let backtick: UInt16 = 50
    }

    /// Returns true when the event was consumed.
    private func route(_ event: NSEvent) -> Bool {
        // Only interpret keys aimed at our overlay panels. When some other
        // window is key (the directory picker, the settings window), the
        // user is typing into it — never treat that as overlay shortcuts.
        if let keyWindow = NSApp.keyWindow, !(keyWindow is OverlayPanel) {
            return false
        }
        switch mode {
        case .hidden:
            return false

        case .promptEntry(let transcribing):
            switch event.keyCode {
            case Key.escape: feed(.escape); return true
            case Key.returnKey where event.modifierFlags.contains(.shift) && !transcribing:
                return NSApp.sendAction(
                    #selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: self)
            case Key.returnKey: feed(.returnKey); return true
            case Key.tab: feed(.tab); return true
            case Key.delete where transcribing:
                feed(.promptHotkey) // stop transcription, begin editing without a seed
                return true
            default:
                if event.modifierFlags.contains(.command) {
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "v":
                        feed(.voiceKey)
                        return true
                    case "p":
                        pickWorkingDirectory()
                        return true
                    case "m":
                        cycleModel()
                        return true
                    default:
                        return handleEditingCommand(event)
                    }
                }
                if transcribing, let c = typedCharacter(event) {
                    feed(.character(c))
                    return true
                }
                return false // editing: let the text field handle it

            }

        case .management:
            switch event.keyCode {
            case Key.escape: feed(.escape); return true
            case Key.tab: feed(.tab); return true
            case Key.up: feed(.navUp); return true
            case Key.down: feed(.navDown); return true
            case Key.right, Key.returnKey: feed(.navOpen); return true
            case Key.left: feed(.navArchive); return true
            default:
                if let c = typedCharacter(event) { feed(.character(c)) }
                return true // swallow everything else; the panel has no text input

            }

        case .conversation:
            // Ctrl+` toggles the terminal pane (works from either focus).
            if event.keyCode == Key.backtick && event.modifierFlags.contains(.control) {
                toggleTerminal()
                return true
            }
            // A focused terminal gets raw keys — Escape/Tab/Return belong to
            // the shell and TUI apps inside it, not the overlay.
            if TerminalCache.isTerminalResponder(conversationPanel?.firstResponder) {
                return false
            }
            if event.keyCode == Key.escape { feed(.escape); return true }
            if event.keyCode == Key.tab { feed(.tab); return true }
            if event.modifierFlags.contains(.command) {
                let c = event.charactersIgnoringModifiers?.lowercased()
                if c == "v" {
                    feed(.voiceKey)
                    return true
                }
                if c == "y" || c == "n", let sessionID = openSessionID,
                   let request = coordinator.pendingPermissions(for: sessionID).first {
                    coordinator.respondToPermission(sessionID: sessionID, requestID: request.id, allow: c == "y")
                    return true
                }
                if c == "m" {
                    cycleSessionModel()
                    return true
                }
                return handleEditingCommand(event)
            }
            if event.keyCode == Key.returnKey {
                if event.modifierFlags.contains(.shift) {
                    // The NSTextField field editor has no Shift+Return
                    // binding; invoke the literal-newline action directly.
                    return NSApp.sendAction(
                        #selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: self)
                }
                sendComposerMessage()
                return true
            }
            return false // typing flows into the composer

        }
    }

    /// An LSUIElement app has no Edit menu, so the standard edit shortcuts
    /// have no menu item to land on — dispatch them to the field editor.
    /// (⌘V is the voice toggle in this app, so paste has no shortcut.)
    private func handleEditingCommand(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        let selector: Selector?
        switch event.charactersIgnoringModifiers?.lowercased() {
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
