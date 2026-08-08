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
