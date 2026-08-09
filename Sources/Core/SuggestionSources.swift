import Foundation

/// Slash commands available in a given project directory, fetched by asking
/// the CLI itself: a short-lived `claude` process answers an `initialize`
/// control request with every command it would accept — built-ins, custom
/// commands, and skills, user- and project-level. Cached per directory for
/// the app's lifetime (command sets change rarely).
@MainActor
final class SlashCommandCatalog {
    static let shared = SlashCommandCatalog()

    private var cache: [String: [SlashCommand]] = [:]
    private var inflight: [String: Task<[SlashCommand], Never>] = [:]

    /// Instantly available result, if any (drives the popup synchronously).
    func cached(for directory: String) -> [SlashCommand]? {
        cache[directory]
    }

    /// Fetch (or return cached) commands for a directory.
    func commands(for directory: String) async -> [SlashCommand] {
        if let hit = cache[directory] { return hit }
        if let task = inflight[directory] { return await task.value }
        let task = Task.detached(priority: .userInitiated) {
            Self.probe(directory: directory)
        }
        inflight[directory] = task
        let result = await task.value
        inflight[directory] = nil
        // Cache failures as empty too — retrying a broken CLI every
        // keystroke would spawn processes in a loop.
        cache[directory] = result
        return result
    }

    /// Spawn the CLI, send `initialize`, read lines until the matching
    /// control_response arrives, then kill the process.
    private nonisolated static func probe(directory: String) -> [SlashCommand] {
        guard let executable = ClaudeCodeLauncher.resolveExecutable(
            configuredPath: UserDefaults.standard.string(forKey: ClaudeCodeProvider.configuredPathKey),
            home: NSHomeDirectory(),
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"],
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        ) else { return [] }

        let requestID = "init-\(UUID().uuidString)"
        guard let request = StreamJSON.encodeInitialize(requestID: requestID) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "-p", "--verbose",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--no-session-persistence",
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.environment = ClaudeCodeProvider.childEnvironment()
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))
        } catch {
            return []
        }
        defer {
            process.terminate()
            try? stdin.fileHandleForWriting.close()
        }

        // Line-buffered read with a deadline; the response is one line but
        // may share a chunk with other output.
        let deadline = Date().addingTimeInterval(15)
        var buffer = Data()
        while Date() < deadline {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { return [] } // EOF: process died
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                if let commands = StreamJSON.parseInitializeCommands(line, requestID: requestID) {
                    return commands
                }
            }
        }
        return []
    }
}

/// Relative file paths under a project directory, for `@` mentions.
/// `git ls-files` (tracked + untracked, gitignore respected) when the
/// directory is a repo; a bounded FileManager walk otherwise.
enum FileLister {
    static func listFiles(at directory: String, limit: Int = 5000) -> [String] {
        if let tracked = gitFiles(at: directory, limit: limit) { return tracked }
        return walkFiles(at: directory, limit: limit)
    }

    private static func gitFiles(at directory: String, limit: Int) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["ls-files", "--cached", "--others", "--exclude-standard"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
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
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        let files = output.split(separator: "\n").prefix(limit).map(String.init)
        return files.isEmpty ? nil : files
    }

    private static let skippedDirectories: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", ".venv", "venv",
        "__pycache__", "DerivedData", ".next", "target",
    ]

    private static func walkFiles(at directory: String, limit: Int) -> [String] {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [String] = []
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in enumerator {
            if files.count >= limit { break }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let path = url.path
            files.append(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path)
        }
        return files
    }
}
