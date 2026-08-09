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
    /// Thinking-effort level for the next agent; nil = CLI default. Persisted.
    @Published var draftEffort: String? {
        didSet { UserDefaults.standard.set(draftEffort, forKey: Self.pickedEffortKey) }
    }
    private static let pickedEffortKey = "agentPickedEffort"
    // Model picker (⌘M).
    @Published var modelSelectedIndex: Int = 0
    // Project picker (⌘P).
    @Published var projectSelectedIndex: Int = 0
    @Published private(set) var recentProjects: [String] = []
    private static let recentProjectsKey = "recentProjects"
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
    // Right-side slot: terminal (⌃`) or diff viewer (⌘⇧D) — one at a time.
    @Published private(set) var terminalVisible = false
    @Published private(set) var activeTerminal: LocalProcessTerminalView?
    @Published private(set) var diffVisible = false
    @Published private(set) var diffLines: [DiffLine] = []
    @Published private(set) var diffIsEmpty = false
    @Published private(set) var modelPaneVisible = false
    private let sidePaneWidth: CGFloat = 440 // pane 424 + HStack spacing 16

    // Inline @file / /command suggestions (pill + composer).
    enum SuggestionField { case pill, composer }
    @Published private(set) var suggestions: [InlineSuggestion] = []
    @Published private(set) var suggestionsLoading = false
    /// Which input the popup belongs to; nil = hidden.
    @Published private(set) var suggestionField: SuggestionField?
    @Published var suggestionIndex = 0
    private var suggestionToken: InlineToken?
    /// Token the user dismissed with Esc — don't re-show until it changes.
    private var suppressedToken: InlineToken?
    private var fileCache: [String: (files: [String], fetchedAt: Date)] = [:]
    private var fileFetchInflight: Set<String> = []

    let store: SessionStore
    let coordinator: AgentCoordinator
    let transcriber: Transcriber

    /// Gate: returns false when onboarding is incomplete; the overlay then
    /// defers to the settings window.
    var canUseOverlay: () -> Bool = { true }
    var onRequestSettings: () -> Void = {}

    private var model = OverlayInteractionModel()
    /// Bottom-center panel hosting the management card stacked above the pill.
    private var pillPanel: OverlayPanel?
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
        if let savedEffort = UserDefaults.standard.string(forKey: Self.pickedEffortKey),
           ClaudeCodeLauncher.effortOptions.contains(savedEffort),
           ClaudeCodeLauncher.supportsEffort(model: draftModel) {
            draftEffort = savedEffort
        }
        loadRecentProjects()

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

        // Recompute @/-suggestions as either input changes. The debounce
        // also lets the field editor's caret settle after each keystroke.
        $draftText
            .removeDuplicates()
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshSuggestions(field: .pill) }
            .store(in: &cancellables)
        $composerText
            .removeDuplicates()
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshSuggestions(field: .composer) }
            .store(in: &cancellables)
    }

    // MARK: - Inline @file and /command suggestions

    /// Visible whenever an @/-token is being typed — including with zero
    /// matches, so the popup shows "no results" instead of vanishing (which
    /// flashed the management card back in).
    var suggestionPopupVisible: Bool {
        suggestionField != nil
    }

    /// What the active token is asking for, for empty/loading copy.
    var suggestionKind: InlineToken.Kind? {
        suggestionToken?.kind
    }

    private func suggestionText(for field: SuggestionField) -> String {
        field == .pill ? draftText : composerText
    }

    private func suggestionDirectory(for field: SuggestionField) -> String {
        switch field {
        case .pill: return draftWorkingDirectory ?? coordinator.defaultWorkingDirectory
        case .composer: return sessionMeta?.workingDirectory ?? coordinator.defaultWorkingDirectory
        }
    }

    /// Cursor as a character offset, from the panel's field editor; falls
    /// back to end-of-text when the editor and binding disagree.
    private func suggestionCursor(for field: SuggestionField, text: String) -> Int {
        let panel = field == .pill ? pillPanel : conversationPanel
        guard let editor = panel?.firstResponder as? NSTextView,
              editor.string == text
        else { return text.count }
        let location = editor.selectedRange().location
        guard location != NSNotFound else { return text.count }
        let index = String.Index(utf16Offset: min(location, text.utf16.count), in: text)
        return text.distance(from: text.startIndex, to: index)
    }

    private func refreshSuggestions(field: SuggestionField) {
        // Only while the matching input is actually being typed into.
        switch field {
        case .pill:
            guard case .promptEntry(transcribing: false) = mode else {
                if suggestionField == .pill { clearSuggestions() }
                return
            }
        case .composer:
            guard case .conversation = mode, !modelPaneVisible, !composerTranscribing else {
                if suggestionField == .composer { clearSuggestions() }
                return
            }
        }

        let text = suggestionText(for: field)
        let cursor = suggestionCursor(for: field, text: text)
        guard let token = InlineTrigger.activeToken(text: text, cursor: cursor) else {
            if suggestionField == field || suggestionField == nil { clearSuggestions() }
            return
        }
        // An Esc-dismissed token stays hidden until the trigger moves.
        if let suppressed = suppressedToken,
           suppressed.kind == token.kind, suppressed.start == token.start {
            clearSuggestions(keepSuppressed: true)
            return
        }
        suppressedToken = nil
        suggestionToken = token
        suggestionField = field

        let directory = suggestionDirectory(for: field)
        switch token.kind {
        case .slashCommand:
            if let commands = SlashCommandCatalog.shared.cached(for: directory) {
                suggestionsLoading = false
                setSuggestions(InlineTrigger.filterCommands(commands, query: token.query).map { .command($0) })
            } else {
                suggestionsLoading = true
                suggestions = []
                Task { [weak self] in
                    _ = await SlashCommandCatalog.shared.commands(for: directory)
                    self?.refreshSuggestions(field: field)
                }
            }
        case .fileMention:
            if let entry = fileCache[directory], Date().timeIntervalSince(entry.fetchedAt) < 20 {
                suggestionsLoading = false
                setSuggestions(InlineTrigger.filterFiles(entry.files, query: token.query).map { .file($0) })
            } else {
                suggestionsLoading = true
                if fileCache[directory] == nil { suggestions = [] }
                guard !fileFetchInflight.contains(directory) else { return }
                fileFetchInflight.insert(directory)
                Task.detached(priority: .userInitiated) {
                    let files = FileLister.listFiles(at: directory)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.fileCache[directory] = (files, Date())
                        self.fileFetchInflight.remove(directory)
                        self.refreshSuggestions(field: field)
                    }
                }
            }
        }
    }

    private func setSuggestions(_ new: [InlineSuggestion]) {
        suggestions = new
        suggestionIndex = min(suggestionIndex, max(0, new.count - 1))
    }

    func moveSuggestion(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        suggestionIndex = (suggestionIndex + delta + suggestions.count) % suggestions.count
    }

    func acceptSuggestion() {
        guard let token = suggestionToken, let field = suggestionField,
              suggestionIndex < suggestions.count
        else { return }
        let text = suggestionText(for: field)
        let newText: String
        switch suggestions[suggestionIndex] {
        case .file(let path):
            newText = InlineTrigger.replacingFileMention(text: text, token: token, path: path)
        case .command(let command):
            newText = InlineTrigger.replacingSlashCommand(text: text, token: token, commandName: command.name)
        }
        switch field {
        case .pill: draftText = newText
        case .composer: composerText = newText
        }
        clearSuggestions()
    }

    func dismissSuggestions() {
        suppressedToken = suggestionToken
        clearSuggestions(keepSuppressed: true)
    }

    private func clearSuggestions(keepSuppressed: Bool = false) {
        suggestions = []
        suggestionsLoading = false
        suggestionField = nil
        suggestionToken = nil
        suggestionIndex = 0
        if !keepSuppressed { suppressedToken = nil }
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
            clearSuggestions()
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
            collapseSidePanes()
            clearSuggestions()
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
                clearSuggestions()
                openSessionID = session.id
                composerText = ""
                composerBaseText = ""
                terminalVisible = false
                diffVisible = false
                modelPaneVisible = false
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
            collapseSidePanes()
            clearSuggestions()
            openSessionID = nil

        case .showProjectPicker:
            projectSelectedIndex = 0

        case .projectPrevious:
            moveProjectSelection(-1)

        case .projectNext:
            moveProjectSelection(1)

        case .chooseProject:
            if projectSelectedIndex < recentProjects.count {
                let path = recentProjects[projectSelectedIndex]
                draftWorkingDirectory = path
                addRecentProject(path)
            } else {
                // The trailing "Add new project…" row.
                pickWorkingDirectory()
            }

        case .showModelPicker:
            modelSelectedIndex = 0

        case .modelPrevious:
            moveModelSelection(-1)

        case .modelNext:
            moveModelSelection(1)

        case .applyModelSelection:
            applyModelSelection()

        case .toggleComposerTranscription:
            if composerTranscribing {
                stopComposerTranscription()
            } else {
                clearSuggestions()
                composerBaseText = composerText
                composerTranscribing = true
                transcriber.start()
            }
        }
    }

    // MARK: - Side panes (terminal / diff)

    private func expandSideSlot(_ panel: OverlayPanel) {
        var frame = panel.frame
        frame.size.width += sidePaneWidth
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if frame.maxX > visible.maxX {
                frame.origin.x = max(visible.minX, visible.maxX - frame.width)
            }
        }
        panel.setFrame(frame, display: true)
    }

    private func shrinkSideSlot(_ panel: OverlayPanel) {
        var frame = panel.frame
        frame.size.width -= sidePaneWidth
        panel.setFrame(frame, display: true)
    }

    /// Ctrl+`: show/hide a shell terminal beside the conversation, scoped to
    /// the agent's working directory. The window widens to make room.
    private func toggleTerminal() {
        guard case .conversation = mode,
              let panel = conversationPanel,
              let sessionID = openSessionID,
              let meta = store.session(id: sessionID)
        else { return }

        if terminalVisible {
            terminalVisible = false
            shrinkSideSlot(panel)
            panel.focusFirstTextInput()
            return
        }
        let terminal = TerminalCache.shared.view(for: sessionID, workingDirectory: meta.workingDirectory)
        activeTerminal = terminal
        if diffVisible || modelPaneVisible {
            diffVisible = false
            modelPaneVisible = false // swap panes; width stays
        } else {
            expandSideSlot(panel)
        }
        terminalVisible = true
        // Focus once SwiftUI has mounted the pane.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak panel, weak terminal] in
            guard let panel, let terminal else { return }
            panel.makeFirstResponder(terminal)
        }
    }

    /// ⌘⇧D: show/hide uncommitted changes in the session's directory.
    private func toggleDiff() {
        guard case .conversation = mode,
              let panel = conversationPanel,
              let sessionID = openSessionID,
              let meta = store.session(id: sessionID)
        else { return }

        if diffVisible {
            diffVisible = false
            shrinkSideSlot(panel)
            panel.focusFirstTextInput()
            return
        }
        let directory = meta.workingDirectory
        Task.detached(priority: .userInitiated) {
            let text = GitInfo.uncommittedDiff(at: directory)
            let lines = GitInfo.parseDiff(text ?? "")
            await MainActor.run { [weak self] in
                guard let self, self.openSessionID == sessionID,
                      case .conversation = self.mode,
                      let panel = self.conversationPanel
                else { return }
                self.diffLines = lines
                self.diffIsEmpty = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if self.terminalVisible || self.modelPaneVisible {
                    self.terminalVisible = false
                    self.modelPaneVisible = false // swap panes; width stays
                } else if !self.diffVisible {
                    self.expandSideSlot(panel)
                }
                self.diffVisible = true
            }
        }
    }

    /// ⌘M in the conversation: model/thinking picker in the side slot.
    private func toggleModelPane() {
        guard case .conversation = mode,
              let panel = conversationPanel,
              openSessionID != nil
        else { return }

        if modelPaneVisible {
            modelPaneVisible = false
            shrinkSideSlot(panel)
            panel.focusFirstTextInput()
            return
        }
        modelSelectedIndex = 0
        if terminalVisible || diffVisible {
            terminalVisible = false
            diffVisible = false // swap panes; width stays
        } else {
            expandSideSlot(panel)
        }
        modelPaneVisible = true
    }

    /// Rows in the session model pane: concrete models (a live session can't
    /// return to "CLI default"), plus thinking levels when supported.
    private var sessionMeta: AgentSessionMeta? {
        openSessionID.flatMap { store.session(id: $0) }
    }

    var sessionConcreteModels: [String] {
        ClaudeCodeLauncher.modelOptions.compactMap { $0 }
    }

    var sessionPaneShowsThinking: Bool {
        ClaudeCodeLauncher.supportsEffort(model: sessionMeta?.model)
    }

    private var sessionModelRowCount: Int {
        sessionConcreteModels.count
            + (sessionPaneShowsThinking ? ClaudeCodeLauncher.effortOptions.count : 0)
    }

    private func moveSessionModelSelection(_ delta: Int) {
        let count = sessionModelRowCount
        modelSelectedIndex = (modelSelectedIndex + delta + count) % count
    }

    private func applySessionModelSelection() {
        guard let sessionID = openSessionID else { return }
        let models = sessionConcreteModels
        if modelSelectedIndex < models.count {
            coordinator.setModel(models[modelSelectedIndex], for: sessionID)
            if !ClaudeCodeLauncher.supportsEffort(model: models[modelSelectedIndex]) {
                coordinator.setEffort(nil, for: sessionID)
            }
        } else if sessionPaneShowsThinking {
            let index = modelSelectedIndex - models.count
            let efforts = ClaudeCodeLauncher.effortOptions
            if index < efforts.count {
                coordinator.setEffort(efforts[index], for: sessionID)
            }
        }
    }

    /// Shrink the window back before hiding so the autosaved frame (and next
    /// open) never includes a side pane's width.
    private func collapseSidePanes() {
        if terminalVisible || diffVisible || modelPaneVisible, let panel = conversationPanel {
            shrinkSideSlot(panel)
        }
        terminalVisible = false
        diffVisible = false
        modelPaneVisible = false
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
        addRecentProject(draftWorkingDirectory ?? coordinator.defaultWorkingDirectory)
        openSessionID = coordinator.startAgent(
            prompt: prompt, workingDirectory: draftWorkingDirectory,
            model: draftModel, effort: draftEffort
        )
        composerText = ""
        composerBaseText = ""
    }

    /// Display string for the pill's model indicator; includes the thinking
    /// level whenever the configured model supports one.
    var pillModelDisplay: String {
        let model = draftModel ?? "default"
        guard ClaudeCodeLauncher.supportsEffort(model: draftModel) else { return model }
        return "\(model) · \(draftEffort ?? "default")"
    }

    // MARK: - Model picker rows

    /// True when the thinking section is shown for the current draft model.
    var modelPickerShowsThinking: Bool {
        ClaudeCodeLauncher.supportsEffort(model: draftModel)
    }

    private var modelPickerRowCount: Int {
        ClaudeCodeLauncher.modelOptions.count
            + (modelPickerShowsThinking ? ClaudeCodeLauncher.effortOptions.count : 0)
    }

    private func moveModelSelection(_ delta: Int) {
        let count = modelPickerRowCount
        modelSelectedIndex = (modelSelectedIndex + delta + count) % count
    }

    private func applyModelSelection() {
        let models = ClaudeCodeLauncher.modelOptions
        if modelSelectedIndex < models.count {
            draftModel = models[modelSelectedIndex]
            if !ClaudeCodeLauncher.supportsEffort(model: draftModel) {
                draftEffort = nil
            }
        } else if modelPickerShowsThinking {
            let efforts = ClaudeCodeLauncher.effortOptions
            let index = modelSelectedIndex - models.count
            if index < efforts.count { draftEffort = efforts[index] }
        }
        // The thinking section may have appeared/disappeared; keep the
        // highlight in range.
        modelSelectedIndex = min(modelSelectedIndex, modelPickerRowCount - 1)
    }

    // MARK: - Recent projects

    private func loadRecentProjects() {
        var projects = UserDefaults.standard.stringArray(forKey: Self.recentProjectsKey) ?? []
        if projects.isEmpty {
            // First run of this feature: seed from past sessions' directories.
            var seen = Set<String>()
            for session in store.sessions.sorted(by: { $0.updatedAt > $1.updatedAt })
            where seen.insert(session.workingDirectory).inserted {
                projects.append(session.workingDirectory)
            }
        }
        recentProjects = projects.filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        UserDefaults.standard.set(recentProjects, forKey: Self.recentProjectsKey)
    }

    /// Record a project use: move-to-front, dedupe, cap.
    func addRecentProject(_ path: String) {
        var projects = recentProjects.filter { $0 != path }
        projects.insert(path, at: 0)
        recentProjects = Array(projects.prefix(12))
        UserDefaults.standard.set(recentProjects, forKey: Self.recentProjectsKey)
    }

    private func moveProjectSelection(_ delta: Int) {
        let count = recentProjects.count + 1 // + "Add new project…"
        projectSelectedIndex = (projectSelectedIndex + delta + count) % count
    }

    /// Display string for the pill: the project (last path component) the
    /// next agent will run in.
    var pillWorkingDirectoryDisplay: String {
        ((draftWorkingDirectory ?? coordinator.defaultWorkingDirectory) as NSString).lastPathComponent
    }

    /// Full path, for the hover tooltip.
    var pillWorkingDirectoryFullPath: String {
        ((draftWorkingDirectory ?? coordinator.defaultWorkingDirectory) as NSString).abbreviatingWithTildeInPath
    }

    /// ⌘P: pick the directory the agent is scoped to. Uses the system open
    /// panel (keyboard-navigable; ⌘⇧G accepts a typed path).
    private func pickWorkingDirectory() {
        let pillWasVisible = pillPanel?.isVisible ?? false
        // Order out (not dismiss) so the pill's state/hierarchy survives.
        pillPanel?.orderOut(nil)

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
            addRecentProject(url.path)
        }
        NSApp.deactivate()

        if case .promptEntry = mode, pillWasVisible {
            pillPanel?.orderFrontRegardless()
            pillPanel?.makeKey()
            pillPanel?.focusFirstTextInput()
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
            presentPillPanel(on: screen)
            installKeyMonitorIfNeeded()

        case .management, .projectPicker, .modelPicker:
            // The pill and the management/projects card share one panel,
            // stacked vertically — which of them "has focus" is driven by
            // `mode`, so the panel just needs to be key. Drop the field's
            // caret so it doesn't look editable while the card is navigated.
            let screen = screenForOverlay()
            conversationPanel?.dismiss()
            presentPillPanel(on: screen)
            pillPanel?.makeFirstResponder(nil)
            installKeyMonitorIfNeeded()

        case .conversation:
            let screen = screenForOverlay()
            pillPanel?.dismiss()
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
        conversationPanel?.dismiss()
        removeKeyMonitor()
    }

    private func presentPillPanel(on screen: NSScreen) {
        // Cards are 560 wide + 40 shadow margin each side. Tall enough for
        // the management card, a 5-line draft, and shadow falloff above.
        let size = NSSize(
            width: 640,
            height: min(680, screen.visibleFrame.height - 48)
        )
        let panel = pillPanel ?? OverlayPanel(size: size)
        pillPanel = panel
        if panel.isVisible {
            // Already showing: the SwiftUI view tracks @Published state, so
            // rebuilding the hosting view would only destroy field focus.
            panel.makeKey()
            return
        }
        panel.setRootView(
            PromptPillView()
                .environmentObject(self)
                .environmentObject(store)
                .environmentObject(transcriber)
        )
        let frame = NSRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 48,
            width: size.width, height: size.height
        )
        panel.present(on: screen, frame: frame)
    }

    private static let conversationFrameKey = "OverlayConversationFrame"

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
        // ⌘, opens Settings from any overlay mode.
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
            onRequestSettings()
            return true
        }
        switch mode {
        case .hidden:
            return false

        case .promptEntry(let transcribing):
            if !transcribing, let handled = routeSuggestionKey(event) { return handled }
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
                    case "d" where !event.modifierFlags.contains(.shift):
                        feed(.voiceKey)
                        return true
                    case "p":
                        feed(.projectKey)
                        return true
                    case "m":
                        feed(.modelKey)
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

        case .projectPicker:
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "p" {
                feed(.projectKey) // toggle closed
                return true
            }
            switch event.keyCode {
            case Key.escape: feed(.escape); return true
            case Key.tab: feed(.tab); return true
            case Key.up: feed(.navUp); return true
            case Key.down: feed(.navDown); return true
            case Key.right, Key.returnKey: feed(.navOpen); return true
            default:
                if let c = typedCharacter(event) { feed(.character(c)) }
                return true // swallow everything else; the picker has no text input

            }

        case .modelPicker:
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "m" {
                feed(.modelKey) // toggle closed
                return true
            }
            switch event.keyCode {
            case Key.escape: feed(.escape); return true
            case Key.tab: feed(.tab); return true
            case Key.up: feed(.navUp); return true
            case Key.down: feed(.navDown); return true
            case Key.right, Key.returnKey: feed(.navOpen); return true
            default:
                if let c = typedCharacter(event) { feed(.character(c)) }
                return true // swallow everything else; the picker has no text input

            }

        case .conversation:
            // Pane toggles work regardless of which pane has focus — the
            // shell never sees ⌃` or ⌘⇧D.
            if event.keyCode == Key.backtick && event.modifierFlags.contains(.control) {
                toggleTerminal()
                return true
            }
            if event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift),
               event.charactersIgnoringModifiers?.lowercased() == "d" {
                toggleDiff()
                return true
            }
            if event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift),
               event.charactersIgnoringModifiers?.lowercased() == "m" {
                toggleModelPane()
                return true
            }
            // A focused terminal gets raw keys — Escape/Tab/Return belong to
            // the shell and TUI apps inside it, not the overlay.
            if TerminalCache.isTerminalResponder(conversationPanel?.firstResponder) {
                return false
            }
            // While the model pane is open it is modal, using the same keys
            // as the pill's model picker: E/D or arrows navigate, Space
            // applies and stays open, Return applies and closes.
            if modelPaneVisible {
                switch event.keyCode {
                case Key.up: moveSessionModelSelection(-1); return true
                case Key.down: moveSessionModelSelection(1); return true
                case Key.returnKey:
                    applySessionModelSelection()
                    toggleModelPane() // close + refocus composer
                    return true
                case Key.escape:
                    toggleModelPane()
                    return true
                default:
                    if !event.modifierFlags.contains(.command), let c = typedCharacter(event) {
                        switch c.lowercased() {
                        case "e": moveSessionModelSelection(-1)
                        case "d": moveSessionModelSelection(1)
                        case " ": applySessionModelSelection()
                        default: break
                        }
                        return true // swallow typing while the pane is open
                    }
                }
            }
            if let handled = routeSuggestionKey(event) { return handled }
            // ⌃C stops the in-flight agent turn (composer focus only — in
            // the terminal pane ⌃C belongs to the shell, handled above).
            if event.modifierFlags.contains(.control),
               event.charactersIgnoringModifiers?.lowercased() == "c",
               let sessionID = openSessionID {
                coordinator.interrupt(sessionID: sessionID)
                return true
            }
            if event.keyCode == Key.escape { feed(.escape); return true }
            if event.keyCode == Key.tab { feed(.tab); return true }
            if event.modifierFlags.contains(.command) {
                let c = event.charactersIgnoringModifiers?.lowercased()
                if c == "d" && !event.modifierFlags.contains(.shift) {
                    feed(.voiceKey)
                    return true
                }
                if c == "y" || c == "n", let sessionID = openSessionID,
                   let request = coordinator.pendingPermissions(for: sessionID).first {
                    coordinator.respondToPermission(sessionID: sessionID, requestID: request.id, allow: c == "y")
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

    /// Keys the @/-suggestion popup owns while visible. Returns nil when the
    /// popup is hidden or the key isn't one of its (event falls through).
    private func routeSuggestionKey(_ event: NSEvent) -> Bool? {
        guard suggestionPopupVisible else { return nil }
        if event.keyCode == Key.escape {
            dismissSuggestions()
            return true
        }
        guard !suggestions.isEmpty else { return nil } // still loading
        switch event.keyCode {
        case Key.up: moveSuggestion(-1); return true
        case Key.down: moveSuggestion(1); return true
        case Key.tab: acceptSuggestion(); return true
        case Key.returnKey where !event.modifierFlags.contains(.shift):
            acceptSuggestion()
            return true
        default:
            return nil
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
