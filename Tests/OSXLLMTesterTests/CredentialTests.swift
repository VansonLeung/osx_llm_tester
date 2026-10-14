import Testing
import Foundation
import Security
@testable import OSXLLMTester

private final class MemoryCredentials: CredentialStore {
    var values: [UUID: String] = [:]
    var failSave = false
    var failRead = false
    var writes = 0

    func save(_ value: String, for id: UUID) throws {
        if failSave { throw KeychainError(operation: "save", status: errSecAuthFailed) }
        writes += 1
        values[id] = value
    }
    func read(for id: UUID) throws -> String {
        if failRead { throw KeychainError(operation: "read", status: errSecAuthFailed) }
        return values[id] ?? ""
    }
    func remove(for id: UUID) throws { values.removeValue(forKey: id) }
}

private final class AuthorizedResponse: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key"
        let body = request.url?.path.hasSuffix("models") == true
            ? "{\"data\":[{\"id\":\"test-model\"}]}"
            : "{\"choices\":[{\"message\":{\"content\":\"authenticated\"}}]}"
        let response = HTTPURLResponse(url: request.url!, statusCode: authorized ? 200 : 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((authorized ? body : "Missing key").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct CredentialTests {
    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "com.osxllmtester.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @MainActor
    @Test
    func testSavePersistsSecretAndKeepsItOutOfEndpointJSON() async throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = MemoryCredentials()
        let store = AppStore(defaults: defaults, credentials: credentials)
        var endpoint = try #require(store.selectedEndpoint)
        endpoint.apiKey = "test-only-key"
        #expect(store.save(endpoint))
        #expect(store.selectedEndpoint?.apiKey == endpoint.apiKey)
        #expect(credentials.values[endpoint.id] == endpoint.apiKey)
        let data = try #require(defaults.data(forKey: "saved-endpoints-v1"))
        #expect(!String(decoding: data, as: UTF8.self).contains(endpoint.apiKey))
        let restored = AppStore(defaults: defaults, credentials: credentials)
        #expect(restored.selectedEndpoint?.apiKey == endpoint.apiKey)
    }

    @MainActor
    @Test
    func testMetadataChangesPreserveKeyAndClearingFieldRemovesIt() async throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = MemoryCredentials()
        let store = AppStore(defaults: defaults, credentials: credentials)
        var endpoint = try #require(store.selectedEndpoint)
        endpoint.apiKey = "test-only-key"
        #expect(store.save(endpoint))
        store.toggleBookmark(endpoint)
        endpoint = try #require(store.selectedEndpoint)
        endpoint.selectedModel = "manual-model"
        #expect(store.save(endpoint))
        #expect(credentials.writes == 1)
        #expect(store.selectedEndpoint?.apiKey == "test-only-key")
        endpoint.apiKey = "replacement-test-key"
        #expect(store.save(endpoint))
        #expect(credentials.values[endpoint.id] == "replacement-test-key")
        endpoint.apiKey = ""
        #expect(store.save(endpoint))
        #expect(AppStore(defaults: defaults, credentials: credentials).selectedEndpoint?.apiKey == "")
    }

    @MainActor
    @Test
    func testFailedSaveRetainsPreviouslySavedEndpointAndKey() async throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = MemoryCredentials()
        let store = AppStore(defaults: defaults, credentials: credentials)
        var endpoint = try #require(store.selectedEndpoint)
        endpoint.apiKey = "test-only-key"
        #expect(store.save(endpoint))
        let originalData = defaults.data(forKey: "saved-endpoints-v1")
        credentials.failSave = true
        endpoint.apiKey = "replacement-test-key"
        endpoint.name = "Should not be committed"
        #expect(!store.save(endpoint))
        #expect(store.selectedEndpoint?.apiKey == "test-only-key")
        #expect(credentials.values[endpoint.id] == "test-only-key")
        #expect(defaults.data(forKey: "saved-endpoints-v1") == originalData)
        #expect(store.errorMessage != nil)
    }

    @MainActor
    @Test
    func testModelDiscoveryAndChatAuthenticateAfterSaveAndRestart() async throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = MemoryCredentials()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthorizedResponse.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)
        let store = AppStore(defaults: defaults, credentials: credentials, client: client)
        let staleEndpoint = try #require(store.selectedEndpoint)
        var endpoint = staleEndpoint
        endpoint.baseURL = "https://test.invalid/v1"
        endpoint.apiKey = "test-only-key"
        #expect(store.save(endpoint))
        await store.fetchModels(for: staleEndpoint)
        #expect(store.errorMessage == nil)
        #expect(store.selectedEndpoint?.models == ["test-model"])
        #expect(credentials.writes == 1)
        await store.run(endpoint: staleEndpoint, model: "test-model", prompt: "Hello", system: "", temperature: 0.7, maxTokens: 32, thinking: false, streaming: false, imageDataURL: nil, documents: "")
        #expect(store.errorMessage == nil)
        #expect(store.resultText.contains("authenticated"))
        let restored = AppStore(defaults: defaults, credentials: credentials, client: client)
        await restored.fetchModels(for: try #require(restored.selectedEndpoint))
        #expect(restored.errorMessage == nil)
        await restored.run(endpoint: try #require(restored.selectedEndpoint), model: "test-model", prompt: "Hello", system: "", temperature: 0.7, maxTokens: 32, thinking: false, streaming: false, imageDataURL: nil, documents: "")
        #expect(restored.errorMessage == nil)
        #expect(restored.resultText.contains("authenticated"))
    }

    @MainActor
    @Test
    func testUnreadableCredentialIsNotClearedByMetadataEdits() async throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = MemoryCredentials()
        let store = AppStore(defaults: defaults, credentials: credentials)
        var endpoint = try #require(store.selectedEndpoint)
        endpoint.apiKey = "test-only-key"
        #expect(store.save(endpoint))
        credentials.failRead = true
        let restored = AppStore(defaults: defaults, credentials: credentials)
        #expect(restored.errorMessage != nil)
        restored.toggleBookmark(try #require(restored.selectedEndpoint))
        #expect(credentials.values[endpoint.id] == "test-only-key")
        await restored.fetchModels(for: try #require(restored.selectedEndpoint))
        #expect(restored.errorMessage?.contains("Keychain") == true)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_KEYCHAIN_TESTS"] == "1", "Set RUN_KEYCHAIN_TESTS=1 to verify Keychain with a disposable test item."))
    func testRealKeychainPersistsAcrossStoreRecreationAndUpdates() async throws {
        let (defaults, name) = isolatedDefaults()
        let credentials = KeychainStore()
        let id = UUID()
        defer {
            try? credentials.remove(for: id)
            defaults.removePersistentDomain(forName: name)
        }
        let store = AppStore(defaults: defaults, credentials: credentials)
        var endpoint = Endpoint(id: id, name: "Credential test", baseURL: "https://test.invalid/v1", apiKey: "test-only-key", models: [], selectedModel: "", enabled: true, bookmarked: false)
        #expect(store.save(endpoint))
        let restored = AppStore(defaults: defaults, credentials: credentials)
        #expect(restored.endpoints.first { $0.id == id }?.apiKey == "test-only-key")
        endpoint.apiKey = "replacement-test-key"
        #expect(restored.save(endpoint))
        #expect(try credentials.read(for: id) == endpoint.apiKey)
        endpoint.apiKey = ""
        #expect(restored.save(endpoint))
        #expect(try credentials.read(for: id) == "")
    }
}
