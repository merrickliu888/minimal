import AppKit
import Carbon.HIToolbox

extension ShortcutModifiers {

    /// Only the four modifiers a shortcut can use: Caps Lock, Fn and the
    /// numeric-pad flag never take part in matching.
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }

    /// Flags in the shape `RegisterEventHotKey` wants.
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}

extension Shortcut {

    /// Matches when the modifiers are exactly right and the key is either the
    /// one in the US-layout position (how the key code is defined) or the one
    /// that types the same character — so "cmd+d" keeps working on layouts
    /// that move D somewhere else.
    func matches(_ event: NSEvent) -> Bool {
        guard ShortcutModifiers(event.modifierFlags) == modifiers else { return false }
        if event.keyCode == keyCode { return true }
        guard let character,
              let typed = event.charactersIgnoringModifiers?.lowercased(),
              typed.count == 1
        else { return false }
        return typed.first == character
    }
}
