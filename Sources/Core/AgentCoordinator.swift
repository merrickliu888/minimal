import AppKit
import Combine
import Foundation

/// Bridges live agent runs to the session store and the UI. Owns the mapping
/// from session id -> running process, starts/resumes runs, and translates
/// AgentRun delegate events into store mutations.
@MainActor
final class AgentCoordinator: ObservableObject, AgentRunDelegate {
    let store: SessionStore
    let provider: AgentProvider

    /// Live process handles. Sessions without an entry are resumable.
    private var liveRuns: [UUID: AgentRun] = [:]

    /// UserDefaults key for the default working directory of new agents.
    static let workingDirectoryKey = "agentWorkingDirectory"

    init(store: SessionStore, provider: AgentProvider) {
        self.store = store
        self.provider = provider
    }

    var defaultWorkingDirectory: String {
        UserDefaults.standard.string(forKey: Self.workingDirectoryKey) ?? NSHomeDirectory()
    }

    // MARK: - Session lifecycle

    /// Start a brand-new agent from the prompt pill. Returns the session id
    /// so the overlay can open its conversation immediately.
    @discardableResult
    func startAgent(prompt: String) -> UUID {
        let meta = AgentSessionMeta(
            providerID: provider.id,
            providerSessionID: nil,
            title: ClaudeCodeLauncher.title(fromPrompt: prompt),
            workingDirectory: defaultWorkingDirectory,
            state: .running,
            statusDetail: "Starting…"
        )
        store.add(meta)
        store.append(message: ChatMessage(role: .user, text: prompt), to: meta.id)
        do {
            let run = try provider.startRun(
                sessionID: meta.id,
                initialPrompt: prompt,
                workingDirectory: meta.workingDirectory,
                resumeProviderSessionID: nil
            )
            run.delegate = self
            liveRuns[meta.id] = run
        } catch {
            store.setState(id: meta.id, .failed, detail: error.localizedDescription)
            store.append(message: ChatMessage(role: .error, text: error.localizedDescription), to: meta.id)
        }
        return meta.id
    }

    /// Send a follow-up message, resuming the provider session if the
    /// process is no longer alive (e.g. after an app restart).
    func send(text: String, to sessionID: UUID) {
        guard let meta = store.session(id: sessionID) else { return }
        store.append(message: ChatMessage(role: .user, text: text), to: sessionID)
        if let run = liveRuns[sessionID] {
            run.send(text: text)
            store.setState(id: sessionID, .running, detail: "Working…")
            return
        }
        do {
            let run = try provider.startRun(
                sessionID: sessionID,
                initialPrompt: text,
                workingDirectory: meta.workingDirectory,
                resumeProviderSessionID: meta.providerSessionID
            )
            run.delegate = self
            liveRuns[sessionID] = run
            store.setState(id: sessionID, .running, detail: "Resuming…")
        } catch {
            store.setState(id: sessionID, .failed, detail: error.localizedDescription)
            store.append(message: ChatMessage(role: .error, text: error.localizedDescription), to: sessionID)
        }
    }

    func respondToPermission(sessionID: UUID, requestID: String, allow: Bool) {
        liveRuns[sessionID]?.respondToPermission(requestID: requestID, allow: allow)
    }

    func pendingPermissions(for sessionID: UUID) -> [PermissionRequest] {
        liveRuns[sessionID]?.pendingPermissions ?? []
    }

    func archive(sessionID: UUID) {
        liveRuns[sessionID]?.terminate()
        liveRuns.removeValue(forKey: sessionID)
        store.archive(id: sessionID)
    }

    func terminateAll() {
        for run in liveRuns.values { run.terminate() }
        liveRuns.removeAll()
    }

    // MARK: - AgentRunDelegate (main thread)

    nonisolated func agentRun(_ run: AgentRun, didReportProviderSessionID id: String) {
        let sessionID = run.sessionID
        Task { @MainActor in self.store.setProviderSessionID(id: sessionID, id) }
    }

    nonisolated func agentRun(_ run: AgentRun, didAppend message: ChatMessage) {
        let sessionID = run.sessionID
        Task { @MainActor in self.store.append(message: message, to: sessionID) }
    }

    nonisolated func agentRun(_ run: AgentRun, didChangeState state: AgentState, detail: String?) {
        let sessionID = run.sessionID
        Task { @MainActor in
            // Never let a live event resurrect an archived session.
            guard self.store.session(id: sessionID)?.state != .archived else { return }
            self.store.setState(id: sessionID, state, detail: detail)
        }
    }

    nonisolated func agentRun(_ run: AgentRun, didRequestPermission request: PermissionRequest) {
        // State + transcript updates arrive via the other callbacks; nothing
        // extra needed here for the MVP UI, which reads pendingPermissions.
    }
}
