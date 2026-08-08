import Foundation

/// Pure helpers for locating the `claude` executable and constructing its
/// command line. Separated from process management for testability.
enum ClaudeCodeLauncher {

    /// Well-known install locations, checked in order. A user-configured
    /// path always wins (checked by the caller before these).
    static func candidatePaths(home: String) -> [String] {
        [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
    }

    /// Resolve the executable using a user-configured override, well-known
    /// paths, then a PATH search. `isExecutable` is injected for testing.
    static func resolveExecutable(
        configuredPath: String?,
        home: String,
        pathEnvironment: String?,
        isExecutable: (String) -> Bool
    ) -> String? {
        if let configured = configuredPath, !configured.isEmpty {
            return isExecutable(configured) ? configured : nil
        }
        for candidate in candidatePaths(home: home) where isExecutable(candidate) {
            return candidate
        }
        if let pathEnv = pathEnvironment {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/claude"
                if isExecutable(candidate) { return candidate }
            }
        }
        return nil
    }

    /// Model aliases the pill's ⌘M cycles through; nil = CLI default.
    static let modelOptions: [String?] = [nil, "fable", "opus", "sonnet", "haiku"]

    /// Arguments for a streaming conversation process.
    /// - `sessionID`: our UUID, handed to the CLI so resume works even if we
    ///   crash before the CLI reports its own id (new sessions only).
    /// - `resumeSessionID`: provider session to resume instead.
    /// - `model`: model alias, or nil for the user's CLI default.
    static func arguments(sessionID: UUID, resumeSessionID: String?, model: String? = nil) -> [String] {
        var args = [
            "-p",
            "--verbose",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            // Route tool approvals over stdin/stdout as can_use_tool control
            // requests so the overlay can surface them as Needs Input.
            "--permission-prompt-tool", "stdio",
            // auto: a model classifier reviews permission prompts and only
            // escalates the ones it won't auto-approve to the overlay.
            "--permission-mode", "auto",
            // Without this, questions arrive as a structured tool call the
            // overlay would have to render as a form; disallowing it makes
            // Claude ask in plain text and end its turn, which the panel
            // already surfaces as Needs Input.
            "--disallowedTools", "AskUserQuestion",
        ]
        if let model {
            args += ["--model", model]
        }
        if let resume = resumeSessionID {
            args += ["--resume", resume]
        } else {
            args += ["--session-id", sessionID.uuidString.lowercased()]
        }
        return args
    }

    /// Short panel title derived from the first prompt.
    static func title(fromPrompt prompt: String) -> String {
        let collapsed = prompt
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= 48 { return collapsed.isEmpty ? "New agent" : collapsed }
        return String(collapsed.prefix(48)) + "…"
    }
}
