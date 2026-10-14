import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingEditor = false
    @State private var draft = Endpoint.starter
    @State private var prompt = "Explain why this endpoint is useful in one sentence."
    @State private var systemPrompt = ""
    @State private var temperature = 0.7
    @State private var maxTokens = 512
    @State private var thinking = false
    @State private var streaming = true
    @State private var documents = "Paris is the capital of France.\nBerlin is the capital of Germany."
    @State private var imageDataURL: String?
    @State private var followResponse = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            mainPanel
        }
        .frame(minWidth: 900, minHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingEditor) { EndpointEditor(endpoint: draft) { store.save($0) } }
        .alert("API Tester error", isPresented: Binding(get: { store.errorMessage != nil && !showingEditor }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("API Tester", systemImage: "network")
                    .font(.headline)
                Spacer()
                Button { store.addEndpoint(); if let endpoint = store.selectedEndpoint { draft = endpoint; showingEditor = true } } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add endpoint")
            }
            .padding(16)
            Divider()
            Text("ENDPOINTS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 14)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.endpoints) { endpoint in
                        EndpointRow(endpoint: endpoint, isSelected: store.selectedEndpointID == endpoint.id) {
                            store.selectedEndpointID = endpoint.id
                        } onBookmark: { store.toggleBookmark(endpoint) }
                    }
                }.padding(10)
            }
            Spacer()
            if let endpoint = store.selectedEndpoint {
                HStack {
                    Circle().fill(endpoint.enabled ? .green : .gray).frame(width: 7, height: 7)
                    Text(endpoint.enabled ? "Enabled" : "Disabled").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit") { draft = endpoint; showingEditor = true }.buttonStyle(.borderless)
                }.padding(14)
            }
        }
        .frame(width: 235)
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            if let endpoint = store.selectedEndpoint {
                header(endpoint)
                Divider()
                modePicker
                Divider()
                requestForm(endpoint)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "network.slash").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("No endpoint").font(.headline)
                    Text("Add an endpoint to begin testing.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func header(_ endpoint: Endpoint) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(endpoint.name).font(.title3.weight(.semibold))
                Text(endpoint.baseURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { Task { await store.fetchModels(for: endpoint) } } label: {
                Label(store.isFetchingModels ? "Fetching…" : "Fetch models", systemImage: "arrow.triangle.2.circlepath")
            }.disabled(store.isFetchingModels)
            Button { draft = endpoint; showingEditor = true } label: { Image(systemName: "slider.horizontal.3") }.help("Edit endpoint")
            Button(role: .destructive) { store.removeSelected() } label: { Image(systemName: "trash") }.help("Remove endpoint")
        }.padding(18)
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(TestMode.allCases) { mode in
                Button { store.selectedMode = mode } label: {
                    Label(mode.rawValue, systemImage: mode.icon)
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.selectedMode == mode ? Color.accentColor : .secondary)
                .background(store.selectedMode == mode ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            }
        }.padding(10)
    }

    private func requestForm(_ endpoint: Endpoint) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Model").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Model", selection: Binding(get: { endpoint.selectedModel }, set: { value in var copy = endpoint; copy.selectedModel = value; store.save(copy) })) {
                    if endpoint.models.isEmpty { Text("Fetch models or enter one").tag("") }
                    ForEach(endpoint.models, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(maxWidth: 220)
                TextField("or enter model ID", text: Binding(get: { endpoint.selectedModel }, set: { value in var copy = endpoint; copy.selectedModel = value; store.save(copy) }))
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                Spacer()
                if store.selectedMode == .chat || store.selectedMode == .multimodal {
                    Toggle("Thinking", isOn: $thinking).toggleStyle(.switch).controlSize(.small)
                    Toggle("Stream", isOn: $streaming).toggleStyle(.switch).controlSize(.small)
                }
            }
            if store.selectedMode == .chat || store.selectedMode == .multimodal {
                Text("System prompt").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: $systemPrompt).font(.body).frame(height: 48).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            }
            Text(store.selectedMode == .rerank ? "Query" : "Prompt").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $prompt).font(.body).frame(minHeight: store.selectedMode == .rerank ? 60 : 105).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            if store.selectedMode == .rerank {
                Text("Documents · one per line").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: $documents).font(.body).frame(height: 75).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            }
            if store.selectedMode == .multimodal {
                HStack { Label(imageDataURL == nil ? "No image attached" : "Image attached", systemImage: "photo").foregroundStyle(.secondary); Spacer(); Button("Attach image…") { chooseImage() } }
            }
            if store.selectedMode == .chat || store.selectedMode == .multimodal {
                HStack {
                    LabeledContent("Temperature") { Slider(value: $temperature, in: 0...2, step: 0.1).frame(width: 150); Text(temperature, format: .number.precision(.fractionLength(1))).monospacedDigit().frame(width: 28) }
                    Divider().frame(height: 20)
                    LabeledContent("Max tokens") { Stepper(value: $maxTokens, in: 1...32768, step: 128) { Text("\(maxTokens)").monospacedDigit() } }
                    Spacer()
                }.font(.caption)
            }
            HStack {
                Text(store.resultStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.isRunning {
                    Button { store.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                }
                Button { Task { await store.run(endpoint: endpoint, model: endpoint.selectedModel, prompt: prompt, system: systemPrompt, temperature: temperature, maxTokens: maxTokens, thinking: thinking, streaming: streaming, imageDataURL: imageDataURL, documents: documents) } } label: {
                    Label(store.isRunning ? "Running…" : "Run test", systemImage: "play.fill")
                }.buttonStyle(.borderedProminent).disabled(store.isRunning || !endpoint.enabled)
            }
            Divider()
            HStack {
                Text("Response").font(.headline)
                if store.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Toggle("Follow", isOn: $followResponse).toggleStyle(.checkbox).font(.caption)
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.resultText, forType: .string) }.buttonStyle(.borderless)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(store.resultText.isEmpty && store.isRunning ? "Waiting for response…" : store.resultText)
                            .font(store.isStreamingResponse ? .body : .system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("response-text")
                        Color.clear.frame(height: 1).id("response-bottom")
                    }.padding(10)
                }
                .onChange(of: store.resultText) { _ in
                    if followResponse { proxy.scrollTo("response-bottom", anchor: .bottom) }
                }
                .onChange(of: followResponse) { follow in
                    if follow { proxy.scrollTo("response-bottom", anchor: .bottom) }
                }
            }.background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8)).frame(maxHeight: .infinity)
        }.padding(18)
    }

    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        imageDataURL = "data:\(url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg");base64,\(data.base64EncodedString())"
    }
}

private struct EndpointRow: View {
    let endpoint: Endpoint; let isSelected: Bool; let select: () -> Void; let onBookmark: () -> Void
    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                Circle().fill(endpoint.enabled ? .green : .gray).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) { Text(endpoint.name).lineLimit(1); Text(endpoint.baseURL).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if endpoint.bookmarked { Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(.orange) }
            }.padding(8)
        }.buttonStyle(.plain).background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contextMenu { Button(endpoint.bookmarked ? "Remove bookmark" : "Bookmark", action: onBookmark) }
    }
}

private struct EndpointEditor: View {
    @State var endpoint: Endpoint
    let onSave: (Endpoint) -> Bool
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(endpoint.id == Endpoint.starter.id ? "Edit endpoint" : "Endpoint settings").font(.title2.weight(.semibold))
            Form {
                TextField("Display name", text: $endpoint.name)
                TextField("Base URL", text: $endpoint.baseURL)
                SecureField("API key (stored in Keychain)", text: $endpoint.apiKey)
                    .accessibilityIdentifier("endpoint-api-key")
                Text(endpoint.apiKey.isEmpty ? "No API key. Leave empty for endpoints that do not require authentication." : "API key configured. Clear this field and Save to remove it.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Enabled", isOn: $endpoint.enabled)
                Toggle("Bookmarked", isOn: $endpoint.bookmarked)
            }.formStyle(.grouped)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { if onSave(endpoint) { dismiss() } }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 480)
            .alert("Could not save endpoint", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
    }
}
