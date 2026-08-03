import Foundation

/// Parsed form of one line of Claude Code's `--output-format stream-json`
/// protocol. Pure functions only, so the wire handling is unit-testable.
enum StreamEvent: Equatable {
    /// system/init: the CLI confirmed the session and reported its ID.
    case sessionStarted(sessionID: String)
    /// A text block from the assistant.
    case assistantText(String)
    /// The assistant invoked a tool; `summary` is a short display string.
    case toolUse(name: String, summary: String)
    /// Turn finished. `resultText` is the final text; `isError` marks failures
    /// (budget exceeded, API errors, etc.).
    case turnEnded(isError: Bool, resultText: String?)
    /// The CLI is asking whether a tool may run (can_use_tool control
    /// request). The session needs user input until this is answered.
    /// `inputJSON` is the tool's raw input, re-serialized, needed verbatim in
    /// the allow response.
    case permissionRequested(requestID: String, toolName: String, summary: String, inputJSON: String)
    /// A line we recognize but don't display (thinking, usage, tool results…).
    case ignored
}

enum StreamJSON {

    // MARK: - Decoding (CLI stdout -> events)

    static func parseLine(_ line: String) -> StreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }

        switch type {
        case "system":
            if obj["subtype"] as? String == "init",
               let sessionID = obj["session_id"] as? String {
                return .sessionStarted(sessionID: sessionID)
            }
            return .ignored

        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { return .ignored }
            // A single assistant event carries one content block in practice,
            // but handle several defensively: prefer tool_use, else text.
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        return .assistantText(text)
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    return .toolUse(name: name, summary: toolSummary(name: name, input: input))
                default:
                    continue
                }
            }
            return .ignored

        case "result":
            let isError = (obj["is_error"] as? Bool ?? false)
                || (obj["subtype"] as? String).map { $0 != "success" } ?? false
            return .turnEnded(isError: isError, resultText: obj["result"] as? String)

        case "control_request":
            guard let request = obj["request"] as? [String: Any],
                  request["subtype"] as? String == "can_use_tool",
                  let requestID = obj["request_id"] as? String
            else { return .ignored }
            let toolName = request["tool_name"] as? String ?? "tool"
            let input = request["input"] as? [String: Any] ?? [:]
            let inputJSON = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return .permissionRequested(
                requestID: requestID,
                toolName: toolName,
                summary: toolSummary(name: toolName, input: input),
                inputJSON: inputJSON
            )

        default:
            return .ignored
        }
    }

    /// Compact, Claude-Code-style one-liner for a tool invocation.
    static func toolSummary(name: String, input: [String: Any]) -> String {
        if let command = input["command"] as? String {
            return command.count > 120 ? String(command.prefix(120)) + "…" : command
        }
        if let path = input["file_path"] as? String {
            return (path as NSString).abbreviatingWithTildeInPath
        }
        if let pattern = input["pattern"] as? String { return pattern }
        if let prompt = input["prompt"] as? String {
            return prompt.count > 80 ? String(prompt.prefix(80)) + "…" : prompt
        }
        if let url = input["url"] as? String { return url }
        if input.isEmpty { return "" }
        let keys = input.keys.sorted().prefix(3).joined(separator: ", ")
        return keys
    }

    // MARK: - Encoding (user messages -> CLI stdin)

    /// One line of `--input-format stream-json` carrying a user message,
    /// optionally with an attached image (base64).
    static func encodeUserMessage(text: String, imageBase64: String? = nil, imageMediaType: String = "image/jpeg") -> String? {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let imageBase64 {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": imageMediaType,
                    "data": imageBase64,
                ],
            ])
        }
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": content,
            ],
        ]
        return serializeLine(payload)
    }

    /// Response to a can_use_tool control request.
    static func encodePermissionResponse(requestID: String, allow: Bool, inputJSON: String) -> String? {
        let updatedInput = (inputJSON.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        let inner: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": updatedInput]
            : ["behavior": "deny", "message": "The user declined this action from the overlay."]
        let payload: [String: Any] = [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestID,
                "response": inner,
            ],
        ]
        return serializeLine(payload)
    }

    private static func serializeLine(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8)
        else { return nil }
        return line
    }
}
