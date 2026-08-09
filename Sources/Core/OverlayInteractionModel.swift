import Foundation

/// The overlay's explicit interaction states. Keyboard input is interpreted
/// against the current mode — never as globally-sniffed single-letter
/// commands — so the same key can safely mean different things in different
/// modes (e.g. "a" archives in the panel but types into the composer).
enum OverlayMode: Equatable {
    case hidden
    /// Bottom-center prompt pill. `transcribing` == listening to speech;
    /// otherwise the pill is an editable text field.
    case promptEntry(transcribing: Bool)
    /// Agent panel above the pill. `confirmingArchive` == awaiting A / Escape.
    case management(confirmingArchive: Bool)
    /// Recent-projects picker shown in place of the agent panel (⌘P).
    case projectPicker
    /// Full conversation overlay for one agent.
    case conversation
}

/// Normalized input events fed to the interaction model by the UI layer.
enum OverlayInput: Equatable {
    case promptHotkey       // Option+Space (global): toggles the overlay
    case managementHotkey   // Option+Tab (global)
    case voiceKey           // Cmd+D while the overlay is open: toggles voice
    case projectKey         // Cmd+P in prompt entry: toggles the project picker
    case escape
    case returnKey
    case tab
    /// A normal typing key pressed while the prompt pill is transcribing.
    case character(Character)
    // Management-panel navigation (arrows; letters arrive as .character and
    // are normalized here).
    case navUp
    case navDown
    case navOpen
    case navArchive
}

/// Side effects the controller must perform after a transition.
enum OverlayCommand: Equatable {
    case showPromptPill
    case startTranscription
    case stopTranscription
    /// Convert the pill into an editable field; `seed` is the character that
    /// interrupted transcription and becomes the first typed character.
    case beginEditing(seed: Character?)
    case submitPrompt
    case hideOverlay
    case showManagement
    case selectPrevious
    case selectNext
    case openSelected
    case beginArchiveConfirmation
    case confirmArchive
    case cancelArchiveConfirmation
    case closeConversation
    /// Toggle voice input inside the conversation composer.
    case toggleComposerTranscription
    // Project picker.
    case showProjectPicker
    case projectPrevious
    case projectNext
    /// Apply the highlighted project (or open the add-new file picker).
    case chooseProject
}

struct OverlayInteractionModel {
    private(set) var mode: OverlayMode = .hidden

    mutating func handle(_ input: OverlayInput) -> [OverlayCommand] {
        switch mode {
        case .hidden:
            switch input {
            case .promptHotkey:
                // Text entry is the default; ⌥Space again toggles voice.
                mode = .promptEntry(transcribing: false)
                return [.showPromptPill, .beginEditing(seed: nil)]
            case .managementHotkey:
                mode = .management(confirmingArchive: false)
                return [.showManagement]
            default:
                return []
            }

        case .promptEntry(let transcribing):
            switch input {
            case .promptHotkey:
                // ⌥Space toggles the overlay: pressing it again closes.
                mode = .hidden
                return transcribing
                    ? [.stopTranscription, .hideOverlay]
                    : [.hideOverlay]
            case .voiceKey:
                if transcribing {
                    mode = .promptEntry(transcribing: false)
                    return [.stopTranscription, .beginEditing(seed: nil)]
                } else {
                    mode = .promptEntry(transcribing: true)
                    return [.startTranscription]
                }
            case .character(let c) where transcribing:
                mode = .promptEntry(transcribing: false)
                return [.stopTranscription, .beginEditing(seed: c)]
            case .returnKey:
                // Submission opens the new agent's conversation rather than
                // closing the overlay, so the user sees it start working.
                mode = .conversation
                return transcribing
                    ? [.stopTranscription, .submitPrompt]
                    : [.submitPrompt]
            case .escape:
                mode = .hidden
                return transcribing
                    ? [.stopTranscription, .hideOverlay]
                    : [.hideOverlay]
            case .tab:
                mode = .management(confirmingArchive: false)
                return transcribing
                    ? [.stopTranscription, .showManagement]
                    : [.showManagement]
            case .managementHotkey:
                mode = .management(confirmingArchive: false)
                return transcribing
                    ? [.stopTranscription, .showManagement]
                    : [.showManagement]
            case .projectKey:
                mode = .projectPicker
                return transcribing
                    ? [.stopTranscription, .showProjectPicker]
                    : [.showProjectPicker]
            default:
                return []
            }

        case .projectPicker:
            switch input {
            case .navUp:
                return [.projectPrevious]
            case .navDown:
                return [.projectNext]
            case .character(let c):
                switch c.lowercased() {
                case "e": return [.projectPrevious]
                case "d": return [.projectNext]
                case " ":
                    mode = .promptEntry(transcribing: false)
                    return [.chooseProject, .beginEditing(seed: nil)]
                default: return []
                }
            case .navOpen, .returnKey:
                mode = .promptEntry(transcribing: false)
                return [.chooseProject, .beginEditing(seed: nil)]
            case .escape, .tab, .projectKey:
                mode = .promptEntry(transcribing: false)
                return [.beginEditing(seed: nil)]
            case .promptHotkey:
                mode = .hidden
                return [.hideOverlay]
            case .managementHotkey:
                mode = .management(confirmingArchive: false)
                return [.showManagement]
            default:
                return []
            }

        case .management(let confirming):
            if confirming {
                switch input {
                case .character(let c) where c.lowercased() == "a":
                    mode = .management(confirmingArchive: false)
                    return [.confirmArchive]
                case .character(let c) where c.lowercased() == "d":
                    mode = .management(confirmingArchive: false)
                    return [.cancelArchiveConfirmation]
                case .escape, .navOpen:
                    mode = .management(confirmingArchive: false)
                    return [.cancelArchiveConfirmation]
                default:
                    return []
                }
            }
            switch input {
            case .navUp:
                return [.selectPrevious]
            case .navDown:
                return [.selectNext]
            case .navOpen:
                mode = .conversation
                return [.openSelected]
            case .navArchive:
                mode = .management(confirmingArchive: true)
                return [.beginArchiveConfirmation]
            case .character(let c):
                switch c.lowercased() {
                case "e": return [.selectPrevious]
                case "d": return [.selectNext]
                case " ":
                    mode = .conversation
                    return [.openSelected]
                case "a":
                    mode = .management(confirmingArchive: true)
                    return [.beginArchiveConfirmation]
                default: return []
                }
            case .escape, .managementHotkey:
                mode = .hidden
                return [.hideOverlay]
            case .promptHotkey:
                // ⌥Space toggles the overlay closed from anywhere.
                mode = .hidden
                return [.hideOverlay]
            case .tab:
                // Tab cycles focus back to the prompt field (draft intact —
                // the pill stays visible while the panel has focus).
                mode = .promptEntry(transcribing: false)
                return [.beginEditing(seed: nil)]
            default:
                return []
            }

        case .conversation:
            switch input {
            case .escape, .tab:
                mode = .management(confirmingArchive: false)
                return [.closeConversation, .showManagement]
            case .promptHotkey:
                mode = .hidden
                return [.hideOverlay]
            case .voiceKey:
                return [.toggleComposerTranscription]
            case .managementHotkey:
                mode = .management(confirmingArchive: false)
                return [.closeConversation, .showManagement]
            default:
                return []
            }
        }
    }

    /// Used when the conversation UI itself changes mode (e.g. opening an
    /// agent from a click) or when the controller must force a state.
    mutating func forceMode(_ newMode: OverlayMode) {
        mode = newMode
    }
}
