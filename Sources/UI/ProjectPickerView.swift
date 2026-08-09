import SwiftUI

/// Recent-projects picker (⌘P), shown in place of the agents card and
/// navigated with the same keys. The trailing row opens the system picker
/// for a directory that isn't in the list yet.
struct ProjectPickerView: View {
    @EnvironmentObject var controller: OverlayController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            projectList
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 560) // matches the prompt pill's editing width
        .overlayCard()
    }

    private var header: some View {
        HStack {
            Text("Projects")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            KeyHint(symbol: "esc", label: "back")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var projectList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(controller.recentProjects.enumerated()), id: \.offset) { index, path in
                    row(index: index) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(currentPath == path ? Theme.accent : Theme.textSecondary)
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 12, weight: index == controller.projectSelectedIndex ? .semibold : .regular))
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 4)
                            if currentPath == path {
                                Text("current")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                row(index: controller.recentProjects.count) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                        Text("Add new project…")
                            .font(.system(size: 12))
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 320)
    }

    private var currentPath: String? {
        controller.draftWorkingDirectory
    }

    private func row(index: Int, @ViewBuilder content: () -> some View) -> some View {
        let selected = index == controller.projectSelectedIndex
        return content()
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
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
    }

    private var footer: some View {
        HStack(spacing: 12) {
            KeyHint(symbol: "E/D", label: "navigate")
            KeyHint(symbol: "␣", label: "select")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
