import SwiftUI

/// Autocomplete popup for `@file` mentions and `/commands`, shown above the
/// prompt pill (as its own card) or above the conversation composer
/// (embedded). Rows come pre-filtered and pre-ranked from the controller.
struct SuggestionPopupView: View {
    @EnvironmentObject var controller: MinimalController
    /// Embedded (conversation composer) skips the card chrome.
    var embedded = false

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            if controller.suggestions.isEmpty {
                HStack(spacing: 8) {
                    if controller.suggestionsLoading {
                        ProgressView().controlSize(.small)
                        Text("Loading suggestions…")
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                        Text(noResultsLabel)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            } else {
                ForEach(Array(controller.suggestions.enumerated()), id: \.offset) { index, suggestion in
                    row(suggestion, selected: index == controller.suggestionIndex)
                }
                HStack(spacing: 12) {
                    KeyHint(symbol: "↑↓", label: "navigate")
                    KeyHint(symbol: "⇥", label: "insert")
                    KeyHint(symbol: "esc", label: "dismiss")
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 8)

        if embedded {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
                .frame(width: 560, alignment: .leading)
                .overlayCard(cornerRadius: 14)
        }
    }

    private var noResultsLabel: String {
        switch controller.suggestionKind {
        case .slashCommand: return "No matching commands"
        case .fileMention, nil: return "No matching files"
        }
    }

    @ViewBuilder
    private func row(_ suggestion: InlineSuggestion, selected: Bool) -> some View {
        HStack(spacing: 8) {
            switch suggestion {
            case .file(let path):
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 14)
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Text(directoryPart(of: path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            case .command(let command):
                Image(systemName: "command")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 14)
                Text("/\(command.name)")
                    .font(.system(size: 12, weight: selected ? .semibold : .regular, design: .monospaced))
                    .lineLimit(1)
                if !command.argumentHint.isEmpty {
                    Text(command.argumentHint)
                        .font(.system(size: 11))
                        .italic()
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Text(command.description)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.22) : .clear)
                .padding(.horizontal, 6)
        )
    }

    private func directoryPart(of path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
}
