import Foundation

// MARK: - Harness configuration

/// Coding-agent harnesses available when a session is created. The raw value
/// is also the provider id persisted in `AgentSessionMeta`.
enum AgentHarness: String, CaseIterable, Codable, Identifiable, Equatable {
    case codex
    case claudeCode = "claude-code"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        }
    }
}

// MARK: - Agent state

/// Lifecycle state of an agent session as shown in the management panel.
enum AgentState: String, Codable, Equatable {
    case running
    case needsInput
    case failed
    case archived
}

// MARK: - Chat transcript model

enum ChatRole: String, Codable, Equatable {
    case user
    case assistant
    case tool
    case system
    case error
}

/// One displayable item in an agent conversation. Tool activity is flattened
/// into short summary lines the way Claude Code's own UI presents it.
struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var role: ChatRole
    var text: String
    /// Tool name when role == .tool (e.g. "Bash", "Edit").
    var toolName: String?
    var timestamp: Date = Date()
}

// MARK: - Session metadata

/// Persistent metadata for one agent session. This is what survives restarts;
/// the provider can resume the underlying conversation from
/// `providerSessionID`.
struct AgentSessionMeta: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    /// Which provider owns this session (e.g. "claude-code").
    var providerID: String
    /// The harness's own session/thread identifier, used for resume. Nil
    /// until the harness reports it.
    var providerSessionID: String?
    /// Short human title, derived from the initial prompt.
    var title: String
    /// Working directory the agent was started in.
    var workingDirectory: String
    /// Model alias the session was started with (nil = CLI default). Reused
    /// on resume so a session keeps its model.
    var model: String?
    /// Thinking-effort level (nil = CLI default). Reused on resume.
    var effort: String?
    var state: AgentState
    /// One-line summary of the latest activity, for the panel.
    var statusDetail: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

// MARK: - Provider abstraction

/// Result of checking whether a provider is usable on this machine.
struct ProviderHealth: Equatable {
    var isConnected: Bool
    /// e.g. resolved executable path and version when connected.
    var detail: String
    /// Actionable error when not connected.
    var errorMessage: String?
    var remediation: String?
}

/// A pending tool-approval request from the agent.
struct PermissionRequest: Identifiable, Equatable {
    var id: String
    var toolName: String
    var summary: String
    /// Raw tool input, echoed back verbatim on approval.
    var inputJSON: String
}

/// Events emitted by a live agent run. Delivered on the main thread.
protocol AgentRunDelegate: AnyObject {
    /// The provider assigned/confirmed its own session identifier.
    func agentRun(_ run: AgentRun, didReportProviderSessionID id: String)
    /// A new displayable message arrived.
    func agentRun(_ run: AgentRun, didAppend message: ChatMessage)
    /// The run's state changed (running <-> needsInput, or failed).
    func agentRun(_ run: AgentRun, didChangeState state: AgentState, detail: String?)
    /// The agent wants to run a tool and awaits approval.
    func agentRun(_ run: AgentRun, didRequestPermission request: PermissionRequest)
}

/// A live, in-process handle to one agent conversation.
protocol AgentRun: AnyObject {
    var sessionID: UUID { get }
    var delegate: AgentRunDelegate? { get set }
    /// Approvals the user has not yet answered.
    var pendingPermissions: [PermissionRequest] { get }
    /// Send a user message into the conversation.
    func send(text: String)
    /// Switch the model for subsequent turns of this live conversation.
    func setModel(_ model: String)
    /// Switch the thinking effort for subsequent turns when the harness can
    /// apply it without restarting the session process.
    func setEffort(_ effort: String?)
    /// Abort the in-flight turn; the session stays alive for follow-ups.
    func interrupt()
    /// Answer a pending tool-approval request.
    func respondToPermission(requestID: String, allow: Bool)
    /// Stop the underlying process. The session may later be resumed.
    func terminate()
}

/// A coding-agent provider backed by one installed harness.
protocol AgentProvider: AnyObject {
    var harness: AgentHarness { get }
    /// Model aliases offered in the picker; nil means the harness default.
    var modelOptions: [String?] { get }
    /// Thinking levels valid for the selected model. An empty array hides the
    /// thinking section.
    func effortOptions(for model: String?) -> [String?]
    /// Verify the provider's executable can be found and launched.
    func checkHealth() async -> ProviderHealth
    /// Start a new conversation, or resume an existing provider session when
    /// `resumeProviderSessionID` is set. `initialPrompt` is nil when resuming
    /// without an immediate message.
    func startRun(
        sessionID: UUID,
        initialPrompt: String?,
        workingDirectory: String,
        model: String?,
        effort: String?,
        resumeProviderSessionID: String?
    ) throws -> AgentRun

    /// Generate a short display title for a session that started with
    /// `prompt`. Optional; nil keeps the fallback (truncated prompt).
    func generateTitle(forPrompt prompt: String) async -> String?
}

extension AgentProvider {
    var id: String { harness.rawValue }
    var displayName: String { harness.displayName }
    func supportsEffort(model: String?) -> Bool { !effortOptions(for: model).isEmpty }
    func generateTitle(forPrompt prompt: String) async -> String? { nil }
}
