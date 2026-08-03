import AppKit
import SwiftUI

/// Borderless, non-activating panel that CAN become key: it receives typed
/// text while the previously frontmost app stays active (Spotlight-style).
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false // shadows drawn in SwiftUI so the clear margins don't cast
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
    }

    func setRootView<V: View>(_ view: V) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    /// Show on the given screen at a frame computed by `position`, and take
    /// key focus without activating the app.
    func present(on screen: NSScreen, frame: NSRect) {
        setFrame(frame, display: true)
        alphaValue = 1
        orderFrontRegardless()
        makeKey()
    }

    func dismiss() {
        orderOut(nil)
        // orderOut alone leaves the SwiftUI hierarchy mounted and animating;
        // unmount so repeat-forever animations stop flushing Core Animation.
        // The hosting view is rebuilt by setRootView on the next present.
        contentView = NSView()
    }
}
