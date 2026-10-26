import Foundation

@MainActor
protocol RemoteConnectionTesting: AnyObject {
    func test(configuration: RemoteProviderConfiguration, apiKey: String?) async throws
}

@MainActor
final class RemoteConnectionTester: RemoteConnectionTesting {
    private let provider: RemoteTranscriptionProvider

    init(provider: RemoteTranscriptionProvider = .init()) {
        self.provider = provider
    }

    func test(configuration: RemoteProviderConfiguration, apiKey: String?) async throws {
        try await provider.testConnection(configuration: configuration, apiKey: apiKey)
    }
}

/// Owns the Transcription page's remote-configuration flow so the view only
/// renders state and emits actions; HTTP, credential storage, and persistence never run
/// in view code.
@MainActor
final class TranscriptionSettingsController: ObservableObject {
    @Published var kind: RemoteProviderKind = .openAICompatible
    @Published var baseURL = ""
    @Published var remoteModel = ""
    @Published var apiKey = ""
    @Published private(set) var remoteResult: String?

    private let configuration: ProviderConfigurationStore
    private let connectionTester: RemoteConnectionTesting
    private var testTask: Task<Void, Never>?

    init(
        configuration: ProviderConfigurationStore,
        connectionTester: RemoteConnectionTesting? = nil
    ) {
        self.configuration = configuration
        self.connectionTester = connectionTester ?? RemoteConnectionTester()
    }

    var draft: RemoteProviderConfiguration {
        .init(kind: kind, baseURL: baseURL, model: remoteModel)
    }

    func loadRemoteDraft() {
        kind = configuration.remote.kind
        baseURL = configuration.remote.baseURL
        remoteModel = configuration.remote.model
    }

    /// The typed key as it would be stored. A ChatGPT token must parse as an
    /// access token and loses a pasted "Bearer " prefix.
    private func validatedTypedKey() throws -> String? {
        guard !apiKey.isEmpty else { return nil }
        guard kind == .chatGPTWeb else { return apiKey }
        guard let token = ChatGPTAccessToken(apiKey) else {
            throw DictationFailure(message: "That is not a ChatGPT access token.", recovery: ChatGPTAccessToken.recovery)
        }
        return token.value
    }

    func saveRemote() {
        do {
            let typedKey = try validatedTypedKey()
            _ = try RemoteTranscriptionProvider.endpoint(for: draft)
            try configuration.saveRemote(draft, apiKey: typedKey)
            apiKey = ""
            remoteResult = "Configuration saved."
        } catch let failure as DictationFailure {
            remoteResult = failure.message
        } catch {
            remoteResult = "Could not save the configuration."
        }
    }

    /// Tests the DRAFT configuration. Testing must never persist the draft or
    /// persist the typed key — only Save Configuration commits.
    func testRemoteConnection() {
        let draft = draft
        let typedKey: String
        do {
            typedKey = try validatedTypedKey() ?? ""
            _ = try RemoteTranscriptionProvider.endpoint(for: draft)
        } catch let failure as DictationFailure {
            remoteResult = failure.message
            return
        } catch {
            remoteResult = "Configuration is invalid."
            return
        }
        remoteResult = "Testing connection…"
        testTask?.cancel()
        testTask = Task { [weak self] in
            guard let self else { return }
            let key: String?
            if typedKey.isEmpty {
                do {
                    key = try self.configuration.apiKey()
                } catch let failure as DictationFailure {
                    self.remoteResult = failure.message
                    return
                } catch {
                    self.remoteResult = "Could not read the API key."
                    return
                }
            } else {
                key = typedKey
            }
            do {
                try await self.connectionTester.test(configuration: draft, apiKey: key)
                guard !Task.isCancelled else { return }
                self.remoteResult = "Connected successfully. Use Save Configuration to keep these settings."
            } catch let failure as DictationFailure {
                guard !Task.isCancelled else { return }
                self.remoteResult = failure.message
            } catch {
                guard !Task.isCancelled else { return }
                self.remoteResult = "Connection test failed."
            }
        }
    }

    func removeAPIKey() {
        do {
            try configuration.removeAPIKey()
            apiKey = ""
            remoteResult = kind == .chatGPTWeb
                ? "Access token removed."
                : "API key removed. Remote requests will use no authentication."
        } catch let failure as DictationFailure {
            remoteResult = failure.message
        } catch {
            remoteResult = "Could not remove the API key."
        }
    }
}
