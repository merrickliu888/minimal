import AppKit
import Carbon.HIToolbox
import Foundation

/// Global hotkeys via Carbon RegisterEventHotKey. Unlike an event tap this
/// needs no Accessibility permission, and unlike NSEvent global monitors it
/// consumes the event so Option+Space doesn't also type a non-breaking space
/// into the frontmost app.
final class HotkeyManager {

    enum Hotkey: UInt32, CaseIterable {
        case promptEntry = 1     // new_agent, ⌥Space by default
        case management = 2      // manage_agents, ⌥Tab by default

        /// The configurable action this hotkey is bound to.
        var action: ShortcutAction {
            switch self {
            case .promptEntry: return .newAgent
            case .management: return .manageAgents
            }
        }
    }

    var onHotkey: ((Hotkey) -> Void)?

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?

    func start() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            if let key = Hotkey(rawValue: hotKeyID.id) {
                DispatchQueue.main.async { manager.onHotkey?(key) }
            }
            return noErr
        }
        InstallEventHandler(GetEventDispatcherTarget(), callback, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)

        for hotkey in Hotkey.allCases {
            let shortcut = Shortcuts[hotkey.action]
            register(keyCode: UInt32(shortcut.keyCode), modifiers: shortcut.modifiers.carbonFlags, id: hotkey)
        }
    }

    /// Re-register after config.toml is reloaded.
    func restart() {
        stop()
        start()
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: Hotkey) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x41535354) /* 'ASST' */, id: id.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        if status != noErr {
            NSLog("HotkeyManager: failed to register hotkey \(id) (status \(status))")
        }
        refs.append(ref)
    }

    func stop() {
        for ref in refs.compactMap({ $0 }) { UnregisterEventHotKey(ref) }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
