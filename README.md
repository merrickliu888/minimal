<div align="center">
  <img src="Assets/minimal-logo-transparent.png" alt="minimal-logo" width="75">  
  <h1>Minimal</h1>
  <p>A simple, shortcut driven client for Claude Code and Codex.</p>
</div>

A macOS overlay for creating and managing AI coding agents without leaving
whatever you're doing — a system-wide HUD in the spirit of JARVIS, with the
interaction model of Superhuman: keyboard-first, voice-first, minimal
interruption.

Minimal drives **Codex** and **Claude Code** through a shared provider layer.

## What it does

- **⌥Space** from any app toggles the overlay: a prompt field appears at the
  bottom of your screen, ready to type into (⌥Space again closes it). Press
  **⌘D** to toggle voice transcription (Apple Speech framework) — spoken text
  appends to whatever you've typed, and typing any key while listening stops
  transcription and keeps going from the keyboard. **Return** submits: the
  overlay starts a new session in the selected harness and opens its conversation so you
  can watch it work.
- **⌥Tab** from any app: a compact panel appears top-left showing your agents
  in two sections — **Needs Input** (prominent, blue dot) and **Running**
  (spinner) — plus failed ones. Navigate entirely by keyboard.
- Opening an agent shows its conversation — messages and tool actions in a
  compact structured transcript — with a composer that supports typing and voice.
- Agents that ask a question or want to run a non-allowlisted tool flip to
  **Needs Input**; tool approvals surface as a bar in the conversation
  (**⌘Y** allow / **⌘N** deny).
- Sessions survive app restarts: metadata and transcripts are persisted, and
  replying to a restored agent resumes the underlying Codex or Claude Code
  session.

The overlay never activates the app or steals your current app's frontmost
status — panels are non-activating `NSPanel`s that take key focus
Spotlight-style.

## Keyboard model

Global:

| Shortcut | Action |
|---|---|
| ⌥Space | Toggle the overlay (opens in prompt-entry mode, text input focused; closes from any mode) |
| ⌥Tab | Open overlay in agent-management mode |
| ⌘, | Open Settings (while the overlay is visible) |

Prompt entry (bottom pill):

| Key | Action |
|---|---|
| ⌘D | Toggle voice transcription (appends to typed text) |
| ⌘P | Open the Projects picker in place of the agents card: recent directories navigated with E/D/arrows, Space/⏎ selects, and an "Add new project…" row opens the system directory picker. Esc or ⌘P closes it |
| ⌘M | Open the Model tab: pick the harness (Codex or Claude Code), model, and supported thinking level. E/D/arrows navigate, Space applies and stays open, ⏎ applies and closes, esc/⌘M closes |
| any typing key | While listening: stop transcription, keep typing |
| ⏎ | Submit prompt, start agent, open its conversation |
| ⇥ | Move focus to the agent panel |
| esc | Close the overlay |

Agent management (top-left panel):

| Key | Action |
|---|---|
| ↑ / E | Select previous agent |
| ↓ / D | Select next agent |
| → / Space / ⏎ | Open selected agent |
| ← / A | Begin archive confirmation (**A** confirms, **esc**/**D** cancels) |
| ⇥ | Cycle focus back to the prompt field (draft preserved) |
| esc | Close the overlay |

Open agent (conversation):

| Key | Action |
|---|---|
| typing | Writes into the composer |
| ⏎ | Send message (resumes the session if needed) |
| ⇧⏎ | Newline |
| ⌘D | Toggle voice input into the composer |
| ⌘Y / ⌘N | Allow / deny a pending tool approval |
| ⌃C | Interrupt the running turn (session stays alive) |
| ⌘M | Open the session's model/thinking picker. The compact chip remains model + thinking level; it does not show the harness |
| ⌃` | Toggle a shell terminal pane beside the conversation (opens in the agent's working directory; keeps shell state per session) |
| ⌘⇧D | Toggle a diff pane showing uncommitted changes in the agent's directory (shares the side slot with the terminal) |
| esc / ⇥ | Back to the management panel |
| ⌥Space | Close the overlay |

While the terminal pane has focus, all keys go to the shell (Escape reaches
vim, etc.) — only ⌃` is intercepted, to toggle back.

All single-letter shortcuts are interpreted against the current interaction
mode (an explicit state machine, `MinimalInteractionModel`), never globally.

## Build & run

Requirements: macOS 14+, Xcode command-line tools, and at least one working
coding harness: [Codex CLI](https://developers.openai.com/codex/cli) (`codex`)
or [Claude Code](https://claude.com/claude-code) (`claude`). The selected CLI
must be installed and logged in.

```bash
make            # build build/Minimal.app
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

1. **Microphone** and **Speech Recognition** are granted (each has a Grant /
   Open Settings button and is re-checked every 2s — macOS provides no grant
   notification).
2. At least one coding harness is detected and launches (`codex --version` or
   `claude --version`). Custom executable paths and the agents' working
   directory are configurable here.

If a permission is denied the overlay stays disabled; the window explains
what's missing and lets you retry.