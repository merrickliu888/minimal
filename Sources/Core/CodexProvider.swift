import Foundation

/// Codex CLI integration using the stable, machine-readable `codex exec`
/// interface. Each message is one process; follow-ups resume the same thread.
final class CodexProvider: AgentProvider {
    let harness = AgentHarness.codex
    var modelOptions: [String?] { CodexLauncher.modelOptions }

    func effortOptions(for model: String?) -> [String?] {
        CodexLauncher.effortOptions(for: model)
    }

    static let configuredPathKey = "codexExecutablePath"

    private var resolvedExecutable: String? {
        CodexLauncher.resolveExecutable(
            configuredPath: UserDefaults.standard.string(forKey: Self.configuredPathKey),
            home: NSHomeDirectory(),
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"],
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    func checkHealth() async -> ProviderHealth {
        guard let executable = resolvedExecutable else {
            return ProviderHealth(
                isConnected: false,
                detail: "",
                errorMessage: "Could not find the `codex` executable.",
                remediation: "Install Codex CLI or set its path in Settings."
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ProviderHealth(
                isConnected: false,
                detail: executable,
                errorMessage: "Found \(executable) but it failed to launch: \(error.localizedDescription)",
                remediation: "Check that the file is executable, or point Settings at a different install."
            )
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            return ProviderHealth(
                isConnected: false,
                detail: executable,
                errorMessage: "`codex --version` exited with status \(process.terminationStatus): \(output)",
                remediation: "Try running it in a terminal to diagnose, then retry."
            )
        }
        return ProviderHealth(
            isConnected: true,
            detail: "\(executable) — \(output)",
            errorMessage: nil,
            remediation: nil
        )
    }

    func startRun(
        sessionID: UUID,
        initialPrompt: String?,
        workingDirectory: String,
        model: String?,
        effort: String?,
        resumeProviderSessionID: String?
    ) throws -> AgentRun {
        guard let executable = resolvedExecutable else {
            throw NSError(domain: "CodexProvider", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Codex executable not found. Configure it in Settings.",
            ])
        }
        let run = CodexRun(
            sessionID: sessionID,
            executable: executable,
            workingDirectory: workingDirectory,
            model: model,
            effort: effort,
            providerSessionID: resumeProviderSessionID
        )
        if let initialPrompt {
            // AgentCoordinator installs the delegate immediately after this
            // method returns. Start on the next main-queue pass so the first
            // thread and transcript events cannot race that installation.
            DispatchQueue.main.async { run.send(text: initialPrompt) }
        }
        return run
    }
}

// MARK: - Live run

final class CodexRun: AgentRun {
    let sessionID: UUID
    weak var delegate: AgentRunDelegate?
    let pendingPermissions: [PermissionRequest] = []

    private let executable: String
    private let workingDirectory: String
    private var model: String?
    private var effort: String?
    private var providerSessionID: String?

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private var turnInFlight = false
    private var interruptRequested = false
    private var terminatedByUs = false

    init(
        sessionID: UUID,
        executable: String,
        workingDirectory: String,
        model: String?,
        effort: String?,
        providerSessionID: String?
    ) {
        self.sessionID = sessionID
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.model = model
        self.effort = effort
        self.providerSessionID = providerSessionID
    }

    private func startTurn(text: String) throws {
        guard process?.isRunning != true else { return }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = CodexLauncher.arguments(
            prompt: text,
            resumeSessionID: providerSessionID,
            model: model,
            effort: effort
        )
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutBuffer = Data()
        stderrTail = ""
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consumeStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(2000))
            }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { self?.handleTermination(status: process.terminationStatus) }
        }

        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        turnInFlight = true
        try process.run()
        delegate?.agentRun(self, didChangeState: .running, detail: "Working…")
    }

    func send(text: String) {
        guard !terminatedByUs else { return }
        do {
            try startTurn(text: text)
        } catch {
            turnInFlight = false
            delegate?.agentRun(self, didAppend: ChatMessage(role: .error, text: error.localizedDescription))
            delegate?.agentRun(self, didChangeState: .failed, detail: error.localizedDescription)
        }
    }

    func setModel(_ model: String) {
        self.model = model
    }

    func setEffort(_ effort: String?) {
        self.effort = effort
    }

    func interrupt() {
        guard turnInFlight, let process, process.isRunning else { return }
        interruptRequested = true
        process.interrupt()
        delegate?.agentRun(self, didChangeState: .running, detail: "Stopping…")
    }

    func respondToPermission(requestID: String, allow: Bool) {
        // `codex exec` uses a pre-set sandbox policy and does not emit
        // interactive approval requests.
    }

    func terminate() {
        terminatedByUs = true
        if let process, process.isRunning { process.terminate() }
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newlineIndex]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            guard let line = String(data: Data(lineData), encoding: .utf8) else { continue }
            handle(event: CodexStreamJSON.parseLine(line))
        }
    }

    private func handle(event: StreamEvent?) {
        guard let event else { return }
        switch event {
        case .sessionStarted(let id):
            providerSessionID = id
            delegate?.agentRun(self, didReportProviderSessionID: id)

        case .assistantText(let text):
            delegate?.agentRun(self, didAppend: ChatMessage(role: .assistant, text: text))

        case .toolUse(let name, let summary):
            delegate?.agentRun(self, didAppend: ChatMessage(role: .tool, text: summary, toolName: name))
            delegate?.agentRun(self, didChangeState: .running, detail: summary.isEmpty ? name : "\(name): \(summary)")

        case .turnEnded(let isError, let resultText):
            turnInFlight = false
            if isError {
                let detail = resultText ?? "Codex run failed"
                delegate?.agentRun(self, didAppend: ChatMessage(role: .error, text: detail))
                delegate?.agentRun(self, didChangeState: .failed, detail: detail)
            } else {
                delegate?.agentRun(self, didChangeState: .needsInput, detail: "Finished — awaiting your reply")
            }

        case .permissionRequested, .ignored:
            break
        }
    }

    private func handleTermination(status: Int32) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        guard !terminatedByUs else { return }
        if interruptRequested {
            interruptRequested = false
            turnInFlight = false
            delegate?.agentRun(self, didAppend: ChatMessage(role: .system, text: "Interrupted."))
            delegate?.agentRun(self, didChangeState: .needsInput, detail: "Interrupted — awaiting your reply")
        } else if status != 0 || turnInFlight {
            turnInFlight = false
            let detail = stderrTail.isEmpty
                ? "Codex exited unexpectedly (status \(status))"
                : "Codex exited (status \(status)): \(stderrTail.suffix(300))"
            delegate?.agentRun(self, didAppend: ChatMessage(role: .error, text: detail))
            delegate?.agentRun(self, didChangeState: .failed, detail: String(detail.prefix(120)))
        }
    }
}
