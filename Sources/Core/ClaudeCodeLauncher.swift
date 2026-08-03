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

    /// Arguments for a streaming conversation process.
    /// - `sessionID`: our UUID, handed to the CLI so resume works even if we
    ///   crash before the CLI reports its own id (new sessions only).
    /// - `resumeSessionID`: provider session to resume instead.
    static func arguments(sessionID: UUID, resumeSessionID: String?) -> [String] {
        var args = [
            "-p",
            "--verbose",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            // Route tool approvals over stdin/stdout as can_use_tool control
            // requests so the overlay can surface them as Needs Input.
            "--permission-prompt-tool", "stdio",
            "--permission-mode", "default",
            // Without this, questions arrive as a structured tool call the
            // overlay would have to render as a form; disallowing it makes
            // Claude ask in plain text and end its turn, which the panel
            // already surfaces as Needs Input.
            "--disallowedTools", "AskUserQuestion",
        ]
        if let resume = resumeSessionID {
            args += ["--resume", resume]
        } else {
            args += ["--session-id", sessionID.uuidString.lowercased()]
        }
        return args
    }

    /// The initial user message, combining the spoken/typed prompt with an
    /// optional screenshot reference the agent can open with its Read tool.
    static func initialPrompt(userPrompt: String, screenshotPath: String?) -> String {
        guard let path = screenshotPath else { return userPrompt }
        return """
        \(userPrompt)

        [Supplemental context: a screenshot of the user's active display at the \
        moment they made this request is saved at \(path) — open it only if it \
        seems relevant to the request.]
        """
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
