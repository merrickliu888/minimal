import SwiftUI

/// Agent management card shown directly above the prompt pill: Needs Input
/// and Running sections with keyboard-driven selection, archive confirmation
/// inline.
struct AgentPanelView: View {
    @EnvironmentObject var controller: OverlayController
    @EnvironmentObject var store: SessionStore

    private var isFocused: Bool {
        if case .management = controller.mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            if store.panelSessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 560) // matches the prompt pill's editing width
        .overlayCard()
    }

    private var header: some View {
        HStack {
            Text("Agents")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !isFocused {
                KeyHint(symbol: "⇥", label: "focus")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 20))
                .foregroundStyle(Theme.textSecondary)
            Text("No active agents")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Text("⌥Space to start one")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var sessionList: some View {
        let sessions = store.panelSessions
        let needsInput = sessions.filter { $0.state == .needsInput }
        let running = sessions.filter { $0.state == .running }
        let failed = sessions.filter { $0.state == .failed }

        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !needsInput.isEmpty {
                    sectionLabel("NEEDS INPUT")
                    ForEach(needsInput) { row(for: $0, in: sessions) }
                }
                if !running.isEmpty {
                    sectionLabel("RUNNING")
                    ForEach(running) { row(for: $0, in: sessions) }
                }
                if !failed.isEmpty {
                    sectionLabel("FAILED")
                    ForEach(failed) { row(for: $0, in: sessions) }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 320)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(for session: AgentSessionMeta, in sessions: [AgentSessionMeta]) -> some View {
        let index = sessions.firstIndex(of: session) ?? 0
        let selected = isFocused && index == min(controller.selectedIndex, sessions.count - 1)
        let confirming = controller.confirmingArchiveID == session.id

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                statusIndicator(for: session.state)
                Text(session.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            if let detail = session.statusDetail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, 20)
            }
            if confirming {
                HStack(spacing: 10) {
                    Text("Archive this agent?")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.failure)
                    KeyHint(symbol: "A", label: "confirm")
                    KeyHint(symbol: "esc", label: "cancel")
                }
                .padding(.leading, 20)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.22) : .clear)
                .padding(.horizontal, 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.75) : .clear, lineWidth: 1)
                .padding(.horizontal, 6)
        )
    }

    @ViewBuilder
    private func statusIndicator(for state: AgentState) -> some View {
        switch state {
        case .running:
            SpinnerView()
                .frame(width: 12, height: 12)
        case .needsInput:
            Circle()
                .fill(Theme.accent)
                .frame(width: 8, height: 8)
                .padding(2)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.failure)
        case .archived:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            KeyHint(symbol: "E/D", label: "navigate")
            KeyHint(symbol: "␣", label: "open")
            KeyHint(symbol: "A", label: "archive")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Small indeterminate spinner that reads well on vibrancy.
struct SpinnerView: View {
    @State private var spinning = false
    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1.0)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
