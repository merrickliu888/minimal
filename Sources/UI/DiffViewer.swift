import SwiftUI

/// Right-side pane showing uncommitted changes in the session's working
/// directory as a colored unified diff (Paseo-style typed line rows).
struct DiffViewerView: View {
    let lines: [DiffLine]
    let isEmpty: Bool

    var body: some View {
        Group {
            if isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textSecondary)
                    Text("No uncommitted changes")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    // Plain VStack + fixedSize: the column takes the widest
                    // line's natural width (rows never wrap), and rows with
                    // maxWidth: .infinity stretch to it so the add/remove
                    // tint bands span the full column.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.prefix(4000)) { line in
                            DiffLineRow(line: line)
                        }
                        if lines.count > 4000 {
                            Text("… diff truncated (\(lines.count) lines)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(12)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.vertical, 10)
                }
            }
        }
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        switch line.kind {
        case .fileHeader:
            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                Text(line.text)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)

        case .hunk:
            Text(line.text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.accent.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)

        case .add:
            row(prefix: "+", color: Color.green)

        case .remove:
            row(prefix: "-", color: Color.red)

        case .context:
            row(prefix: " ", color: nil)

        case .meta:
            EmptyView()
        }
    }

    private func row(prefix: String, color: Color?) -> some View {
        Text(prefix + line.text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(color?.opacity(0.95) ?? Theme.textPrimary.opacity(0.8))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((color ?? .clear).opacity(color == nil ? 0 : 0.08))
            .textSelection(.enabled)
    }
}
