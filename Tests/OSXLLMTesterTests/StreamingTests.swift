import Foundation
import Testing
@testable import OSXLLMTester

private struct NoCredentials: CredentialStore {
    func save(_ value: String, for id: UUID) throws {}
    func read(for id: UUID) throws -> String { "test-only-key" }
    func remove(for id: UUID) throws {}
}

/// Sends delayed and fragmented bytes so tests cannot pass by buffering to EOF.
private final class StreamingResponse: URLProtocol {
    private var producer: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        producer = Task { [self] in
            let path = request.url!.path
            let httpError = path.contains("http-error")
            let json = path.contains("json")
            let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key"
            let status = authorized ? (httpError ? 429 : 200) : 401
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": json || status != 200 ? "application/json" : "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            do {
                if status != 200 {
                    send("{\"error\":{\"message\":\"Rate limit test\"}}")
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                if json {
                    send("{\"choices\":[{\"message\":{\"content\":\"Hello world\"}}]}")
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                send(": keep-alive\r\nevent: message\r\n\r\n")
                send(delta("Hel"))
                try await Task.sleep(nanoseconds: 60_000_000)
                // Split a UTF-8 emoji and an SSE JSON line across network deliveries.
                let chunk = Data(delta("lo 👋 ").utf8)
                let split = chunk.firstIndex(of: 0xF0)! + 1
                client?.urlProtocol(self, didLoad: Data(chunk[..<split]))
                try await Task.sleep(nanoseconds: 20_000_000)
                client?.urlProtocol(self, didLoad: Data(chunk[split...]))
                try await Task.sleep(nanoseconds: path.contains("slow") ? 2_000_000_000 : 200_000_000)
                if path.contains("stream-error") {
                    send("data: {\"error\":{\"message\":\"Stream test failure\"}}\n\n")
                } else {
                    send(delta("world\n你好!"))
                    send("data: {\"choices\":[],\"usage\":{\"total_tokens\":8}}\n\n")
                    send("data: [DONE]\n\n")
                }
                // A compliant client must finish at [DONE], without waiting for EOF.
                try await Task.sleep(nanoseconds: 2_000_000_000)
                client?.urlProtocolDidFinishLoading(self)
            } catch { /* Stop cancels the producer. */ }
        }
    }

    override func stopLoading() { producer?.cancel() }

    private func send(_ text: String) { client?.urlProtocol(self, didLoad: Data(text.utf8)) }
    private func delta(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": ["content": text]]]])
        return "data: \(String(decoding: data, as: UTF8.self))\r\n\r\n"
    }
}

struct StreamingTests {
    @Test
    func decoderHandlesMetadataMultilineAndErrors() throws {
        var decoder = ChatStreamDecoder()
        #expect(try decoder.consume(": heartbeat") == nil)
        #expect(try decoder.consume("event: message") == nil)
        #expect(try decoder.consume("data: {\"choices\": [{\"delta\": {\"role\": \"assistant\"}}]}") == nil)
        #expect(try decoder.consume("data: {\"choices\": [") == nil)
        #expect(try decoder.consume("data: {\"index\":0,\"delta\":{\"content\":\"Hello 👋\"}}]}") == .text("Hello 👋"))
        #expect(try decoder.consume("data: {\"choices\":[],\"usage\":{\"total_tokens\":10}}") == nil)
        #expect(try decoder.consume("data: [DONE]") == .done)
        #expect(throws: APIClientError.self) {
            try decoder.consume("data: {\"error\":{\"message\":\"Test failure\"}}")
        }
    }

    @Test
    func wordBufferJoinsTokensPreservesWhitespaceAndFlushesLastWord() {
        var buffer = WordStreamBuffer()
        buffer.append("Hel")
        #expect(buffer.next(finishing: false) == nil)
        buffer.append("lo  world\n\nlast")
        #expect(buffer.next(finishing: false) == "Hello  ")
        #expect(buffer.next(finishing: false) == "world\n\n")
        #expect(buffer.next(finishing: false) == nil)
        #expect(buffer.next(finishing: true) == "last")
        #expect(buffer.next(finishing: true) == nil)
        buffer.append(" 你好 世界👋\n")
        var result = ""
        var pieces = 0
        while let word = buffer.next(finishing: true) { result += word; pieces += 1 }
        #expect(result == " 你好 世界👋\n")
        #expect(pieces >= 4)
    }

    @MainActor
    @Test
    func rendererRevealsWordsSeparatelyAndStopKeepsPartialText() async throws {
        var visible = ""
        var updates: [String] = []
        let renderer = WordStreamRenderer(interval: 10_000_000) { word in
            visible += word
            updates.append(visible)
        }
        renderer.append("one two three")
        await renderer.finish()
        #expect(updates == ["one ", "one two ", "one two three"])
        var stopped = ""
        let cancellable = WordStreamRenderer(interval: 50_000_000) { stopped += $0 }
        cancellable.append("first second third fourth")
        try await Task.sleep(nanoseconds: 10_000_000)
        cancellable.cancel()
        let partial = stopped
        await cancellable.finish()
        #expect(stopped == partial)
        #expect(stopped == "first ")
    }

    @MainActor
    @Test
    func liveStreamUpdatesBeforeCompletionAndStopsAtDone() async throws {
        let fixture = makeStore("paced")
        defer { fixture.cleanUp() }
        let store = fixture.store
        let endpoint = try #require(store.selectedEndpoint)
        let started = Date()
        let run = Task { await runStream(store, endpoint) }
        defer { run.cancel(); store.stop() }
        try await waitUntil { store.isRunning && store.resultText.hasPrefix("Hello ") }
        #expect(store.isRunning)
        #expect(store.resultText.hasPrefix("Hello "))
        #expect(!store.resultText.contains("world"))
        #expect(store.resultStatus == "Streaming…")
        await run.value
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(store.resultText == "Hello 👋 world\n你好!")
        #expect(!store.isRunning)
        #expect(store.errorMessage == nil)
        #expect(store.resultStatus.hasPrefix("HTTP 200"))
    }

    @MainActor
    @Test
    func stopCancelsNetworkAndAllowsAnotherRequest() async throws {
        let fixture = makeStore("slow")
        defer { fixture.cleanUp() }
        let store = fixture.store
        let endpoint = try #require(store.selectedEndpoint)
        let run = Task { await runStream(store, endpoint) }
        defer { run.cancel(); store.stop() }
        try await waitUntil { store.isRunning && store.resultText.hasPrefix("Hello ") }
        store.stop()
        let partial = store.resultText
        await run.value
        #expect(store.resultStatus == "Stopped")
        #expect(store.errorMessage == nil)
        #expect(store.resultText == partial)
        #expect(!store.isRunning)
        var next = endpoint
        next.baseURL = "https://stream.invalid/json"
        #expect(store.save(next))
        await runStream(store, next)
        #expect(store.resultText == "Hello world")
        #expect(store.errorMessage == nil)
    }

    @MainActor
    @Test
    func streamErrorsKeepPartialResponseAndHTTPDetails() async throws {
        let fixture = makeStore("stream-error")
        defer { fixture.cleanUp() }
        let store = fixture.store
        await runStream(store, try #require(store.selectedEndpoint))
        #expect(store.resultText == "Hello 👋 ")
        #expect(store.errorMessage == "Stream test failure")
        #expect(!store.isRunning)
        var endpoint = try #require(store.selectedEndpoint)
        endpoint.baseURL = "https://stream.invalid/http-error"
        #expect(store.save(endpoint))
        await runStream(store, endpoint)
        #expect(store.resultText.isEmpty)
        #expect(store.errorMessage?.contains("HTTP 429") == true)
        #expect(store.errorMessage?.contains("Rate limit test") == true)
    }

    @MainActor
    private func runStream(_ store: AppStore, _ endpoint: Endpoint) async {
        await store.run(endpoint: endpoint, model: "test-model", prompt: "Hello", system: "", temperature: 0.7,
                        maxTokens: 32, thinking: false, streaming: true, imageDataURL: nil, documents: "")
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1.5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        try #require(condition(), "Expected a live response before the stream completed")
    }

    @MainActor
    private func makeStore(_ scenario: String) -> Fixture {
        let name = "com.osxllmtester.stream-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingResponse.self]
        let session = URLSession(configuration: config)
        let store = AppStore(defaults: defaults, credentials: NoCredentials(), client: APIClient(session: session))
        var endpoint = store.selectedEndpoint!
        endpoint.baseURL = "https://stream.invalid/\(scenario)"
        _ = store.save(endpoint)
        return Fixture(store: store, session: session, defaults: defaults, domain: name)
    }

    @MainActor
    private struct Fixture {
        let store: AppStore
        let session: URLSession
        let defaults: UserDefaults
        let domain: String
        func cleanUp() {
            store.stop()
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: domain)
        }
    }
}
