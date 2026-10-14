import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var endpoints: [Endpoint]
    @Published var selectedEndpointID: UUID?
    @Published var selectedMode: TestMode = .chat
    @Published var isRunning = false
    @Published var isFetchingModels = false
    @Published var resultText = "Run a request to see the response here."
    @Published var resultStatus = "Ready"
    @Published var errorMessage: String?
    @Published var isStreamingResponse = false

    private var requestTask: Task<RequestResult, Error>?
    private var streamRenderer: WordStreamRenderer?
    private var stopRequested = false

    let client: APIClient
    private let credentials: CredentialStore
    private let defaults: UserDefaults
    private var unreadCredentialIDs: Set<UUID> = []
    private let defaultsKey = "saved-endpoints-v1"

    init(defaults: UserDefaults = .standard, credentials: CredentialStore = KeychainStore(), client: APIClient = APIClient()) {
        self.defaults = defaults
        self.credentials = credentials
        self.client = client
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([Endpoint].self, from: data) {
            endpoints = decoded
        } else {
            endpoints = [.starter]
        }
        for index in endpoints.indices {
            do { endpoints[index].apiKey = try credentials.read(for: endpoints[index].id) }
            catch {
                unreadCredentialIDs.insert(endpoints[index].id)
                errorMessage = error.localizedDescription
            }
        }
        selectedEndpointID = endpoints.first?.id
    }

    var selectedIndex: Int? { endpoints.firstIndex { $0.id == selectedEndpointID } }
    var selectedEndpoint: Endpoint? {
        guard let selectedIndex else { return nil }
        return endpoints[selectedIndex]
    }

    @discardableResult
    func save(_ endpoint: Endpoint) -> Bool {
        let previous = endpoints.first { $0.id == endpoint.id }
        do {
            // Metadata edits should never rewrite a credential or clear an unreadable one.
            if previous?.apiKey != endpoint.apiKey {
                try credentials.save(endpoint.apiKey, for: endpoint.id)
                unreadCredentialIDs.remove(endpoint.id)
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) { endpoints[index] = endpoint }
        else { endpoints.append(endpoint); selectedEndpointID = endpoint.id }
        persist()
        return true
    }

    func addEndpoint() {
        let endpoint = Endpoint(id: UUID(), name: "New endpoint", baseURL: "https://api.openai.com/v1", apiKey: "", models: [], selectedModel: "", enabled: true, bookmarked: false)
        endpoints.append(endpoint)
        selectedEndpointID = endpoint.id
    }

    func removeSelected() {
        guard let id = selectedEndpointID else { return }
        do { try credentials.remove(for: id) }
        catch { errorMessage = error.localizedDescription; return }
        unreadCredentialIDs.remove(id)
        endpoints.removeAll { $0.id == id }
        selectedEndpointID = endpoints.first?.id
        persist()
    }

    func toggleBookmark(_ endpoint: Endpoint) {
        var copy = endpoint; copy.bookmarked.toggle(); save(copy)
    }

    func fetchModels(for endpoint: Endpoint) async {
        isFetchingModels = true; errorMessage = nil
        do {
            let authorizedEndpoint = try endpointForRequest(endpoint)
            let models = try await client.listModels(for: authorizedEndpoint)
            guard var copy = endpoints.first(where: { $0.id == endpoint.id }) else {
                isFetchingModels = false
                return
            }
            copy.models = models
            if copy.selectedModel.isEmpty { copy.selectedModel = models.first ?? "" }
            save(copy); resultStatus = "Fetched \(models.count) model\(models.count == 1 ? "" : "s")"
        } catch { errorMessage = error.localizedDescription }
        isFetchingModels = false
    }

    func run(endpoint: Endpoint, model: String, prompt: String, system: String,
             temperature: Double, maxTokens: Int, thinking: Bool, streaming: Bool,
             imageDataURL: String?, documents: String) async {
        guard !isRunning else { return }
        let mode = selectedMode
        isStreamingResponse = streaming && (mode == .chat || mode == .multimodal)
        isRunning = true; errorMessage = nil; resultText = ""
        resultStatus = isStreamingResponse ? "Waiting for response…" : "Running…"
        stopRequested = false
        let renderer = isStreamingResponse ? WordStreamRenderer { [weak self] word in
            self?.resultText += word
        } : nil
        streamRenderer = renderer
        defer {
            isRunning = false
            requestTask = nil
            streamRenderer = nil
        }
        do {
            let authorizedEndpoint = try endpointForRequest(endpoint)
            let request = Task {
                try await client.run(mode: mode, endpoint: authorizedEndpoint, model: model,
                                              prompt: prompt, system: system, temperature: temperature,
                                              maxTokens: maxTokens, thinking: thinking, streaming: streaming,
                                              imageDataURL: imageDataURL, documents: documents,
                                              onTextDelta: { [weak self, weak renderer] text in
                    guard let self, !self.stopRequested else { return }
                    self.resultStatus = "Streaming…"
                    renderer?.append(text)
                })
            }
            requestTask = request
            let result = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
            await renderer?.finish()
            try Task.checkCancellation()
            if stopRequested { throw CancellationError() }
            if renderer?.receivedText != true { resultText = result.body }
            resultStatus = "HTTP \(result.statusCode) · \(String(format: "%.2fs", result.elapsed))"
        } catch {
            if stopRequested || Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                renderer?.cancel()
                resultStatus = "Stopped"
            } else {
                await renderer?.finish()
                errorMessage = error.localizedDescription
                resultStatus = "Request failed"
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        stopRequested = true
        requestTask?.cancel()
        streamRenderer?.cancel()
        resultStatus = "Stopping…"
    }

    private func persist() {
        let sanitized = endpoints.map { item -> Endpoint in var copy = item; copy.apiKey = ""; return copy }
        if let data = try? JSONEncoder().encode(sanitized) { defaults.set(data, forKey: defaultsKey) }
    }

    private func endpointForRequest(_ endpoint: Endpoint) throws -> Endpoint {
        var resolved = endpoints.first { $0.id == endpoint.id } ?? endpoint
        if unreadCredentialIDs.contains(endpoint.id) {
            resolved.apiKey = try credentials.read(for: endpoint.id)
            if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) { endpoints[index] = resolved }
            unreadCredentialIDs.remove(endpoint.id)
        }
        return resolved
    }
}
