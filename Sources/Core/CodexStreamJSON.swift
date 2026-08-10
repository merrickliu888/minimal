import Foundation

/// Parser for the JSONL event stream emitted by `codex exec --json`.
enum CodexStreamJSON {

    static func parseLine(_ line: String) -> StreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        switch type {
        case "thread.started":
            guard let threadID = object["thread_id"] as? String else { return .ignored }
            return .sessionStarted(sessionID: threadID)

        case "item.started":
            guard let item = object["item"] as? [String: Any] else { return .ignored }
            return toolEvent(from: item)

        case "item.completed":
            guard let item = object["item"] as? [String: Any],
                  let itemType = item["type"] as? String
            else { return .ignored }
            if itemType == "agent_message",
               let text = item["text"] as? String, !text.isEmpty {
                return .assistantText(text)
            }
            // File changes are commonly reported only once they complete.
            if itemType == "file_change" {
                return toolEvent(from: item)
            }
            return .ignored

        case "turn.completed":
            return .turnEnded(isError: false, resultText: nil)

        case "turn.failed", "error":
            return .turnEnded(isError: true, resultText: errorMessage(from: object))

        case "turn.started":
            return .ignored

        default:
            return .ignored
        }
    }

    private static func toolEvent(from item: [String: Any]) -> StreamEvent {
        switch item["type"] as? String {
        case "command_execution":
            let command = item["command"] as? String ?? ""
            return .toolUse(name: "Shell", summary: shortened(command, limit: 120))

        case "file_change":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let paths = changes.compactMap { $0["path"] as? String }
            let summary = paths.isEmpty ? "Updated files" : paths.prefix(3).joined(separator: ", ")
            return .toolUse(name: "Edit", summary: shortened(summary, limit: 120))

        case "mcp_tool_call":
            let server = item["server"] as? String
            let tool = item["tool"] as? String ?? "MCP"
            let name = server.map { "\($0).\(tool)" } ?? tool
            let arguments = item["arguments"] as? [String: Any] ?? [:]
            return .toolUse(name: name, summary: StreamJSON.toolSummary(name: tool, input: arguments))

        case "web_search":
            return .toolUse(name: "Web Search", summary: item["query"] as? String ?? "")

        default:
            return .ignored
        }
    }

    private static func errorMessage(from object: [String: Any]) -> String? {
        if let message = object["message"] as? String { return message }
        if let error = object["error"] as? String { return error }
        if let error = object["error"] as? [String: Any] {
            return error["message"] as? String
        }
        return nil
    }

    private static func shortened(_ value: String, limit: Int) -> String {
        value.count > limit ? String(value.prefix(limit)) + "…" : value
    }
}
