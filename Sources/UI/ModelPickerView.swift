import SwiftUI

/// Harness + model + thinking-level picker (⌘M), shown in place of the agents card.
/// One flat keyboard list across both sections: Space applies a row and
/// stays open (so both can be set in one visit), Return applies and closes.
struct ModelPickerView: View {
    @EnvironmentObject var controller: MinimalController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionLabel("HARNESS")
                        ForEach(Array(controller.harnessOptions.enumerated()), id: \.offset) { index, harness in
                            row(index: index, title: harness.displayName,
                                subtitle: nil,
                                active: controller.draftHarness == harness)
                        }
                        sectionLabel("MODEL")
                        ForEach(Array(controller.draftModelOptions.enumerated()), id: \.offset) { index, model in
                            row(index: controller.harnessOptions.count + index, title: model ?? "default",
                                subtitle: model == nil ? "your \(controller.draftHarness.displayName) default" : nil,
                                active: controller.draftModel == model)
                        }
                        if controller.modelPickerShowsThinking {
                            sectionLabel("THINKING")
                            ForEach(Array(controller.draftEffortOptions.enumerated()), id: \.offset) { index, effort in
                                row(index: controller.harnessOptions.count + controller.draftModelOptions.count + index,
                                    title: effort ?? "default",
                                    subtitle: nil,
                                    active: controller.draftEffort == effort)
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
            .frame(maxHeight: 360)
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 560) // matches the prompt pill's editing width
        .overlayCard()
    }

    private var header: some View {
        HStack {
            Text("Model")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            KeyHint(symbol: "esc", label: "back")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(index: Int, title: String, subtitle: String?, active: Bool) -> some View {
        let selected = index == controller.modelSelectedIndex
        return HStack(spacing: 8) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular, design: .monospaced))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
            }
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

    private var footer: some View {
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
