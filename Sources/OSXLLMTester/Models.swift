import Foundation

enum TestMode: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case embeddings = "Embeddings"
    case multimodal = "Multimodal"
    case rerank = "Rerank"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .embeddings: return "point.3.connected.trianglepath.dotted"
        case .multimodal: return "photo.on.rectangle.angled"
        case .rerank: return "list.number"
        }
    }
}

struct Endpoint: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var baseURL: String
    var apiKey: String
    var models: [String]
    var selectedModel: String
    var enabled: Bool
    var bookmarked: Bool

    static let starter = Endpoint(
        id: UUID(),
        name: "Local / OpenAI",
        baseURL: "http://localhost:11434/v1",
        apiKey: "",
        models: [],
        selectedModel: "",
        enabled: true,
        bookmarked: true
    )
}

struct ModelChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

struct RequestResult {
    let statusCode: Int
    let body: String
    let elapsed: TimeInterval
}
