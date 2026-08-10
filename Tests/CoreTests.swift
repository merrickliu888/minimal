import Foundation

// Minimal hand-rolled test harness (no XCTest in a plain swiftc build).
var failureCount = 0
var testCount = 0

func expect(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    testCount += 1
    if !condition {
        failureCount += 1
        print("FAIL [\((file as NSString).lastPathComponent):\(line)] \(message)")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
    expect(a == b, "\(message) — expected \(b), got \(a)", file: file, line: line)
}

// MARK: - StreamJSON tests

func testStreamJSONParsing() {
    let initLine = #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"ebbd08b6-45d6-4c69-95b6-73d2e79a63de","tools":[]}"#
    expectEqual(StreamJSON.parseLine(initLine), .sessionStarted(sessionID: "ebbd08b6-45d6-4c69-95b6-73d2e79a63de"), "init line")

    let textLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}"#
    expectEqual(StreamJSON.parseLine(textLine), .assistantText("hello"), "assistant text")

    let thinkingLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}"#
    expectEqual(StreamJSON.parseLine(thinkingLine), .ignored, "thinking ignored")

    let toolLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la"}}]}}"#
    expectEqual(StreamJSON.parseLine(toolLine), .toolUse(name: "Bash", summary: "ls -la"), "tool use")

    let resultLine = #"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"x"}"#
    expectEqual(StreamJSON.parseLine(resultLine), .turnEnded(isError: false, resultText: "done"), "result success")

    let errorResult = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}"#
    expectEqual(StreamJSON.parseLine(errorResult), .turnEnded(isError: true, resultText: "boom"), "result error")

    let statusLine = #"{"type":"system","subtype":"status","status":null}"#
    expectEqual(StreamJSON.parseLine(statusLine), .ignored, "status ignored")

    expectEqual(StreamJSON.parseLine("not json"), nil, "garbage line")
    expectEqual(StreamJSON.parseLine(""), nil, "empty line")

    // Encoding round-trip
    let encoded = StreamJSON.encodeUserMessage(text: "fix the bug\nplease")!
    let decoded = try! JSONSerialization.jsonObject(with: encoded.data(using: .utf8)!) as! [String: Any]
    expectEqual(decoded["type"] as! String, "user", "encoded type")
    let msg = decoded["message"] as! [String: Any]
    let content = msg["content"] as! [[String: Any]]
    expectEqual(content[0]["text"] as! String, "fix the bug\nplease", "encoded text")
    expect(!encoded.contains("\n"), "encoded line must not contain raw newlines")
}

func testPermissionProtocol() {
    let controlLine = #"{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"touch /tmp/x","description":"Create file"}}}"#
    guard case .permissionRequested(let id, let tool, let summary, let inputJSON)? = StreamJSON.parseLine(controlLine) else {
        expect(false, "control_request should parse as permissionRequested")
        return
    }
    expectEqual(id, "req-1", "request id")
    expectEqual(tool, "Bash", "tool name")
    expectEqual(summary, "touch /tmp/x", "summary uses command")
    expect(inputJSON.contains("touch /tmp/x"), "input preserved")

    // Allow response echoes the original input.
    let allow = StreamJSON.encodePermissionResponse(requestID: "req-1", allow: true, inputJSON: inputJSON)!
    let decoded = try! JSONSerialization.jsonObject(with: allow.data(using: .utf8)!) as! [String: Any]
    expectEqual(decoded["type"] as! String, "control_response", "response type")
    let response = decoded["response"] as! [String: Any]
    expectEqual(response["request_id"] as! String, "req-1", "response request id")
    let inner = response["response"] as! [String: Any]
    expectEqual(inner["behavior"] as! String, "allow", "allow behavior")
    let updated = inner["updatedInput"] as! [String: Any]
    expectEqual(updated["command"] as! String, "touch /tmp/x", "updatedInput echoed")

    // Deny carries a message and no updatedInput requirement.
    let deny = StreamJSON.encodePermissionResponse(requestID: "req-1", allow: false, inputJSON: inputJSON)!
    let denyDecoded = try! JSONSerialization.jsonObject(with: deny.data(using: .utf8)!) as! [String: Any]
    let denyInner = (denyDecoded["response"] as! [String: Any])["response"] as! [String: Any]
    expectEqual(denyInner["behavior"] as! String, "deny", "deny behavior")
    expect((denyInner["message"] as? String)?.isEmpty == false, "deny message present")

    // Other control requests are ignored, not surfaced.
    let other = #"{"type":"control_request","request_id":"r2","request":{"subtype":"hook_callback"}}"#
    expectEqual(StreamJSON.parseLine(other), .ignored, "non-permission control requests ignored")
}

func testToolSummaries() {
    expectEqual(StreamJSON.toolSummary(name: "Edit", input: ["file_path": "/Users/x/proj/main.swift"]), "/Users/x/proj/main.swift", "edit summary")
    let long = String(repeating: "x", count: 200)
    expect(StreamJSON.toolSummary(name: "Bash", input: ["command": long]).count <= 121, "long command truncated")
    expectEqual(StreamJSON.toolSummary(name: "Grep", input: ["pattern": "TODO"]), "TODO", "grep summary")
}

// MARK: - Interaction model tests

func testPromptEntryFlow() {
    var m = MinimalInteractionModel()
    // Text entry is the default mode.
    expectEqual(m.handle(.promptHotkey), [.showPromptPill, .beginEditing(seed: nil)], "opt+space opens pill in text mode")
    expectEqual(m.mode, .promptEntry(transcribing: false), "editing state by default")

    // Cmd+V toggles voice on…
    expectEqual(m.handle(.voiceKey), [.startTranscription], "cmd+v starts voice")
    expectEqual(m.mode, .promptEntry(transcribing: true), "transcribing state")

    // …and off again
    expectEqual(m.handle(.voiceKey), [.stopTranscription, .beginEditing(seed: nil)], "cmd+v stops voice")
    expectEqual(m.mode, .promptEntry(transcribing: false), "back to editing")

    // Typing a key while transcribing stops and seeds the field
    _ = m.handle(.voiceKey)
    expectEqual(m.handle(.character("f")), [.stopTranscription, .beginEditing(seed: "f")], "typing stops transcription")

    // Return submits and opens the new agent's conversation
    expectEqual(m.handle(.returnKey), [.submitPrompt], "return submits")
    expectEqual(m.mode, .conversation, "conversation stays open after submit")

    // Escape from there returns to the management panel
    expectEqual(m.handle(.escape), [.closeConversation, .showManagement], "escape to management")
}

func testPromptEscapeAndTab() {
    var m = MinimalInteractionModel()
    _ = m.handle(.promptHotkey)
    expectEqual(m.handle(.escape), [.hideMinimal], "escape closes from text mode")
    expectEqual(m.mode, .hidden, "hidden after escape")

    _ = m.handle(.promptHotkey)
    _ = m.handle(.voiceKey) // voice on
    expectEqual(m.handle(.escape), [.stopTranscription, .hideMinimal], "escape closes while transcribing")
    expectEqual(m.mode, .hidden, "hidden after escape from voice")

    _ = m.handle(.promptHotkey)
    expectEqual(m.handle(.tab), [.showManagement], "tab moves to management")
    expectEqual(m.mode, .management(confirmingArchive: false), "management mode after tab")

    // Tab cycles back to the prompt field without clearing the draft
    // (no .showPromptPill, which would reset it).
    expectEqual(m.handle(.tab), [.beginEditing(seed: nil)], "tab returns to prompt field")
    expectEqual(m.mode, .promptEntry(transcribing: false), "editing mode after tab back")
}

func testMinimalToggle() {
    var m = MinimalInteractionModel()
    // ⌥Space toggles the overlay from every visible mode.
    _ = m.handle(.promptHotkey)
    expectEqual(m.handle(.promptHotkey), [.hideMinimal], "opt+space closes from text mode")
    expectEqual(m.mode, .hidden, "hidden after toggle")

    _ = m.handle(.promptHotkey)
    _ = m.handle(.voiceKey)
    expectEqual(m.handle(.promptHotkey), [.stopTranscription, .hideMinimal], "opt+space closes while transcribing")

    _ = m.handle(.managementHotkey)
    expectEqual(m.handle(.promptHotkey), [.hideMinimal], "opt+space closes from management")

    _ = m.handle(.managementHotkey)
    _ = m.handle(.character(" ")) // needs a session in reality; model still transitions
    expectEqual(m.handle(.promptHotkey), [.hideMinimal], "opt+space closes from conversation")
    expectEqual(m.mode, .hidden, "hidden after closing conversation")
}

func testManagementNavigation() {
    var m = MinimalInteractionModel()
    _ = m.handle(.managementHotkey)
    expectEqual(m.mode, .management(confirmingArchive: false), "opt+tab opens management")

    expectEqual(m.handle(.character("e")), [.selectPrevious], "e selects previous")
    expectEqual(m.handle(.character("d")), [.selectNext], "d selects next")
    expectEqual(m.handle(.navUp), [.selectPrevious], "up arrow")
    expectEqual(m.handle(.navDown), [.selectNext], "down arrow")

    expectEqual(m.handle(.character(" ")), [.openSelected], "space opens agent")
    expectEqual(m.mode, .conversation, "conversation mode")

    expectEqual(m.handle(.escape), [.closeConversation, .showManagement], "escape closes conversation")
    expectEqual(m.mode, .management(confirmingArchive: false), "back to management")
}

func testArchiveConfirmation() {
    var m = MinimalInteractionModel()
    _ = m.handle(.managementHotkey)

    expectEqual(m.handle(.character("a")), [.beginArchiveConfirmation], "a begins archive confirm")
    expectEqual(m.mode, .management(confirmingArchive: true), "confirming state")

    // Escape cancels
    expectEqual(m.handle(.escape), [.cancelArchiveConfirmation], "escape cancels archive")
    expectEqual(m.mode, .management(confirmingArchive: false), "back to browsing")

    // D cancels too
    _ = m.handle(.navArchive)
    expectEqual(m.handle(.character("d")), [.cancelArchiveConfirmation], "d cancels archive")

    // A confirms
    _ = m.handle(.character("a"))
    expectEqual(m.handle(.character("a")), [.confirmArchive], "a confirms archive")
    expectEqual(m.mode, .management(confirmingArchive: false), "browsing after archive")

    // W/S ignored while confirming
    _ = m.handle(.character("a"))
    expectEqual(m.handle(.character("e")), [], "nav ignored while confirming")
}

func testConversationMode() {
    var m = MinimalInteractionModel()
    _ = m.handle(.managementHotkey)
    _ = m.handle(.character(" "))
    expectEqual(m.mode, .conversation, "in conversation")

    expectEqual(m.handle(.voiceKey), [.toggleComposerTranscription], "cmd+v toggles composer voice")
    expectEqual(m.mode, .conversation, "still in conversation")

    // Tab exits the conversation back to the management overlay
    expectEqual(m.handle(.tab), [.closeConversation, .showManagement], "tab exits conversation")
    expectEqual(m.mode, .management(confirmingArchive: false), "management after tab")
    _ = m.handle(.character(" ")) // back into conversation for remaining checks

    // Typing keys are not interpreted as commands in conversation mode
    expectEqual(m.handle(.character("a")), [], "letters not interpreted in conversation")
}

func testProjectPickerFlow() {
    var m = MinimalInteractionModel()
    _ = m.handle(.promptHotkey)

    // ⌘P opens the picker in place of the agents card.
    expectEqual(m.handle(.projectKey), [.showProjectPicker], "cmd+p opens picker")
    expectEqual(m.mode, .projectPicker, "picker mode")

    expectEqual(m.handle(.character("e")), [.projectPrevious], "e navigates up")
    expectEqual(m.handle(.character("d")), [.projectNext], "d navigates down")
    expectEqual(m.handle(.navUp), [.projectPrevious], "up arrow")
    expectEqual(m.handle(.navDown), [.projectNext], "down arrow")

    // Space selects and returns to the prompt field.
    expectEqual(m.handle(.character(" ")), [.chooseProject, .beginEditing(seed: nil)], "space chooses project")
    expectEqual(m.mode, .promptEntry(transcribing: false), "back to prompt entry")

    // Return also selects; Escape/⌘P close without choosing.
    _ = m.handle(.projectKey)
    expectEqual(m.handle(.returnKey), [.chooseProject, .beginEditing(seed: nil)], "return chooses project")
    _ = m.handle(.projectKey)
    expectEqual(m.handle(.escape), [.beginEditing(seed: nil)], "escape closes without choosing")
    expectEqual(m.mode, .promptEntry(transcribing: false), "prompt entry after escape")
    _ = m.handle(.projectKey)
    expectEqual(m.handle(.projectKey), [.beginEditing(seed: nil)], "cmd+p toggles closed")

    // ⌥Space still closes the whole overlay from the picker.
    _ = m.handle(.projectKey)
    expectEqual(m.handle(.promptHotkey), [.hideMinimal], "opt+space closes overlay from picker")
    expectEqual(m.mode, .hidden, "hidden")
}

func testModelPickerFlow() {
    var m = MinimalInteractionModel()
    _ = m.handle(.promptHotkey)

    expectEqual(m.handle(.modelKey), [.showModelPicker], "cmd+m opens model picker")
    expectEqual(m.mode, .modelPicker, "model picker mode")

    expectEqual(m.handle(.character("e")), [.modelPrevious], "e navigates up")
    expectEqual(m.handle(.character("d")), [.modelNext], "d navigates down")

    // Space applies without closing (set model, then thinking).
    expectEqual(m.handle(.character(" ")), [.applyModelSelection], "space applies, stays open")
    expectEqual(m.mode, .modelPicker, "still in model picker")

    // Return applies and closes.
    expectEqual(m.handle(.returnKey), [.applyModelSelection, .beginEditing(seed: nil)], "return applies and closes")
    expectEqual(m.mode, .promptEntry(transcribing: false), "back to prompt entry")

    // Escape / ⌘M close without applying.
    _ = m.handle(.modelKey)
    expectEqual(m.handle(.escape), [.beginEditing(seed: nil)], "escape closes without applying")
    _ = m.handle(.modelKey)
    expectEqual(m.handle(.modelKey), [.beginEditing(seed: nil)], "cmd+m toggles closed")
}

// MARK: - Launcher tests

func testExecutableResolution() {
    let resolved = ClaudeCodeLauncher.resolveExecutable(
        configuredPath: nil, home: "/Users/t", pathEnvironment: "/bin:/custom",
        isExecutable: { $0 == "/custom/claude" }
    )
    expectEqual(resolved, "/custom/claude", "PATH fallback")

    let known = ClaudeCodeLauncher.resolveExecutable(
        configuredPath: nil, home: "/Users/t", pathEnvironment: nil,
        isExecutable: { $0 == "/Users/t/.local/bin/claude" }
    )
    expectEqual(known, "/Users/t/.local/bin/claude", "well-known path")

    let configured = ClaudeCodeLauncher.resolveExecutable(
        configuredPath: "/x/claude", home: "/Users/t", pathEnvironment: nil,
        isExecutable: { _ in false }
    )
    expectEqual(configured, nil, "bad configured path is an error, not a fallback")
}

func testArguments() {
    let id = UUID()
    let newArgs = ClaudeCodeLauncher.arguments(sessionID: id, resumeSessionID: nil)
    expect(newArgs.contains("--session-id"), "new session pins session id")
    expect(newArgs.contains(id.uuidString.lowercased()), "session id value present")
    expect(!newArgs.contains("--resume"), "no resume for new session")

    let resumeArgs = ClaudeCodeLauncher.arguments(sessionID: id, resumeSessionID: "abc-123")
    expect(resumeArgs.contains("--resume"), "resume flag present")
    expect(resumeArgs.contains("abc-123"), "resume id present")
    expect(!resumeArgs.contains("--session-id"), "no session-id when resuming")
    expect(!resumeArgs.contains("--model"), "no model flag by default")

    let modelArgs = ClaudeCodeLauncher.arguments(sessionID: id, resumeSessionID: nil, model: "haiku")
    expect(modelArgs.contains("--model"), "model flag present")
    expect(modelArgs.contains("haiku"), "model alias present")

    // Effort flag, gated on model support.
    let effortArgs = ClaudeCodeLauncher.arguments(sessionID: id, resumeSessionID: nil, model: "fable", effort: "high")
    expect(effortArgs.contains("--effort"), "effort flag present")
    expect(effortArgs.contains("high"), "effort value present")
    let haikuEffort = ClaudeCodeLauncher.arguments(sessionID: id, resumeSessionID: nil, model: "haiku", effort: "high")
    expect(!haikuEffort.contains("--effort"), "no effort flag for haiku")
    expect(ClaudeCodeLauncher.supportsEffort(model: nil), "default model supports effort")
    expect(!ClaudeCodeLauncher.supportsEffort(model: "haiku"), "haiku has no effort")

    expectEqual(ClaudeCodeLauncher.modelOptions.first ?? "x", nil, "first model option is CLI default")

    // Live model-switch control request
    let setModel = StreamJSON.encodeSetModel(requestID: "r1", model: "sonnet")!
    let decodedSetModel = try! JSONSerialization.jsonObject(with: setModel.data(using: .utf8)!) as! [String: Any]
    expectEqual(decodedSetModel["type"] as! String, "control_request", "set_model type")
    expectEqual(decodedSetModel["request_id"] as! String, "r1", "set_model request id")
    let request = decodedSetModel["request"] as! [String: Any]
    expectEqual(request["subtype"] as! String, "set_model", "set_model subtype")
    expectEqual(request["model"] as! String, "sonnet", "set_model model")
}

func testCodexExecutableResolution() {
    let resolved = CodexLauncher.resolveExecutable(
        configuredPath: nil, home: "/Users/t", pathEnvironment: "/bin:/custom",
        isExecutable: { $0 == "/custom/codex" }
    )
    expectEqual(resolved, "/custom/codex", "Codex PATH fallback")

    let known = CodexLauncher.resolveExecutable(
        configuredPath: nil, home: "/Users/t", pathEnvironment: nil,
        isExecutable: { $0 == "/Users/t/.volta/bin/codex" }
    )
    expectEqual(known, "/Users/t/.volta/bin/codex", "Codex well-known path")
}

func testCodexArguments() {
    expectEqual(
        CodexLauncher.modelOptions,
        [nil, "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"],
        "Codex picker exposes only the GPT-5.6 family plus the CLI default"
    )

    let initial = CodexLauncher.arguments(
        prompt: "fix it", resumeSessionID: nil,
        model: "gpt-5.6-sol", effort: "high"
    )
    expectEqual(initial.first, "exec", "Codex uses exec")
    expect(initial.contains("--json"), "Codex JSONL enabled")
    expect(initial.contains("--sandbox"), "new Codex session pins sandbox")
    expect(initial.contains("workspace-write"), "Codex workspace-write sandbox")
    expect(initial.contains("--skip-git-repo-check"), "non-git project directories allowed")
    expect(initial.contains("--model"), "Codex model flag present")
    expect(initial.contains(#"model_reasoning_effort="high""#), "Codex effort config present")
    expectEqual(initial.last, "fix it", "prompt is final argument")

    let resumed = CodexLauncher.arguments(
        prompt: "continue", resumeSessionID: "thread-123"
    )
    expectEqual(Array(resumed.prefix(3)), ["exec", "resume", "thread-123"], "Codex resume syntax")
    expect(!resumed.contains("--sandbox"), "resume uses config instead of unsupported sandbox flag")
    expect(resumed.contains(#"sandbox_mode="workspace-write""#), "resume pins workspace-write sandbox")
    expectEqual(resumed.last, "continue", "follow-up prompt present")
}

func testCodexStreamParsing() {
    let started = #"{"type":"thread.started","thread_id":"0199a213-81c0"}"#
    expectEqual(CodexStreamJSON.parseLine(started), .sessionStarted(sessionID: "0199a213-81c0"), "Codex thread id")

    let message = #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Done."}}"#
    expectEqual(CodexStreamJSON.parseLine(message), .assistantText("Done."), "Codex assistant message")

    let command = #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"swift test","status":"in_progress"}}"#
    expectEqual(CodexStreamJSON.parseLine(command), .toolUse(name: "Shell", summary: "swift test"), "Codex command")

    let edit = #"{"type":"item.completed","item":{"id":"item_2","type":"file_change","changes":[{"path":"Sources/App.swift","kind":"update"}]}}"#
    expectEqual(CodexStreamJSON.parseLine(edit), .toolUse(name: "Edit", summary: "Sources/App.swift"), "Codex file change")

    let completed = #"{"type":"turn.completed","usage":{"input_tokens":10}}"#
    expectEqual(CodexStreamJSON.parseLine(completed), .turnEnded(isError: false, resultText: nil), "Codex turn complete")

    let failed = #"{"type":"turn.failed","error":{"message":"rate limited"}}"#
    expectEqual(CodexStreamJSON.parseLine(failed), .turnEnded(isError: true, resultText: "rate limited"), "Codex turn failure")
}

func testTitleDerivation() {
    expectEqual(ClaudeCodeLauncher.title(fromPrompt: "  fix   the\nlogin bug  "), "fix the login bug", "title collapses whitespace")
    expect(ClaudeCodeLauncher.title(fromPrompt: String(repeating: "word ", count: 40)).count <= 49, "title truncated")
    expectEqual(ClaudeCodeLauncher.title(fromPrompt: "   "), "New agent", "empty prompt fallback")
}

// MARK: - Diff parsing tests

func testDiffParsing() {
    let diff = """
    diff --git a/Sources/main.swift b/Sources/main.swift
    index 1234567..89abcde 100644
    --- a/Sources/main.swift
    +++ b/Sources/main.swift
    @@ -1,3 +1,4 @@
     import Foundation
    -print("old")
    +print("new")
    +print("extra")
    """
    let lines = GitInfo.parseDiff(diff)
    expectEqual(lines[0].kind, .fileHeader, "file header first")
    expectEqual(lines[0].text, "Sources/main.swift", "header shows new path")
    expectEqual(lines[1].kind, .hunk, "hunk after header (meta dropped)")
    expectEqual(lines[2].kind, .context, "context line")
    expectEqual(lines[2].text, "import Foundation", "context prefix stripped")
    expectEqual(lines[3].kind, .remove, "remove line")
    expectEqual(lines[3].text, "print(\"old\")", "remove text stripped")
    expectEqual(lines[4].kind, .add, "add line")
    expectEqual(lines[5].kind, .add, "second add line")
    expectEqual(lines.count, 6, "meta lines dropped")

    expectEqual(GitInfo.parseDiff("").count, 0, "empty diff parses empty")
}

// MARK: - SessionStore tests

func testSessionStorePersistence() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("minimal-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = SessionStore(directory: dir)
    var meta = AgentSessionMeta(
        providerID: "claude-code", providerSessionID: "prov-1",
        title: "Test agent", workingDirectory: "/tmp", state: .running
    )
    store.add(meta)
    store.append(message: ChatMessage(role: .user, text: "hello"), to: meta.id)
    store.append(message: ChatMessage(role: .assistant, text: "hi"), to: meta.id)

    // Reload from disk: running becomes needsInput, transcript intact.
    let reloaded = SessionStore(directory: dir)
    expectEqual(reloaded.sessions.count, 1, "one session restored")
    expectEqual(reloaded.sessions[0].state, .needsInput, "running demoted to needsInput on restore")
    expectEqual(reloaded.sessions[0].providerSessionID, "prov-1", "provider session id restored")
    expectEqual(reloaded.transcript(for: meta.id).count, 2, "transcript restored")
    expectEqual(reloaded.transcript(for: meta.id)[1].text, "hi", "transcript content")

    // Archived sessions leave the panel.
    meta.id = reloaded.sessions[0].id
    reloaded.archive(id: meta.id)
    expectEqual(reloaded.panelSessions.count, 0, "archived leaves panel")
    let again = SessionStore(directory: dir)
    expectEqual(again.sessions[0].state, .archived, "archive persisted")
}

func testPanelOrdering() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("minimal-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir)

    store.add(AgentSessionMeta(providerID: "claude-code", title: "runner", workingDirectory: "/", state: .running))
    store.add(AgentSessionMeta(providerID: "claude-code", title: "waiter", workingDirectory: "/", state: .needsInput))
    store.add(AgentSessionMeta(providerID: "claude-code", title: "gone", workingDirectory: "/", state: .archived))
    store.add(AgentSessionMeta(providerID: "claude-code", title: "broken", workingDirectory: "/", state: .failed))

    let panel = store.panelSessions
    expectEqual(panel.count, 3, "archived excluded")
    expectEqual(panel[0].title, "waiter", "needsInput first")
    expectEqual(panel[1].title, "runner", "running second")
    expectEqual(panel[2].title, "broken", "failed last")
}

// MARK: - Inline trigger tests

func testInlineTokenDetection() {
    // @file mentions
    let atEnd = InlineTrigger.activeToken(text: "look at @src/ma", cursor: 15)
    expectEqual(atEnd, InlineToken(kind: .fileMention, start: 8, end: 15, query: "src/ma"), "@ mention at end")

    let bareAt = InlineTrigger.activeToken(text: "@", cursor: 1)
    expectEqual(bareAt, InlineToken(kind: .fileMention, start: 0, end: 1, query: ""), "bare @ triggers with empty query")

    expectEqual(InlineTrigger.activeToken(text: "a@b c", cursor: 5), nil, "space after @ token ends it")
    expectEqual(InlineTrigger.activeToken(text: "email @\"x", cursor: 9), nil, "quote invalidates @ query")

    // /commands
    let slashStart = InlineTrigger.activeToken(text: "/comp", cursor: 5)
    expectEqual(slashStart, InlineToken(kind: .slashCommand, start: 0, end: 5, query: "comp"), "/ at start")

    let slashInline = InlineTrigger.activeToken(text: "run /rev", cursor: 8)
    expectEqual(slashInline, InlineToken(kind: .slashCommand, start: 4, end: 8, query: "rev"), "/ after whitespace")

    expectEqual(InlineTrigger.activeToken(text: "src/main", cursor: 8), nil, "path slash does not trigger")
    expectEqual(InlineTrigger.activeToken(text: "a/b/c", cursor: 5), nil, "nested path slash does not trigger")

    // Cursor before the trigger sees nothing.
    expectEqual(InlineTrigger.activeToken(text: "hello @file", cursor: 5), nil, "cursor before trigger")
    // @path with slashes still a file mention, not a command.
    let atPath = InlineTrigger.activeToken(text: "@src/ui/view.swift", cursor: 18)
    expectEqual(atPath?.kind, .fileMention, "@ with slashes stays a file mention")
}

func testInlineReplacement() {
    let token = InlineToken(kind: .fileMention, start: 8, end: 15, query: "src/ma")
    expectEqual(
        InlineTrigger.replacingFileMention(text: "look at @src/ma", token: token, path: "src/main.swift"),
        "look at @src/main.swift ",
        "file replacement adds trailing space at end"
    )
    let midToken = InlineToken(kind: .fileMention, start: 0, end: 3, query: "ma")
    expectEqual(
        InlineTrigger.replacingFileMention(text: "@ma then more", token: midToken, path: "main.swift"),
        "@main.swift then more",
        "mid-text replacement keeps the tail, no extra space"
    )
    expectEqual(
        InlineTrigger.replacingFileMention(
            text: "@doc", token: InlineToken(kind: .fileMention, start: 0, end: 4, query: "doc"),
            path: "my docs/notes.md"
        ),
        "@\"my docs/notes.md\" ",
        "paths with spaces get quoted"
    )
    let cmdToken = InlineToken(kind: .slashCommand, start: 0, end: 5, query: "comp")
    expectEqual(
        InlineTrigger.replacingSlashCommand(text: "/comp", token: cmdToken, commandName: "compact"),
        "/compact ",
        "command replacement adds trailing space at end"
    )
}

func testInlineFiltering() {
    let files = ["Sources/UI/Theme.swift", "Sources/Core/StreamJSON.swift", "README.md", "Tests/CoreTests.swift"]
    expectEqual(InlineTrigger.filterFiles(files, query: "stream"), ["Sources/Core/StreamJSON.swift"], "filename match")
    expectEqual(InlineTrigger.filterFiles(files, query: "core"),
                ["Tests/CoreTests.swift", "Sources/Core/StreamJSON.swift"],
                "filename substring beats path-only substring")
    expectEqual(InlineTrigger.filterFiles(files, query: ""), files, "empty query returns head of list")
    expectEqual(InlineTrigger.filterFiles(files, query: "zzz"), [], "no match")

    let commands = [
        SlashCommand(name: "compact", description: "Compact the conversation", argumentHint: ""),
        SlashCommand(name: "review", description: "Review a PR", argumentHint: "[pr]"),
        SlashCommand(name: "commit", description: "Create a git commit", argumentHint: ""),
    ]
    expectEqual(InlineTrigger.filterCommands(commands, query: "com").map(\.name), ["commit", "compact"], "prefix matches sorted by name")
    expectEqual(InlineTrigger.filterCommands(commands, query: "pr").map(\.name), ["review"], "description hit")
    expectEqual(InlineTrigger.filterCommands(commands, query: "").count, 3, "empty query returns all")
}

func testInitializeProtocol() {
    let encoded = StreamJSON.encodeInitialize(requestID: "init-1")!
    let decoded = try! JSONSerialization.jsonObject(with: encoded.data(using: .utf8)!) as! [String: Any]
    expectEqual(decoded["type"] as! String, "control_request", "initialize type")
    expectEqual(decoded["request_id"] as! String, "init-1", "initialize request id")
    expectEqual((decoded["request"] as! [String: Any])["subtype"] as! String, "initialize", "initialize subtype")

    let response = #"{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{"commands":[{"name":"compact","description":"Compact","argumentHint":""},{"name":"review","description":"Review","argumentHint":"[pr]"}]}}}"#
    let commands = StreamJSON.parseInitializeCommands(response, requestID: "init-1")
    expectEqual(commands, [
        SlashCommand(name: "compact", description: "Compact", argumentHint: ""),
        SlashCommand(name: "review", description: "Review", argumentHint: "[pr]"),
    ], "commands parsed")

    expectEqual(StreamJSON.parseInitializeCommands(response, requestID: "other"), nil, "mismatched request id ignored")
    let unrelated = #"{"type":"assistant","message":{}}"#
    expectEqual(StreamJSON.parseInitializeCommands(unrelated, requestID: "init-1"), nil, "unrelated line ignored")
    let errorResponse = #"{"type":"control_response","response":{"subtype":"error","request_id":"init-1","error":"nope"}}"#
    expectEqual(StreamJSON.parseInitializeCommands(errorResponse, requestID: "init-1"), [], "error response yields empty list")
}

// MARK: - Runner

@main
struct TestRunner {
    static func main() {
        testStreamJSONParsing()
        testPermissionProtocol()
        testToolSummaries()
        testPromptEntryFlow()
        testPromptEscapeAndTab()
        testMinimalToggle()
        testManagementNavigation()
        testArchiveConfirmation()
        testConversationMode()
        testProjectPickerFlow()
        testModelPickerFlow()
        testExecutableResolution()
        testArguments()
        testCodexExecutableResolution()
        testCodexArguments()
        testCodexStreamParsing()
        testTitleDerivation()
        testDiffParsing()
        testSessionStorePersistence()
        testPanelOrdering()
        testInlineTokenDetection()
        testInlineReplacement()
        testInlineFiltering()
        testInitializeProtocol()

        if failureCount > 0 {
            print("\(failureCount)/\(testCount) checks FAILED")
            exit(1)
        }
        print("All \(testCount) checks passed")
    }
}
