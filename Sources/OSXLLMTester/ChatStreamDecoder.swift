import Foundation

enum ChatStreamEvent: Equatable {
    case text(String)
    case done
}

/// Accepts SSE data lines, including JSON split across multiple data fields.
struct ChatStreamDecoder {
    private var payload = ""

    mutating func consume(_ line: String) throws -> ChatStreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        var data = String(line.dropFirst(5))
        if data.hasPrefix(" ") { data.removeFirst() }
        if data.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            payload = ""
            return .done
        }
        payload += (payload.isEmpty ? "" : "\n") + data
        guard let bytes = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        payload = ""
        return try Self.event(from: object)
    }

    static func event(from object: [String: Any]) throws -> ChatStreamEvent? {
        if let error = object["error"] as? [String: Any] {
            throw APIClientError.server(error["message"] as? String ?? "The endpoint returned a stream error.")
        }
        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first(where: { ($0["index"] as? Int) == 0 }) ?? choices.first else { return nil }
        let message = (first["delta"] as? [String: Any]) ?? (first["message"] as? [String: Any])
        if let text = message?["content"] as? String, !text.isEmpty { return .text(text) }
        if let parts = message?["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return .text(text) }
        }
        if let text = first["text"] as? String, !text.isEmpty { return .text(text) }
        return nil
    }
}
