import Foundation

enum APIClientError: LocalizedError {
    case invalidURL
    case missingModel
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid base URL."
        case .missingModel: return "Choose a model first."
        case .server(let message): return message
        case .invalidResponse: return "The endpoint returned an unreadable response."
        }
    }
}

final class APIClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        self.session = URLSession(configuration: configuration)
    }

    func listModels(for endpoint: Endpoint) async throws -> [String] {
        let data = try await request(path: "/models", method: "GET", endpoint: endpoint, body: nil)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else { throw APIClientError.invalidResponse }
        return rows.compactMap { $0["id"] as? String }.sorted()
    }

    func run(mode: TestMode, endpoint: Endpoint, model: String, prompt: String, system: String,
             temperature: Double, maxTokens: Int, thinking: Bool, streaming: Bool,
             imageDataURL: String? = nil, documents: String = "",
             onTextDelta: (@MainActor (String) -> Void)? = nil) async throws -> RequestResult {
        guard !model.isEmpty else { throw APIClientError.missingModel }
        let path: String
        var payload: [String: Any] = [:]
        switch mode {
        case .chat, .multimodal:
            path = "/chat/completions"
            let userContent: Any
            if mode == .multimodal, let imageDataURL {
                userContent = [["type": "text", "text": prompt],
                               ["type": "image_url", "image_url": ["url": imageDataURL]]]
            } else { userContent = prompt }
            var messages: [[String: Any]] = []
            if !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(["role": "system", "content": system])
            }
            messages.append(["role": "user", "content": userContent])
            payload = ["model": model, "messages": messages, "temperature": temperature,
                       "max_tokens": maxTokens, "stream": streaming]
            if thinking { payload["thinking"] = ["type": "enabled"] }
        case .embeddings:
            path = "/embeddings"
            payload = ["model": model, "input": prompt]
        case .rerank:
            path = "/rerank"
            payload = ["model": model, "query": prompt,
                       "documents": documents.split(separator: "\n").map(String.init)]
        }
        let start = Date()
        if streaming && (mode == .chat || mode == .multimodal) {
            let (body, status) = try await streamingRequest(path: path, endpoint: endpoint, body: payload, onTextDelta: onTextDelta)
            return RequestResult(statusCode: status, body: body, elapsed: Date().timeIntervalSince(start))
        }
        let data = try await request(path: path, method: "POST", endpoint: endpoint, body: payload)
        let pretty = prettyJSON(data) ?? String(data: data, encoding: .utf8) ?? ""
        return RequestResult(statusCode: 200, body: pretty, elapsed: Date().timeIntervalSince(start))
    }

    private func request(path: String, method: String, endpoint: Endpoint,
                         body: [String: Any]?) async throws -> Data {
        guard URLComponents(string: endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else { throw APIClientError.invalidURL }
        let normalizedBase = endpoint.baseURL.hasSuffix("/") ? String(endpoint.baseURL.dropLast()) : endpoint.baseURL
        let urlString = normalizedBase + (path.hasPrefix("/") ? path : "/" + path)
        guard let url = URL(string: urlString) else { throw APIClientError.invalidURL }
        let request = makeRequest(url: url, method: method, endpoint: endpoint, body: body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    private func makeRequest(url: URL, method: String, endpoint: Endpoint, body: [String: Any]?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !endpoint.apiKey.isEmpty { request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw APIClientError.server("HTTP \(http.statusCode): \(message)")
        }
    }

    private func streamingRequest(path: String, endpoint: Endpoint, body: [String: Any],
                                  onTextDelta: (@MainActor (String) -> Void)?) async throws -> (String, Int) {
        let normalizedBase = endpoint.baseURL.hasSuffix("/") ? String(endpoint.baseURL.dropLast()) : endpoint.baseURL
        guard let url = URL(string: normalizedBase + (path.hasPrefix("/") ? path : "/" + path)) else { throw APIClientError.invalidURL }
        var request = makeRequest(url: url, method: "POST", endpoint: endpoint, body: body)
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count >= 16_384 { break }
            }
            try validate(response: response, data: errorBody)
            throw APIClientError.invalidResponse
        }
        if http.mimeType == "application/json" {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               case .text(let content) = try ChatStreamDecoder.event(from: object) {
                try Task.checkCancellation()
                await onTextDelta?(content)
                return (content, http.statusCode)
            }
            return (prettyJSON(data) ?? String(decoding: data, as: UTF8.self), http.statusCode)
        }
        var text = ""
        var raw = ""
        var decoder = ChatStreamDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if text.isEmpty { raw += line + "\n" }
            switch try decoder.consume(line) {
            case .text(let content):
                text += content
                raw = ""
                await onTextDelta?(content)
            case .done:
                return (text.isEmpty ? raw : text, http.statusCode)
            case nil: break
            }
        }
        return (text.isEmpty ? raw : text, http.statusCode)
    }

    private func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}
