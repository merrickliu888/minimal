import AppKit
import SwiftTerm
import SwiftUI

/// Per-session shell terminals (SwiftTerm), cached so toggling the pane or
/// reopening a conversation keeps shell state. Shells die with the app; an
/// archived session's shell is terminated explicitly.
@MainActor
final class TerminalCache {
    static let shared = TerminalCache()

    private var views: [UUID: LocalProcessTerminalView] = [:]

    func view(for sessionID: UUID, workingDirectory: String) -> LocalProcessTerminalView {
        if let existing = views[sessionID] { return existing }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 424, height: 560))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // Keep SwiftTerm transparent so the same overlayCard material used by
        // the agent viewer is the only surface rendered behind both panes.
        let background = NSColor.clear
        view.nativeBackgroundColor = background
        // SwiftTerm syncs its backing layer's color only at setup, before we
        // changed the background — left alone it stays black and shows
        // through whenever drawing lags layout (first present, resizes).
        view.layer?.backgroundColor = background.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.nativeForegroundColor = NSColor.textColor
                .usingColorSpace(.sRGB) ?? NSColor.white
        }
        // Hide the embedded scroller outright — the system "Show scroll bars:
        // Always" preference forces a visible track regardless of style, and
        // wheel/trackpad scrollback works through the terminal view itself.
        Self.hideScroller(in: view)
        var env = ProcessInfo.processInfo.environment
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CLAUDE_AGENT_SDK_VERSION"] {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        let shell = env["SHELL"] ?? "/bin/zsh"
        view.startProcess(
            executable: shell,
            args: ["-il"],
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: nil,
            currentDirectory: workingDirectory
        )
        views[sessionID] = view
        return view
    }

    func terminate(sessionID: UUID) {
        views.removeValue(forKey: sessionID)?.process.terminate()
    }

    static func hideScroller(in view: NSView) {
        for subview in view.subviews {
            if let scroller = subview as? NSScroller {
                scroller.isHidden = true
            } else {
                hideScroller(in: subview)
            }
        }
    }

    /// True when the given responder is (inside) a terminal view — those get
    /// raw keys, e.g. Escape must reach vim rather than close the overlay.
    static func isTerminalResponder(_ responder: NSResponder?) -> Bool {
        var current = responder as? NSView
        while let view = current {
            if view is TerminalView { return true }
            current = view.superview
        }
        return false
    }
}

struct TerminalPane: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView { terminalView }
    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        // Re-assert on every update: layout passes can re-run SwiftTerm's
        // setup (re-showing the scroller), and the system appearance may
        // have changed since the cached view was created — the padding
        // around the pane re-resolves each render, so the terminal's own
        // colors must follow the same source or the surfaces mismatch.
        TerminalCache.hideScroller(in: view)
        let background = NSColor.clear
        if view.nativeBackgroundColor != background {
            view.nativeBackgroundColor = background
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.nativeForegroundColor = NSColor.textColor
                    .usingColorSpace(.sRGB) ?? view.nativeForegroundColor
            }
        }
        view.layer?.backgroundColor = background.cgColor
    }
}
