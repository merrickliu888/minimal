import AppKit
import Combine
import Foundation

/// Bridges live agent runs to the session store and the UI. Owns the mapping
/// from session id -> running process, starts/resumes runs, and translates
/// AgentRun delegate events into store mutations.
@MainActor
final class AgentCoordinator: ObservableObject, AgentRunDelegate {
    let store: SessionStore
    let providers: [AgentProvider]

    private var providersByID: [String: AgentProvider] {
        Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
    }

    /// Live process handles. Sessions without an entry are resumable.
    private var liveRuns: [UUID: AgentRun] = [:]

    /// UserDefaults key for the default working directory of new agents.
    static let workingDirectoryKey = "agentWorkingDirectory"

    init(store: SessionStore, providers: [AgentProvider]) {
        self.store = store
        self.providers = providers
    }

    func provider(for harness: AgentHarness) -> AgentProvider? {
        providersByID[harness.rawValue]
    }

    func provider(forID id: String) -> AgentProvider? {
        providersByID[id]
    }

    var defaultWorkingDirectory: String {
        UserDefaults.standard.string(forKey: Self.workingDirectoryKey) ?? NSHomeDirectory()
    }

    // MARK: - Session lifecycle

    /// Start a brand-new agent from the prompt pill, scoped to the given
    /// directory (Settings default when nil). Returns the session id so the
    /// overlay can open its conversation immediately.
    @discardableResult
    func startAgent(
        prompt: String,
        harness: AgentHarness,
        workingDirectory: String? = nil,
        model: String? = nil,
        effort: String? = nil
    ) -> UUID {
        let provider = provider(for: harness)
        let meta = AgentSessionMeta(
            providerID: harness.rawValue,
            providerSessionID: nil,
            title: ClaudeCodeLauncher.title(fromPrompt: prompt),
            workingDirectory: workingDirectory ?? defaultWorkingDirectory,
            model: model,
            effort: effort,
            state: .running,
            statusDetail: "Starting…"
        )
        store.add(meta)
        store.append(message: ChatMessage(role: .user, text: prompt), to: meta.id)
        // Upgrade the truncated-prompt title to a generated one in the
        // background; keep the fallback if generation fails.
        Task { [weak self] in
            guard let self, let provider,
                  let title = await provider.generateTitle(forPrompt: prompt)
            else { return }
            guard self.store.session(id: meta.id)?.state != .archived else { return }
            self.store.update(id: meta.id) { $0.title = title }
        }
        guard let provider else {
            let detail = "The \(harness.displayName) harness is not configured."
            store.setState(id: meta.id, .failed, detail: detail)
            store.append(message: ChatMessage(role: .error, text: detail), to: meta.id)
            return meta.id
        }
        do {
            let run = try provider.startRun(
                sessionID: meta.id,
                initialPrompt: prompt,
                workingDirectory: meta.workingDirectory,
                model: meta.model,
                effort: meta.effort,
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
        guard let provider = provider(forID: meta.providerID) else {
            let detail = "The session's coding harness is no longer available."
            store.setState(id: sessionID, .failed, detail: detail)
            store.append(message: ChatMessage(role: .error, text: detail), to: sessionID)
            return
        }
        do {
            let run = try provider.startRun(
                sessionID: sessionID,
                initialPrompt: text,
                workingDirectory: meta.workingDirectory,
                model: meta.model,
                effort: meta.effort,
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

    /// Switch a session's model: live via the control channel when the
    /// process is running, and persisted so restarts/resumes keep it.
    func setModel(_ model: String, for sessionID: UUID) {
        store.update(id: sessionID) { $0.model = model }
        liveRuns[sessionID]?.setModel(model)
    }

    /// Stop the in-flight turn; the session stays alive for follow-ups.
    func interrupt(sessionID: UUID) {
        liveRuns[sessionID]?.interrupt()
    }

    /// Persist a session's thinking level and let harnesses that launch one
    /// process per turn apply it to the next message.
    func setEffort(_ effort: String?, for sessionID: UUID) {
        store.update(id: sessionID) { $0.effort = effort }
        liveRuns[sessionID]?.setEffort(effort)
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
