import Foundation

/// A slash command the CLI reported via the `initialize` control response:
/// custom commands, skills, and built-ins alike.
struct SlashCommand: Equatable {
    let name: String
    let description: String
    let argumentHint: String
}

/// One row of the suggestion popup.
enum InlineSuggestion: Equatable {
    case file(String)
    case command(SlashCommand)
}

/// The `@file` / `/command` token currently being typed, located by
/// character offsets so replacements are exact.
struct InlineToken: Equatable {
    enum Kind: Equatable {
        case fileMention
        case slashCommand
    }
    let kind: Kind
    /// Offset of the trigger character (`@` or `/`).
    let start: Int
    /// Offset one past the last character of the query (the cursor).
    let end: Int
    /// Text between the trigger character and the cursor.
    let query: String
}

enum InlineTrigger {

    // MARK: - Detection

    /// The active token at `cursor` (a character offset), if any. Slash
    /// commands win when both could match (their trigger sits closer to the
    /// cursor only when the text looks like `/cmd`, never inside a path).
    static func activeToken(text: String, cursor: Int) -> InlineToken? {
        let chars = Array(text)
        let clamped = max(0, min(cursor, chars.count))
        let mention = fileMention(chars: chars, cursor: clamped)
        let command = slashCommand(chars: chars, cursor: clamped)
        switch (mention, command) {
        case (let m?, let c?): return c.start > m.start ? c : m
        case (let m?, nil): return m
        case (nil, let c?): return c
        case (nil, nil): return nil
        }
    }

    /// `@query` — the query may contain anything except whitespace/quotes
    /// (paths with slashes are fine).
    private static func fileMention(chars: [Character], cursor: Int) -> InlineToken? {
        var index = cursor - 1
        while index >= 0 {
            let c = chars[index]
            if c.isWhitespace || c == "\"" || c == "'" { return nil }
            if c == "@" {
                return InlineToken(
                    kind: .fileMention,
                    start: index,
                    end: cursor,
                    query: String(chars[(index + 1)..<cursor])
                )
            }
            index -= 1
        }
        return nil
    }

    /// `/query` — only at the start of the text or after whitespace, and the
    /// query may not contain slashes (so paths never trigger it).
    private static func slashCommand(chars: [Character], cursor: Int) -> InlineToken? {
        var index = cursor - 1
        while index >= 0 {
            let c = chars[index]
            if c.isWhitespace || c == "\"" || c == "'" { return nil }
            if c == "/" {
                if index > 0 && !chars[index - 1].isWhitespace { return nil }
                return InlineToken(
                    kind: .slashCommand,
                    start: index,
                    end: cursor,
                    query: String(chars[(index + 1)..<cursor])
                )
            }
            index -= 1
        }
        return nil
    }

    // MARK: - Replacement

    /// Replace a file-mention token with `@path` (quoted when the path
    /// contains spaces — the CLI's mention syntax) plus a trailing space
    /// when the token ends the text.
    static func replacingFileMention(text: String, token: InlineToken, path: String) -> String {
        let needsQuotes = path.contains(where: \.isWhitespace) || path.contains("\"")
        let mention =
            needsQuotes ? "@\"\(path.replacingOccurrences(of: "\"", with: "\\\""))\"" : "@\(path)"
        return replace(text: text, token: token, with: mention)
    }

    /// Replace a slash-command token with `/name` plus a trailing space when
    /// the token ends the text.
    static func replacingSlashCommand(text: String, token: InlineToken, commandName: String)
        -> String
    {
        replace(text: text, token: token, with: "/\(commandName)")
    }

    private static func replace(text: String, token: InlineToken, with replacement: String)
        -> String
    {
        let chars = Array(text)
        let start = max(0, min(token.start, chars.count))
        let end = max(start, min(token.end, chars.count))
        let before = String(chars[0..<start])
        let after = String(chars[end...])
        let trailing = after.isEmpty ? " " : ""
        return before + replacement + trailing + after
    }

    // MARK: - Filtering

    /// Rank relative paths against the query: filename prefix beats filename
    /// substring beats path substring. Empty query returns the head of the
    /// list unchanged (recently indexed order).
    static func filterFiles(_ paths: [String], query: String, limit: Int = 8) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(paths.prefix(limit)) }
        var ranked: [(rank: Int, path: String)] = []
        for path in paths {
            let name = ((path as NSString).lastPathComponent).lowercased()
            let full = path.lowercased()
            let rank: Int
            if name.hasPrefix(q) {
                rank = 0
            } else if name.contains(q) {
                rank = 1
            } else if full.contains(q) {
                rank = 2
            } else {
                continue
            }
            ranked.append((rank, path))
        }
        return
            ranked
            .sorted { ($0.rank, $0.path.count, $0.path) < ($1.rank, $1.path.count, $1.path) }
            .prefix(limit)
            .map(\.path)
    }

    /// Rank commands by name: prefix beats substring beats description hit.
    static func filterCommands(_ commands: [SlashCommand], query: String, limit: Int = 8)
        -> [SlashCommand]
    {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(commands.prefix(limit)) }
        var ranked: [(rank: Int, command: SlashCommand)] = []
        for command in commands {
            let name = command.name.lowercased()
            let rank: Int
            if name.hasPrefix(q) {
                rank = 0
            } else if name.contains(q) {
                rank = 1
            } else if command.description.lowercased().contains(q) {
                rank = 2
            } else {
                continue
            }
            ranked.append((rank, command))
        }
        return
            ranked
            .sorted { ($0.rank, $0.command.name) < ($1.rank, $1.command.name) }
            .prefix(limit)
            .map(\.command)
    }
}
