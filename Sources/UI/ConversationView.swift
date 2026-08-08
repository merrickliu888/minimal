import SwiftUI
import Textual

/// Large conversation overlay: the agent's transcript (messages and tool
/// actions, Claude Code style) plus a composer with voice input.
struct ConversationView: View {
    @EnvironmentObject var controller: OverlayController
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var transcriber: Transcriber
    @FocusState private var composerFocused: Bool

    private var sessionID: UUID? { controller.openSessionID }
    private var meta: AgentSessionMeta? { sessionID.flatMap { store.session(id: $0) } }

    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.4)
                transcript
                pendingPermissionBar
                Divider().opacity(0.4)
                composer
            }
            .frame(minWidth: 512, maxWidth: .infinity, minHeight: 392, maxHeight: .infinity)
            .overlayCard(cornerRadius: 14)

            if controller.terminalVisible, let terminal = controller.activeTerminal {
                TerminalPane(terminalView: terminal)
                    .padding(12)
                    .background(Color(nsColor: TerminalCache.resolvedBackground()))
                    .frame(width: 424)
                    .frame(maxHeight: .infinity)
                    .overlayCard(cornerRadius: 14)
            } else if controller.diffVisible {
                DiffViewerView(lines: controller.diffLines, isEmpty: controller.diffIsEmpty)
                    .frame(width: 424)
                    .frame(maxHeight: .infinity)
                    .overlayCard(cornerRadius: 14)
            }
        }
        .padding(24)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if let meta {
                statusDot(for: meta.state)
                Text(meta.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text((meta.workingDirectory as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if let branch = controller.sessionBranch {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                        Text(branch)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            KeyHint(symbol: "esc", label: "back")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(WindowDragArea())
    }

    @ViewBuilder
    private func statusDot(for state: AgentState) -> some View {
        switch state {
        case .running: SpinnerView().frame(width: 12, height: 12)
        case .needsInput: Circle().fill(Theme.accent).frame(width: 8, height: 8)
        case .failed: Circle().fill(Theme.failure).frame(width: 8, height: 8)
        case .archived: Circle().fill(Color.gray).frame(width: 8, height: 8)
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let sessionID {
                        ForEach(store.transcript(for: sessionID)) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: sessionID.map { store.transcript(for: $0).count } ?? 0) {
                if let last = sessionID.flatMap({ store.transcript(for: $0).last }) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let last = sessionID.flatMap({ store.transcript(for: $0).last }) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: Permissions

    @ViewBuilder
    private var pendingPermissionBar: some View {
        if let sessionID,
           let request = controller.coordinator.pendingPermissions(for: sessionID).first {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Allow \(request.toolName)?")
                        .font(.system(size: 12, weight: .semibold))
                    Text(request.summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                KeyHint(symbol: "⌘Y", label: "allow")
                KeyHint(symbol: "⌘N", label: "deny")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.accent.opacity(0.10))
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    controller.composerTranscribing ? "Listening…" : "Reply to the agent…",
                    text: $controller.composerText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($composerFocused)
                .onAppear { composerFocused = true }

                if controller.composerTranscribing {
                    WaveformView(level: transcriber.audioLevel)
                        .frame(width: 60, height: 18)
                }
            }
            HStack(spacing: 12) {
                KeyHint(symbol: "⏎", label: "send")
                KeyHint(symbol: "⇧⏎", label: "newline")
                KeyHint(symbol: "⌘V", label: controller.composerTranscribing ? "stop voice" : "voice")
                KeyHint(symbol: "⌘M", label: "model")
                KeyHint(symbol: "⌃`", label: controller.terminalVisible ? "hide terminal" : "terminal")
                KeyHint(symbol: "⌘⇧D", label: controller.diffVisible ? "hide diff" : "diff")
                Spacer()
                if let meta {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.system(size: 9))
                        Text(meta.model ?? "default")
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundStyle(meta.model == nil ? Theme.textSecondary : Theme.accent)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Message rendering

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: 8) {
                Text(">")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                Text(message.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .assistant:
            // Textual renders the markdown Claude emits (code blocks with
            // syntax highlighting, lists, tables) with native text selection.
            StructuredText(markdown: message.text)
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .tool:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: toolIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 14)
                Text(message.toolName ?? "Tool")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(message.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .system:
            Text(message.text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .error:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.failure)
                Text(message.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.failure)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var toolIcon: String {
        switch message.toolName {
        case "Bash": return "terminal"
        case "Read": return "eye"
        case "Edit", "Write", "MultiEdit": return "pencil"
        case "Grep", "Glob", "WebSearch": return "magnifyingglass"
        case "WebFetch": return "globe"
        case "Task": return "person.2"
        default: return "wrench"
        }
    }
}
