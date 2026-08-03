import Combine
import Foundation

/// Owns all agent-session metadata and transcripts, and persists them so the
/// management panel can be restored after a restart. Foundation/Combine only —
/// no AppKit — so it is unit-testable.
final class SessionStore: ObservableObject {

    @Published private(set) var sessions: [AgentSessionMeta] = []
    /// Transcripts keyed by session id. Loaded eagerly (MVP scale).
    @Published private(set) var transcripts: [UUID: [ChatMessage]] = [:]

    private let directory: URL
    private var sessionsFile: URL { directory.appendingPathComponent("sessions.json") }
    private var transcriptsDir: URL { directory.appendingPathComponent("transcripts") }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Assistant")
    }

    init(directory: URL = SessionStore.defaultDirectory()) {
        self.directory = directory
        load()
    }

    // MARK: - Derived views for the panel

    /// Sessions shown in the panel: needs-input first, then running, then
    /// failed. Archived sessions are excluded.
    var panelSessions: [AgentSessionMeta] {
        let visible = sessions.filter { $0.state != .archived }
        func rank(_ s: AgentState) -> Int {
            switch s {
            case .needsInput: return 0
            case .running: return 1
            case .failed: return 2
            case .archived: return 3
            }
        }
        return visible.sorted {
            if rank($0.state) != rank($1.state) { return rank($0.state) < rank($1.state) }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func session(id: UUID) -> AgentSessionMeta? {
        sessions.first { $0.id == id }
    }

    func transcript(for id: UUID) -> [ChatMessage] {
        transcripts[id] ?? []
    }

    // MARK: - Mutations

    func add(_ meta: AgentSessionMeta) {
        sessions.append(meta)
        persistSessions()
    }

    func update(id: UUID, _ mutate: (inout AgentSessionMeta) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[index])
        sessions[index].updatedAt = Date()
        persistSessions()
    }

    func setState(id: UUID, _ state: AgentState, detail: String? = nil) {
        update(id: id) {
            $0.state = state
            if let detail { $0.statusDetail = detail }
        }
    }

    func setProviderSessionID(id: UUID, _ providerSessionID: String) {
        update(id: id) { $0.providerSessionID = providerSessionID }
    }

    func archive(id: UUID) {
        setState(id: id, .archived)
    }

    func append(message: ChatMessage, to id: UUID) {
        transcripts[id, default: []].append(message)
        persistTranscript(for: id)
    }

    // MARK: - Persistence

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func load() {
        guard let data = try? Data(contentsOf: sessionsFile),
              let loaded = try? Self.decoder.decode([AgentSessionMeta].self, from: data)
        else { return }
        // Processes don't survive restarts: anything that was mid-run comes
        // back as needs-input so the user can resume it.
        sessions = loaded.map { meta in
            var m = meta
            if m.state == .running {
                m.state = .needsInput
                m.statusDetail = "Interrupted by restart — send a message to resume"
            }
            return m
        }
        for meta in sessions where meta.state != .archived {
            let file = transcriptsDir.appendingPathComponent("\(meta.id.uuidString).json")
            if let data = try? Data(contentsOf: file),
               let messages = try? Self.decoder.decode([ChatMessage].self, from: data) {
                transcripts[meta.id] = messages
            }
        }
    }

    private func persistSessions() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(sessions)
            try data.write(to: sessionsFile, options: .atomic)
        } catch {
            NSLog("SessionStore: failed to persist sessions: \(error)")
        }
    }

    private func persistTranscript(for id: UUID) {
        do {
            try FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(transcripts[id] ?? [])
            try data.write(to: transcriptsDir.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
        } catch {
            NSLog("SessionStore: failed to persist transcript: \(error)")
        }
    }
}
