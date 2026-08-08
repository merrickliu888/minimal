import Foundation

/// Minimal git introspection for display purposes.
enum GitInfo {
    /// Current branch name at `path`, or nil when not a git repo (or git is
    /// unavailable). Detached HEAD reports the short commit hash.
    static func currentBranch(at path: String) -> String? {
        guard let head = run(["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]) else { return nil }
        if head == "HEAD" {
            return run(["-C", path, "rev-parse", "--short", "HEAD"]).map { "@\($0)" }
        }
        return head.isEmpty ? nil : head
    }

    /// Unified diff of uncommitted changes (staged + unstaged) at `path`.
    /// Empty string = clean tree; nil = not a repo/git failure.
    static func uncommittedDiff(at path: String) -> String? {
        // HEAD is invalid in a repo with no commits yet; fall back to the
        // index-relative diff there.
        run(["-C", path, "diff", "HEAD"]) ?? run(["-C", path, "diff"])
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Unified diff model (Paseo-style typed lines)

struct DiffLine: Identifiable, Equatable {
    enum Kind: Equatable {
        /// "diff --git …" — starts a new file section; text is the file path.
        case fileHeader
        /// "@@ -a,b +c,d @@ …" hunk marker.
        case hunk
        case add
        case remove
        case context
        /// index/mode/rename/--- +++ noise lines, not displayed.
        case meta
    }

    let id: Int
    let kind: Kind
    let text: String
}

extension GitInfo {
    /// Parse `git diff` output into typed display lines. Meta noise is
    /// dropped; file headers carry just the (new) path.
    static func parseDiff(_ diff: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var id = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let entry: DiffLine?
            if line.hasPrefix("diff --git") {
                // "diff --git a/old b/new" -> show the new path.
                let path = line.split(separator: " ").last.map {
                    $0.hasPrefix("b/") ? String($0.dropFirst(2)) : String($0)
                } ?? line
                entry = DiffLine(id: id, kind: .fileHeader, text: path)
            } else if line.hasPrefix("@@") {
                entry = DiffLine(id: id, kind: .hunk, text: line)
            } else if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("index ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file")
                || line.hasPrefix("similarity") || line.hasPrefix("rename")
                || line.hasPrefix("old mode") || line.hasPrefix("new mode")
                || line.hasPrefix("Binary files") {
                entry = line.hasPrefix("Binary files")
                    ? DiffLine(id: id, kind: .context, text: line)
                    : nil // meta noise
            } else if line.hasPrefix("+") {
                entry = DiffLine(id: id, kind: .add, text: String(line.dropFirst()))
            } else if line.hasPrefix("-") {
                entry = DiffLine(id: id, kind: .remove, text: String(line.dropFirst()))
            } else {
                entry = DiffLine(id: id, kind: .context, text: line.hasPrefix(" ") ? String(line.dropFirst()) : line)
            }
            if let entry {
                lines.append(entry)
                id += 1
            }
        }
        // Trim a trailing blank context line from the final newline split.
        if lines.last?.kind == .context, lines.last?.text.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }
}
