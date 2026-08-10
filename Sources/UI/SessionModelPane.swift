import SwiftUI

/// Model/thinking picker for the OPEN session, shown in the conversation's
/// side slot (⌘M). ↑/↓ navigate, ⏎ applies and closes, esc closes — letters
/// keep typing into the composer. Model changes apply live; the thinking
/// level applies when the session next restarts/resumes.
struct SessionModelPane: View {
    @EnvironmentObject var controller: OverlayController
    @EnvironmentObject var store: SessionStore

    private var meta: AgentSessionMeta? {
        controller.openSessionID.flatMap { store.session(id: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Model")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                KeyHint(symbol: "esc", label: "close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider().opacity(0.4)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionLabel("MODEL — applies immediately")
                        ForEach(Array(controller.sessionConcreteModels.enumerated()), id: \.offset) { index, model in
                            row(index: index, title: model, active: meta?.model == model)
                        }
                        if controller.sessionPaneShowsThinking {
                            sectionLabel("THINKING — applies on next restart")
                            ForEach(Array(controller.sessionEffortOptions.enumerated()), id: \.offset) { index, effort in
                                row(index: controller.sessionConcreteModels.count + index,
                                    title: effort ?? "default",
                                    active: meta?.effort == effort)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: controller.modelSelectedIndex) { _, index in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }

            Divider().opacity(0.4)
            HStack(spacing: 12) {
                KeyHint(symbol: "E/D", label: "navigate")
                KeyHint(symbol: "␣", label: "apply")
                KeyHint(symbol: "⏎", label: "apply & close")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(index: Int, title: String, active: Bool) -> some View {
        let selected = index == controller.modelSelectedIndex
        return HStack(spacing: 8) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular, design: .monospaced))
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .id(index)
    }
}
