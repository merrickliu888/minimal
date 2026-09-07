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
    expect(initial.contains(#"approval_policy="on-request""#), "Codex uses Auto approval policy")
    expect(!initial.contains(#"approval_policy="never""#), "Codex no longer disables approvals")
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
    expect(resumed.contains(#"approval_policy="on-request""#), "resume preserves Auto approval policy")
    expectEqual(resumed.last, "continue", "follow-up prompt present")

    let titleArgs = CodexLauncher.titleGenerationArguments(forPrompt: "fix login")
    expectEqual(titleArgs.first, "exec", "Codex title generation uses exec")
    expect(titleArgs.contains("--ephemeral"), "Codex title session is not persisted")
    expect(titleArgs.contains("--ignore-user-config"), "Codex title ignores user config")
    expect(titleArgs.contains("--ignore-rules"), "Codex title ignores project instructions")
    expect(titleArgs.contains("read-only"), "Codex title generation uses read-only sandbox")
    expect(titleArgs.contains("gpt-5.6-luna"), "Codex title generation uses fast model")
    expect(titleArgs.contains(#"model_reasoning_effort="low""#), "Codex title generation uses low effort")
    expect(titleArgs.last?.contains("User prompt: fix login") == true, "title prompt includes task prompt")

    expectEqual(CodexLauncher.generatedTitle(from: "  \"Fix login flow.\"\n"), "Fix login flow", "Codex title output normalized")
    expectEqual(CodexLauncher.generatedTitle(from: ""), nil, "empty Codex title rejected")
    expectEqual(CodexLauncher.generatedTitle(from: "first\nsecond"), nil, "multiline Codex title rejected")
    expectEqual(CodexLauncher.generatedTitle(from: String(repeating: "x", count: 65)), nil, "long Codex title rejected")
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

// MARK: - Transcript link tests

func testTranscriptFileLinks() {
    let workingDirectory = "/Users/example/project"
    let markdown = "[App.swift](/Users/example/project/Sources/App.swift)"
    let rendered = try! AttributedString(
        markdown: markdown,
        baseURL: TranscriptLinks.baseURL(workingDirectory: workingDirectory)
    )
    let link = rendered.runs.compactMap(\.link).first

    expectEqual(link?.scheme, "file", "absolute transcript path uses the file URL scheme")
    expectEqual(link?.path, "/Users/example/project/Sources/App.swift", "file link keeps its absolute path")
}

func testTranscriptFileLinkOpening() {
    let fileURL = URL(fileURLWithPath: "/Users/example/project/Sources/App.swift")
    var openedURL: URL?
    let result = TranscriptLinks.open(fileURL) { url in
        openedURL = url
        return true
    }

    expectEqual(result, .handled, "file link reports that the click was handled")
    expectEqual(openedURL, fileURL, "file link is sent to the workspace opener")

    let webURL = URL(string: "https://example.com")!
    let webResult = TranscriptLinks.open(webURL) { _ in
        expect(false, "web links should not be sent to the file opener")
        return true
    }
    expectEqual(webResult, .systemAction, "web links keep SwiftUI system handling")
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

// MARK: - Config file / shortcuts tests

func testTOMLParsing() {
    let document = try! TOML.parse("""
    # a comment
    top = "level"

    [shortcuts]  # trailing comment
    voice = "cmd+d"   # another
    empty_ok = ''
    escaped = "a\\"b"
    literal = 'raw\\value'
    bare = 42

    [other.nested]
    key = "value"
    """)
    expectEqual(document[""]?["top"], "level", "root table key")
    expectEqual(document["shortcuts"]?["voice"], "cmd+d", "table key with comment")
    expectEqual(document["shortcuts"]?["empty_ok"], "", "empty literal string")
    expectEqual(document["shortcuts"]?["escaped"], "a\"b", "escaped quote")
    expectEqual(document["shortcuts"]?["literal"], "raw\\value", "literal string keeps backslash")
    expectEqual(document["shortcuts"]?["bare"], "42", "bare value")
    expectEqual(document["other.nested"]?["key"], "value", "dotted table name")

    // Dotted keys land in the table they name.
    let dotted = try! TOML.parse("shortcuts.voice = \"cmd+j\"")
    expectEqual(dotted["shortcuts"]?["voice"], "cmd+j", "dotted key")

    func failure(_ text: String) -> Int? {
        do { _ = try TOML.parse(text); return nil }
        catch let error as TOML.ParseError { return error.line }
        catch { return -1 }
    }
    expectEqual(failure("[shortcuts\nvoice = \"cmd+d\""), 1, "unterminated header")
    expectEqual(failure("voice"), 1, "missing '='")
    expectEqual(failure("voice ="), 1, "missing value")
    expectEqual(failure("voice = \"cmd+d"), 1, "unterminated string")
    expectEqual(failure("voice = \"a\" junk"), 1, "trailing junk")
    expectEqual(failure("[shortcuts]\nvoice = \"a\"\nvoice = \"b\""), 3, "duplicate key")
    expectEqual(failure("keys = [1, 2]\n"), nil, "arrays parse as opaque bare values")
}

func testShortcutParsing() {
    expectEqual(try! Shortcut.parse("cmd+d"), Shortcut(2, [.command]), "cmd+d")
    expectEqual(try! Shortcut.parse("  CMD + Shift + D "), Shortcut(2, [.command, .shift]), "spacing and case")
    expectEqual(try! Shortcut.parse("⌘⇧D"), Shortcut(2, [.command, .shift]), "symbol spelling")
    expectEqual(try! Shortcut.parse("opt+space"), Shortcut(49, [.option]), "opt+space")
    expectEqual(try! Shortcut.parse("option+tab"), Shortcut(48, [.option]), "option+tab")
    expectEqual(try! Shortcut.parse("alt+tab"), Shortcut(48, [.option]), "alt alias")
    expectEqual(try! Shortcut.parse("ctrl+`"), Shortcut(50, [.control]), "ctrl+backtick")
    expectEqual(try! Shortcut.parse("control+backtick"), Shortcut(50, [.control]), "named backtick")
    expectEqual(try! Shortcut.parse("cmd+,"), Shortcut(43, [.command]), "cmd+comma")
    expectEqual(try! Shortcut.parse("cmd+ctrl+f5"), Shortcut(96, [.command, .control]), "function key")

    func error(_ text: String) -> ShortcutParseError? {
        do { _ = try Shortcut.parse(text); return nil }
        catch let error as ShortcutParseError { return error }
        catch { return nil }
    }
    expectEqual(error(""), .empty, "empty string")
    expectEqual(error("cmd"), .missingKey, "modifiers only")
    expectEqual(error("cmd+zz"), .unknownKey("zz"), "unknown key")
    expectEqual(error("cmd+d+e"), .multipleKeys("d", "e"), "two keys")
    expect(error("cmd++") != nil, "trailing separator is an error")

    // Displays match the hints the app has always shown.
    expectEqual(ShortcutAction.newAgent.defaultShortcut.display, "⌥Space", "⌥Space display")
    expectEqual(ShortcutAction.manageAgents.defaultShortcut.display, "⌥Tab", "⌥Tab display")
    expectEqual(ShortcutAction.toggleDiff.defaultShortcut.display, "⌘⇧D", "⌘⇧D display")
    expectEqual(ShortcutAction.toggleTerminal.defaultShortcut.display, "⌃`", "⌃` display")
    expectEqual(ShortcutAction.allowPermission.defaultShortcut.display, "⌘Y", "⌘Y display")
    expectEqual(ShortcutAction.settings.defaultShortcut.display, "⌘,", "⌘, display")
    expectEqual(try! Shortcut.parse("cmd+return").display, "⌘⏎", "return display")

    // No two defaults collide, and every key name round-trips to its code.
    var seenDefaults: Set<Shortcut> = []
    for action in ShortcutAction.allCases {
        expect(seenDefaults.insert(action.defaultShortcut).inserted,
               "\(action.rawValue) has its own default shortcut")
    }
    for key in Shortcut.keys {
        for name in key.names {
            expectEqual(Shortcut.codesByName[name], key.code, "name '\(name)' maps to its key")
        }
    }
}

func testShortcutConfigOverrides() {
    let config = ShortcutConfig.parse(toml: """
    [shortcuts]
    new_agent = "ctrl+opt+space"
    voice = "cmd+j"
    toggle_diff = "⌘⇧G"
    """)
    expect(config.warnings.isEmpty, "clean config has no warnings: \(config.warnings)")
    expectEqual(config[.newAgent], Shortcut(49, [.control, .option]), "global override")
    expectEqual(config[.voice], Shortcut(38, [.command]), "voice override")
    expectEqual(config[.toggleDiff], Shortcut(5, [.command, .shift]), "diff override")
    // Untouched actions keep their defaults.
    expectEqual(config[.manageAgents], ShortcutAction.manageAgents.defaultShortcut, "default kept")
    expectEqual(config[.stopAgent], ShortcutAction.stopAgent.defaultShortcut, "default kept")

    // An empty or shortcut-less file is exactly the defaults.
    let empty = ShortcutConfig.parse(toml: "")
    for action in ShortcutAction.allCases {
        expectEqual(empty[action], action.defaultShortcut, "\(action.rawValue) defaults")
    }
    expect(empty.warnings.isEmpty, "empty config is silent")
}

func testShortcutConfigRejectsBadEntries() {
    let config = ShortcutConfig.parse(toml: """
    [shortcuts]
    voice = "not+a+key"
    model_picker = "j"
    nonsense = "cmd+k"
    stop_agent = "cmd+k"
    project_picker = "cmd+k"

    [colours]
    accent = "red"
    """)
    // Bad values fall back rather than dropping the binding.
    expectEqual(config[.voice], ShortcutAction.voice.defaultShortcut, "unparsable value falls back")
    expectEqual(config[.modelPicker], ShortcutAction.modelPicker.defaultShortcut, "bare key falls back")
    expectEqual(config[.stopAgent], Shortcut(40, [.command]), "valid value applied")
    expect(config.warnings.contains(where: { $0.contains("not+a+key") }), "warns about the bad value")
    expect(config.warnings.contains(where: { $0.contains("modifier") }), "warns a modifier is required")
    expect(config.warnings.contains(where: { $0.contains("nonsense") }), "warns about an unknown action")
    expect(config.warnings.contains(where: { $0.contains("[colours]") }), "warns about an unknown section")
    expect(config.warnings.contains(where: { $0.contains("⌘K") }), "warns about the duplicate binding")

    // Invalid TOML keeps every default instead of half-applying the file.
    let broken = ShortcutConfig.parse(toml: "[shortcuts]\nvoice = ")
    expectEqual(broken[.voice], ShortcutAction.voice.defaultShortcut, "broken file keeps defaults")
    expectEqual(broken.warnings.count, 1, "broken file reports once")
}

func testShortcutConfigLoading() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("minimal-config-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let missing = directory.appendingPathComponent("missing.toml")
    let present = directory.appendingPathComponent("config.toml")
    try! "[shortcuts]\nvoice = \"cmd+j\"\n".write(to: present, atomically: true, encoding: .utf8)

    // No file anywhere: defaults, and no source to show in Settings.
    let absent = ShortcutConfig.load(searchPaths: [missing])
    expectEqual(absent[.voice], ShortcutAction.voice.defaultShortcut, "no config = defaults")
    expect(absent.source == nil, "no config = no source")

    // First existing path in the list wins.
    let loaded = ShortcutConfig.load(searchPaths: [missing, present])
    expectEqual(loaded[.voice], Shortcut(38, [.command]), "loads the first file that exists")
    expectEqual(loaded.source, present, "records where it came from")

    // Search order: the env override beats ~/.config, which beats
    // Application Support.
    let paths = ShortcutConfig.searchPaths(
        environment: ["MINIMAL_CONFIG": "~/elsewhere.toml", "XDG_CONFIG_HOME": "/xdg"],
        home: "/Users/test")
    expectEqual(paths.map(\.path), [
        "/Users/test/elsewhere.toml",
        "/xdg/minimal/config.toml",
        "/Users/test/Library/Application Support/Minimal/config.toml",
    ], "search order")
    expectEqual(
        ShortcutConfig.userConfigPath(environment: [:], home: "/Users/test").path,
        "/Users/test/.config/minimal/config.toml", "default config path")
}

func testShortcutConfigTemplate() {
    // Every default round-trips through the spelling the template writes, so
    // a line the user uncomments is a line Minimal can read back.
    for action in ShortcutAction.allCases {
        let spelling = action.defaultShortcut.configSpelling
        expectEqual(try! Shortcut.parse(spelling), action.defaultShortcut,
                    "\(action.rawValue) spelling '\(spelling)' round-trips")
    }
    expectEqual(Shortcut(2, [.command, .shift]).configSpelling, "cmd+shift+d", "modifier order")
    expectEqual(Shortcut(50, [.control]).configSpelling, "ctrl+`", "punctuation key")
    expectEqual(Shortcut(49, [.option]).configSpelling, "opt+space", "named key")

    let template = ShortcutConfig.template

    // Shipped as written, the file changes nothing: every binding is
    // commented, so defaults stay live and no warning is raised.
    let seeded = ShortcutConfig.parse(toml: template)
    expect(seeded.warnings.isEmpty, "template parses without warnings")
    for action in ShortcutAction.allCases {
        expectEqual(seeded[action], action.defaultShortcut,
                    "\(action.rawValue) keeps its default in the shipped template")
    }

    // Uncommenting every binding must still yield exactly the defaults —
    // that is what proves the file documents what the app actually does.
    let uncommented = template
        .components(separatedBy: .newlines)
        .map { line -> String in
            guard line.hasPrefix("# ") else { return line }
            let body = String(line.dropFirst(2))
            guard let equals = body.firstIndex(of: "="),
                  body[body.startIndex..<equals].allSatisfy({ $0.isLowercase || $0 == "_" || $0 == " " })
            else { return line }
            return body
        }
        .joined(separator: "\n")
    let live = ShortcutConfig.parse(toml: uncommented)
    expect(live.warnings.isEmpty, "uncommented template parses without warnings")
    for action in ShortcutAction.allCases {
        expectEqual(live[action], action.defaultShortcut,
                    "\(action.rawValue) matches its default when uncommented")
        expect(template.contains(action.rawValue), "template lists \(action.rawValue)")
        expect(template.contains(action.summary), "template explains \(action.rawValue)")
    }
}

func testShortcutConfigSeeding() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("minimal-seed-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("minimal/config.toml")

    // Nothing on disk: the template is written, intermediate directories and
    // all, and it loads back as the defaults.
    let written = ShortcutConfig.seedUserConfigIfMissing(searchPaths: [destination], destination: destination)
    expectEqual(written, destination, "seeds when no config exists")
    expectEqual(try? String(contentsOf: destination, encoding: .utf8), ShortcutConfig.template,
                "writes the template verbatim")
    expectEqual(ShortcutConfig.load(searchPaths: [destination])[.voice],
                ShortcutAction.voice.defaultShortcut, "a seeded file is a no-op config")

    // Seeding is once-only: an edited file is never overwritten.
    try! "[shortcuts]\nvoice = \"cmd+j\"\n".write(to: destination, atomically: true, encoding: .utf8)
    expect(ShortcutConfig.seedUserConfigIfMissing(searchPaths: [destination], destination: destination) == nil,
           "leaves an existing config alone")
    expectEqual(ShortcutConfig.load(searchPaths: [destination])[.voice], Shortcut(38, [.command]),
                "the user's edit survives")

    // A config found anywhere in the search order counts, so seeding never
    // drops a second file next to a $MINIMAL_CONFIG that is already in use.
    let elsewhere = directory.appendingPathComponent("elsewhere.toml")
    expect(ShortcutConfig.seedUserConfigIfMissing(searchPaths: [destination], destination: elsewhere) == nil,
           "an earlier search path suppresses seeding")
    expect(!FileManager.default.fileExists(atPath: elsewhere.path), "nothing written next to it")
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
        testTranscriptFileLinks()
        testTranscriptFileLinkOpening()
        testInitializeProtocol()
        testTOMLParsing()
        testShortcutParsing()
        testShortcutConfigOverrides()
        testShortcutConfigRejectsBadEntries()
        testShortcutConfigLoading()
        testShortcutConfigTemplate()
        testShortcutConfigSeeding()

        if failureCount > 0 {
            print("\(failureCount)/\(testCount) checks FAILED")
            exit(1)
        }
        print("All \(testCount) checks passed")
    }
}
