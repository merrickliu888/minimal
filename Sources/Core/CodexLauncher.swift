import Foundation

/// Pure helpers for locating the `codex` executable and constructing stable
/// non-interactive invocations.
enum CodexLauncher {

    static func candidatePaths(home: String) -> [String] {
        [
            "\(home)/.local/bin/codex",
            "\(home)/.volta/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ]
    }

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
        if let pathEnvironment {
            for directory in pathEnvironment.split(separator: ":") {
                let candidate = "\(directory)/codex"
                if isExecutable(candidate) { return candidate }
            }
        }
        return nil
    }

    /// Current Codex CLI aliases exposed by the bundled model catalog. The
    /// default row remains useful when a user's config selects another model.
    static let modelOptions: [String?] = [
        nil,
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
    ]

    static func effortOptions(for model: String?) -> [String?] {
        let standard: [String?] = [nil, "low", "medium", "high", "xhigh"]
        switch model {
        case "gpt-5.6-sol", "gpt-5.6-terra", nil:
            return standard + ["max", "ultra"]
        case "gpt-5.6-luna":
            return standard + ["max"]
        default:
            return standard
        }
    }

    /// Build one `codex exec --json` turn. Codex exec is process-per-turn, so
    /// follow-ups use its resume subcommand rather than stdin.
    static func arguments(
        prompt: String,
        resumeSessionID: String?,
        model: String? = nil,
        effort: String? = nil
    ) -> [String] {
        var args = ["exec"]
        if let resumeSessionID {
            args += ["resume", resumeSessionID]
        }
        args += ["--json", "--skip-git-repo-check", "--config", "approval_policy=\"on-request\""]
        // Current `exec resume` does not accept the dedicated sandbox flag,
        // so use the equivalent config override on resumed turns.
        if resumeSessionID == nil {
            args += ["--sandbox", "workspace-write"]
        } else {
            args += ["--config", "sandbox_mode=\"workspace-write\""]
        }
        if let model {
            args += ["--model", model]
        }
        if let effort {
            args += ["--config", "model_reasoning_effort=\"\(effort)\""]
        }
        args.append(prompt)
        return args
    }
}
