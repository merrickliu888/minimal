<div align="center">
  <img src="Assets/minimal-logo-transparent.png" alt="minimal-logo" width="75">  
  <h1>Minimal</h1>
  <p>A simple, macOS native, shortcut driven client for Claude Code and Codex.</p>
</div>

<div align="center">
  <img src="Assets/empty-menu.png" alt="Agent Menu" width="720">
</div>

## Quick Start
1. Install [Claude Code](https://code.claude.com/docs/en/quickstart#step-1-install-claude-code) or [Codex](https://learn.chatgpt.com/docs/codex/cli#getting-started).
2. Download Minimal for [Apple Silicon](https://github.com/merrickliu888/minimal/releases/download/v0.1.0/Minimal-0.1.0-Apple-Silicon.dmg) or [Intel](https://github.com/merrickliu888/minimal/releases/download/v0.1.0/Minimal-0.1.0-Intel.dmg).
3. Open the DMG and drag Minimal into Applications. The app is not signed with an Apple Developer ID, so after macOS blocks the first launch, open **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway**, then confirm **Open**.
4. Grant permissions.
5. `⌥Space` to open the hud.

## Overview

Minimal is a native macOS app for running Claude Code and Codex from a lightweight HUD. Open it from anywhere with a keyboard shortcut, enter a prompt, and get back to your work.

## Features

- **Quick access** - Open the prompt with `⌥Space` and manage agents with `⌥Tab`, or [rebind](#configuration) both.
- **Claude Code and Codex** - Choose the coding agent that fits your task.
- **Voice prompts** - Speak prompts using Apple's on-device speech recognition.

## Configuration

Shortcuts are configurable. Minimal reads `~/.config/minimal/config.toml` at
launch — without one, the defaults below apply. Copy
[`config.example.toml`](config.example.toml) to get started:

```sh
mkdir -p ~/.config/minimal && curl -o ~/.config/minimal/config.toml \
  https://raw.githubusercontent.com/merrickliu888/minimal/main/config.example.toml
```

```toml
[shortcuts]
new_agent = "opt+space"
voice = "cmd+d"
toggle_diff = "cmd+shift+d"
```

Only the lines you write are overridden; everything else keeps its default.
Pick up an edit with **Reload Config** in the menu bar — no restart needed.

| Action | Default | Does |
| --- | --- | --- |
| `new_agent` | `⌥Space` | Open the prompt (works in any app) |
| `manage_agents` | `⌥Tab` | Open the agents panel (works in any app) |
| `settings` | `⌘,` | Open the settings window |
| `voice` | `⌘D` | Start/stop a voice prompt |
| `project_picker` | `⌘P` | Pick the agent's project |
| `model_picker` | `⌘M` | Pick harness, model and thinking level |
| `toggle_terminal` | `` ⌃` `` | Show/hide the terminal pane |
| `toggle_diff` | `⌘⇧D` | Show/hide uncommitted changes |
| `stop_agent` | `⌃C` | Interrupt the running turn |
| `allow_permission` | `⌘Y` | Allow a permission request |
| `deny_permission` | `⌘N` | Deny a permission request |

Values are modifiers and a key joined by `+` (`"cmd+shift+d"`); symbols work
too (`"⌘⇧D"`). Modifiers are `cmd`/`command`, `opt`/`option`/`alt`,
`ctrl`/`control` and `shift`. Keys are letters, digits, `f1`–`f20`,
punctuation, or a name such as `space`, `tab`, `return`, `escape`, `delete` or
an arrow. Each shortcut needs at least one of `cmd`, `opt` or `ctrl`, so a
binding can never swallow ordinary typing. Entries Minimal can't use are
ignored — it keeps that default and explains why in the settings window.

Minimal uses the first file that exists: `$MINIMAL_CONFIG`, then
`~/.config/minimal/config.toml` (`$XDG_CONFIG_HOME` is honoured), then
`~/Library/Application Support/Minimal/config.toml`.

## Privacy

Minimal runs locally on your Mac. Voice transcription uses Apple's on-device Speech framework. The only data sent from your computer is the requests your coding agents make to their LLM providers.

## Gallery

<div align="center">
  <img src="Assets/empty-menu-transcription.png" alt="Voice transcription" width="720">
  <p><em>Voice transcription</em></p>
</div>

<div align="center">
  <img src="Assets/agent-viewer.png" alt="Agent conversation" width="720">
  <p><em>Agent viewer</em></p>
</div>

<div align="center">
  <img src="Assets/agent-viewer-terminal.png" alt="Agent viewer with terminal" width="720">
  <p><em>Agent viewer with terminal</em></p>
</div>

<div align="center">
  <img src="Assets/agent-viewer-diffs.png" alt="Agent viewer with diffs" width="720">
  <p><em>Agent viewer with diffs</em></p>
</div>

## Inspirations
- [Paseo](https://github.com/getpaseo/paseo)
- [FreeFlow](https://github.com/zachlatta/freeflow)
- [Yap](https://github.com/FrigadeHQ/yap)
