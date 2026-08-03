import AppKit
import Carbon.HIToolbox
import Foundation

/// Global hotkeys via Carbon RegisterEventHotKey. Unlike an event tap this
/// needs no Accessibility permission, and unlike NSEvent global monitors it
/// consumes the event so Option+Space doesn't also type a non-breaking space
/// into the frontmost app.
final class HotkeyManager {

    enum Hotkey: UInt32 {
        case promptEntry = 1     // Option+Space
        case management = 2      // Option+Tab
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

        register(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), id: .promptEntry)
        register(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey), id: .management)
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
