# Assistant

A macOS overlay for creating and managing AI coding agents without leaving
whatever you're doing — a system-wide HUD in the spirit of JARVIS, with the
interaction model of Superhuman: keyboard-first, voice-first, minimal
interruption.

The MVP drives **Claude Code**; the provider layer is an abstraction so other
agents (Codex, …) can be added later.

## What it does

- **⌥Space** from any app: a pill appears at the bottom of your screen and
  immediately starts transcribing your voice (Apple Speech framework). Speak a
  task, or just start typing — the first key you press stops transcription and
  becomes the next character of an editable prompt. **Return** submits: the
  overlay captures a screenshot of your active display as supplemental
  context and starts a new Claude Code session in the background.
- **⌥Tab** from any app: a compact panel appears top-left showing your agents
  in two sections — **Needs Input** (prominent, blue dot) and **Running**
  (spinner) — plus failed ones. Navigate entirely by keyboard.
- Opening an agent shows its conversation — messages and tool actions the way
  Claude Code presents them — with a composer that supports typing and voice.
- Agents that ask a question or want to run a non-allowlisted tool flip to
  **Needs Input**; tool approvals surface as a bar in the conversation
  (**⌘Y** allow / **⌘N** deny).
- Sessions survive app restarts: metadata and transcripts are persisted, and
  replying to a restored agent resumes the underlying Claude Code session
  (`--resume`).

The overlay never activates the app or steals your current app's frontmost
status — panels are non-activating `NSPanel`s that take key focus
Spotlight-style.

## Keyboard model

Global:

| Shortcut | Action |
|---|---|
| ⌥Space | Open overlay in prompt-entry mode, start transcribing |
| ⌥Tab | Open overlay in agent-management mode |

Prompt entry (bottom pill):

| Key | Action |
|---|---|
| ⌥Space | Stop transcription (edit), or restart it |
| any typing key | Stop transcription; key becomes the next character |
| ⏎ | Submit prompt, start agent (with screenshot) |
| ⇥ | Move focus to the agent panel |
| esc | Close the overlay |

Agent management (top-left panel):

| Key | Action |
|---|---|
| ↑ / W | Select previous agent |
| ↓ / S | Select next agent |
| → / D / ⏎ | Open selected agent |
| ← / A | Begin archive confirmation (**A** confirms, **esc**/**D** cancels) |
| esc | Close the overlay |

Open agent (conversation):

| Key | Action |
|---|---|
| typing | Writes into the composer |
| ⏎ | Send message (resumes the session if needed) |
| ⇧⏎ | Newline |
| ⌥Space | Toggle voice input into the composer |
| ⌘Y / ⌘N | Allow / deny a pending tool approval |
| esc | Back to the management panel |

All single-letter shortcuts are interpreted against the current interaction
mode (an explicit state machine, `OverlayInteractionModel`), never globally.

## Build & run

Requirements: macOS 14+, Xcode command-line tools, and a working
[Claude Code](https://claude.com/claude-code) install (`claude` on your PATH
or in a standard location; you must be logged in).

```bash
make            # build build/Assistant.app
make run        # build and launch
make test       # unit tests for the pure core (protocol, state machine, store)
```

No Xcode project — the app is compiled with `swiftc` and the bundle is
assembled by the Makefile (pattern borrowed from FreeFlow). Dev builds are
ad-hoc signed; because TCC permissions are tied to the signature, rebuilding
may re-prompt for permissions unless you set `CODESIGN_IDENTITY` to a real
identity.

### First run

The settings window opens automatically and gates the overlay until:

1. **Microphone**, **Speech Recognition**, and **Screen Recording** are
   granted (each has a Grant / Open Settings button and is re-checked every
   2s — macOS provides no grant notification).
2. **Claude Code** is detected and launches (`claude --version`). A custom
   executable path and the agents' working directory are configurable here.

If a permission is denied the overlay stays disabled; the window explains
what's missing and lets you retry.

## Architecture

```
Sources/
  App.swift                    SwiftUI @main, MenuBarExtra (LSUIElement app)
  AppDelegate.swift            wiring, settings window, activation policy
  HotkeyManager.swift          Carbon RegisterEventHotKey (no Accessibility needed)
  Core/
    AgentModels.swift          AgentProvider/AgentRun abstraction, session + chat models
    ClaudeCodeLauncher.swift   pure: executable discovery, argv, prompt/title building
    ClaudeCodeProvider.swift   process spawn, stream-json pump, teardown
    StreamJSON.swift           pure: wire protocol encode/decode (incl. can_use_tool)
    OverlayInteractionModel.swift  pure keyboard state machine (mode -> commands)
    SessionStore.swift         persistence: sessions.json + per-session transcripts
    AgentCoordinator.swift     live runs <-> store bridge, start/resume/archive
    Transcriber.swift          SFSpeechRecognizer + AVAudioEngine, level metering
    ScreenshotCapturer.swift   ScreenCaptureKit capture of the active display
    PermissionsManager.swift   TCC status, requests, polling
  UI/
    OverlayPanel.swift         non-activating key-capable NSPanel
    OverlayController.swift    panels, key routing, command execution
    PromptPillView.swift       waveform pill <-> editable field
    AgentPanelView.swift       Needs Input / Running / Failed sections
    ConversationView.swift     transcript, approval bar, composer
    SettingsView.swift         onboarding/settings
    Theme.swift                grays, light-blue accent, vibrancy chrome
Tests/
    CoreTests.swift            hand-rolled runner over the pure core (make test)
```

### Claude Code integration

Each session is a `claude -p --input-format stream-json --output-format
stream-json` child process (stdin/stdout JSON lines):

- `system/init` → provider session id (persisted; later used with `--resume`)
- `assistant` text / `tool_use` blocks → transcript rows
- `result` → turn over → **Needs Input** (or **Failed** on `is_error`)
- `control_request` (`can_use_tool`, enabled via `--permission-prompt-tool
  stdio`) → pending approval → **Needs Input**; answered on stdin with
  allow/deny
- The screenshot is sent as a base64 image content block in the first user
  message (downscaled to ≤1568px JPEG), marked as supplemental context.
- `AskUserQuestion` is disallowed so questions arrive as plain text and end
  the turn — which the panel already surfaces as Needs Input.
- Parent-session env vars (`CLAUDECODE`, …) are stripped so the app works
  when launched from inside a Claude Code session during development.

State is never scraped from terminal output; it derives entirely from the
structured stream, and the UI is decoupled from the provider behind
`AgentProvider`/`AgentRun`.

## Known MVP limitations

- ⌥Tab is not yet remappable (no conflict observed with stock macOS).
- Tool approvals allow/deny the specific request only; no "always allow" rules.
- Screenshot temp files in `$TMPDIR` are not garbage-collected.
- One provider (Claude Code); the abstraction is ready for more.
