import Foundation
import XCTest
@testable import WinterVoice

@MainActor
final class ProviderConfigurationTests: XCTestCase {
    func testConfiguredTranscriberRoutesAudioAndLanguageToRemoteProvider() async throws {
        let suite = "RemoteRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(defaults: defaults, credentials: CredentialStoreSpy())
        try store.saveRemote(.init(baseURL: "https://host.example/v1", model: "m"), apiKey: "secret")
        store.languageCode = "ru"
        let transport = RemoteTransportSpy(status: 200, body: #"{"text":"héllo wörld"}"#)
        let subject = ConfiguredTranscriber(
            recorder: AudioRecorderSpy(samples: [0.1, -0.1]),
            configuration: store,
            remoteProvider: RemoteTranscriptionProvider(transport: transport)
        )

        XCTAssertNoThrow(try subject.validateConfiguration())
        try await subject.start()
        let transcription = try await subject.stop()
        XCTAssertEqual(transcription, "héllo wörld")
        let capturedRequest = await transport.capturedRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nru"))
    }

    func testUnconfiguredRemoteFailsValidationBeforeRecording() throws {
        let suite = "RemoteValidationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let subject = ConfiguredTranscriber(
            recorder: AudioRecorderSpy(),
            configuration: ProviderConfigurationStore(defaults: defaults, credentials: CredentialStoreSpy())
        )

        XCTAssertThrowsError(try subject.validateConfiguration()) { error in
            XCTAssertEqual(
                (error as? DictationFailure)?.message,
                "Remote transcription provider is not configured."
            )
        }
    }

    func testLanguageSelectionPersistsAndAdoptsLegacyRemoteLanguage() throws {
        let suite = "LanguagePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(defaults: defaults, credentials: CredentialStoreSpy())
        XCTAssertNil(store.languageCode, "A fresh install defaults to auto-detect")
        store.languageCode = "vi"
        XCTAssertEqual(
            ProviderConfigurationStore(defaults: defaults, credentials: CredentialStoreSpy()).languageCode,
            "vi"
        )
        store.languageCode = nil
        XCTAssertNil(
            ProviderConfigurationStore(defaults: defaults, credentials: CredentialStoreSpy()).languageCode,
            "Returning to auto-detect must persist, not fall back to the legacy value"
        )

        // Pre-picker installs stored a free-text code inside the remote JSON;
        // a known code is adopted once, junk is dropped.
        for (legacy, expected) in [("VI ", "vi"), ("Vietnamese please", nil)] {
            let legacySuite = "\(suite).\(expected ?? "junk")"
            let legacyDefaults = try XCTUnwrap(UserDefaults(suiteName: legacySuite))
            defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
            let json = #"{"baseURL":"https://host.example/v1","model":"m","language":"\#(legacy)"}"#
            legacyDefaults.set(Data(json.utf8), forKey: "transcription.remote.configuration")
            let migrated = ProviderConfigurationStore(defaults: legacyDefaults, credentials: CredentialStoreSpy())
            XCTAssertEqual(migrated.languageCode, expected)
            XCTAssertEqual(migrated.remote.model, "m", "Migration must not disturb the remote configuration")
        }
    }

    func testRemoteConfigurationAndCredentialPersistAtTheirOwnedStores() throws {
        let suite = "ProviderConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = CredentialStoreSpy()
        let subject = ProviderConfigurationStore(defaults: defaults, credentials: credentials)

        try subject.saveRemote(
            .init(baseURL: "https://host.example/v1", model: "transcriber"),
            apiKey: "secret"
        )
        let restored = ProviderConfigurationStore(defaults: defaults, credentials: credentials)

        XCTAssertEqual(restored.remote.model, "transcriber")
        XCTAssertEqual(try restored.apiKey(), "secret")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { "\($0)".contains("secret") })
    }

    func testProviderStatusIsSingleTruthForUnconfiguredAndReadyRemote() throws {
        let suite = "ProviderStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = CredentialStoreSpy()
        let store = ProviderConfigurationStore(defaults: defaults, credentials: credentials)

        XCTAssertFalse(store.status().isReady)
        try store.saveRemote(.init(baseURL: "https://host.example/v1", model: "m"), apiKey: nil)
        XCTAssertTrue(store.status().isReady)
        XCTAssertTrue(store.status().readiness.detail.contains("without authentication"))
        try store.saveRemote(.init(baseURL: "https://host.example/v1", model: "m"), apiKey: "secret")
        let remote = store.status()
        XCTAssertTrue(remote.isReady)
        XCTAssertTrue(remote.overviewSummary.contains("Transcription is ready"))
        XCTAssertTrue(remote.privacySummary.contains("configured remote endpoint"))
        XCTAssertTrue(remote.readiness.detail.contains("saved API key"))
    }

    func testExplicitCredentialRemovalChangesStatusAndSubsequentRequestIsUnauthenticated() async throws {
        let suite = "CredentialRemovalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = CredentialStoreSpy()
        let store = ProviderConfigurationStore(defaults: defaults, credentials: credentials)
        try store.saveRemote(.init(baseURL: "https://host.example/v1", model: "m"), apiKey: "secret")

        try store.saveRemote(store.remote, apiKey: nil)
        XCTAssertEqual(try store.apiKey(), "secret", "Blank ordinary save preserves the existing key")
        try store.removeAPIKey()

        XCTAssertFalse(store.hasAPIKey)
        XCTAssertNil(try store.apiKey())
        XCTAssertTrue(store.status().readiness.detail.contains("without authentication"))
        let transport = RemoteTransportSpy(status: 200, body: #"{"text":"ok"}"#)
        _ = try await RemoteTranscriptionProvider(transport: transport).transcribe(
            audio: .init(samples: [0], sampleRate: 16_000),
            configuration: store.remote,
            language: nil,
            apiKey: try store.apiKey()
        )
        let capturedRequest = await transport.capturedRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testFailedCredentialRemovalPreservesKeyAndAuthenticatedStatus() throws {
        let suite = "CredentialRemovalFailureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = CredentialStoreSpy(value: "secret", deleteError: TestFailure.expected)
        let store = ProviderConfigurationStore(defaults: defaults, credentials: credentials)
        try store.saveRemote(.init(baseURL: "https://host.example", model: "m"), apiKey: nil)

        XCTAssertThrowsError(try store.removeAPIKey())
        XCTAssertTrue(store.hasAPIKey)
        XCTAssertEqual(try store.apiKey(), "secret")
        XCTAssertTrue(store.status().readiness.detail.contains("saved API key"))
    }

    func testFileCredentialStoreRoundTripsAndDeletes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wv-credentials-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = FileCredentialStore(root: root)
        XCTAssertNil(try subject.read())
        try subject.write("secret-key")
        XCTAssertEqual(try subject.read(), "secret-key")
        try subject.write("rotated")
        XCTAssertEqual(try subject.read(), "rotated")
        try subject.delete()
        XCTAssertNil(try subject.read())
        try subject.delete()
    }

    func testFileCredentialStoreWritesOwnerOnlyPermissionsAndTrimsWhitespace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wv-credentials-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = FileCredentialStore(root: root)
        try subject.write("  padded-key\n")
        XCTAssertEqual(try subject.read(), "padded-key")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("remote-api-key").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
        try subject.write("   \n")
        XCTAssertNil(try subject.read())
    }
}

final class RemoteProviderTests: XCTestCase {
    func testEndpointAllowsHTTPSAndExplicitPrivateHTTPOnly() throws {
        XCTAssertEqual(
            try RemoteTranscriptionProvider.endpoint(for: .init(baseURL: "https://host.example/v1", model: "m")).path,
            "/v1/audio/transcriptions"
        )
        XCTAssertNoThrow(try RemoteTranscriptionProvider.endpoint(for: .init(baseURL: "http://192.168.1.4:9000/v1", model: "m")))
        XCTAssertThrowsError(try RemoteTranscriptionProvider.endpoint(for: .init(baseURL: "http://public.example/v1", model: "m")))
        XCTAssertThrowsError(try RemoteTranscriptionProvider.endpoint(for: .init(baseURL: "https://user:password@host.example/v1", model: "m")))
        XCTAssertThrowsError(try RemoteTranscriptionProvider.endpoint(for: .init(baseURL: "https://host.example/v1#secret", model: "m")))
        let queryEndpoint = try RemoteTranscriptionProvider.endpoint(for: .init(baseURL: "https://host.example/v1?deployment=a", model: "m"))
        XCTAssertEqual(queryEndpoint.query, "deployment=a", "Non-secret endpoint query parameters are deliberately preserved")
    }

    func testIsLocalOrLANRequiresHostToBeAnIPLiteralOrLocalName() {
        for host in ["localhost", "myhost.local", "127.0.0.1", "10.0.0.5", "192.168.1.4", "172.16.0.1", "::1", "[::1]"] {
            XCTAssertTrue(RemoteTranscriptionProvider.isLocalOrLAN(host), "Expected \(host) to count as local/LAN")
        }
        for host in ["10.1.2.3.attacker.com", "8.8.8.8", "172.32.0.1", "public.example"] {
            XCTAssertFalse(RemoteTranscriptionProvider.isLocalOrLAN(host), "Expected \(host) to be rejected")
        }
        XCTAssertThrowsError(
            try RemoteTranscriptionProvider.endpoint(for: .init(baseURL: "http://10.1.2.3.attacker.com/v1", model: "m")),
            "A public DNS name embedding a private IP must not unlock plain HTTP"
        )
        XCTAssertNoThrow(try RemoteTranscriptionProvider.endpoint(for: .init(baseURL: "http://[::1]:8080/v1", model: "m")))
    }

    func testMultipartRequestAndStandardTextResponse() async throws {
        let transport = RemoteTransportSpy(status: 200, body: #"{"text":"hello"}"#)
        let subject = RemoteTranscriptionProvider(transport: transport)
        let configuration = RemoteProviderConfiguration(baseURL: "https://host.example/v1", model: "model-a")

        let text = try await subject.transcribe(
            audio: .init(samples: [0, 0.5], sampleRate: 16_000),
            configuration: configuration,
            language: "vi",
            apiKey: "test-key"
        )

        XCTAssertEqual(text, "hello")
        let capturedRequest = await transport.request
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nmodel-a"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nvi"))
        XCTAssertTrue(body.contains("filename=\"audio.wav\""))
    }

    func testUnauthenticatedEndpointSendsNoAuthorizationHeader() async throws {
        let transport = RemoteTransportSpy(status: 200, body: #"{"text":"hello"}"#)
        let subject = RemoteTranscriptionProvider(transport: transport)

        _ = try await subject.transcribe(
            audio: .init(samples: [0], sampleRate: 16_000),
            configuration: .init(baseURL: "http://localhost:8080/v1", model: " local-model "),
            language: nil,
            apiKey: nil
        )

        let capturedRequest = await transport.request
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("\r\n\r\nlocal-model\r\n"))
        XCTAssertFalse(body.contains("name=\"language\""), "Auto-detect must omit the language field entirely")
    }

    func testMultipartFieldsRejectEmptyModelAndLineBreakInjection() {
        let endpoint = URL(string: "https://host.example/audio/transcriptions")!
        for configuration in [
            RemoteProviderConfiguration(baseURL: "https://host.example", model: "  "),
            RemoteProviderConfiguration(baseURL: "https://host.example", model: "\r\nmodel"),
            RemoteProviderConfiguration(baseURL: "https://host.example", model: "model\r\n--injected")
        ] {
            XCTAssertThrowsError(try RemoteTranscriptionProvider.makeRequest(
                endpoint: endpoint,
                audio: .init(samples: [0], sampleRate: 16_000),
                configuration: configuration,
                language: nil,
                apiKey: nil,
                boundary: "boundary"
            ), "Expected rejection for model=\(configuration.model.debugDescription)")
        }
    }

    func testUnknownLanguageCodeIsDroppedFromMultipartBody() throws {
        let request = try RemoteTranscriptionProvider.makeRequest(
            endpoint: URL(string: "https://host.example/audio/transcriptions")!,
            audio: .init(samples: [0], sampleRate: 16_000),
            configuration: .init(baseURL: "https://host.example", model: "model"),
            language: "vi\r\n--injected",
            apiKey: nil,
            boundary: "boundary"
        )
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"language\""), "Codes outside the picker list must never reach the body")
    }

    func testAuthAndInvalidResponsesMapWithoutLeakingBody() async {
        for (status, body, expected) in [
            (401, "key=secret", "Remote authentication failed."),
            (200, "not-json", "The remote provider returned an invalid response.")
        ] {
            let subject = RemoteTranscriptionProvider(transport: RemoteTransportSpy(status: status, body: body))
            do {
                _ = try await subject.transcribe(
                    audio: .init(samples: [0], sampleRate: 16_000),
                    configuration: .init(baseURL: "https://host.example", model: "m"),
                    language: nil,
                    apiKey: "secret"
                )
                XCTFail("Expected failure")
            } catch let failure as DictationFailure {
                XCTAssertEqual(failure.message, expected)
                XCTAssertFalse(failure.message.contains("secret"))
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testConnectionProbeAcceptsEmptyTranscriptionAndSendsRealAudioPayload() async throws {
        let transport = RemoteTransportSpy(status: 200, body: #"{"text":""}"#)
        let subject = RemoteTranscriptionProvider(transport: transport)

        try await subject.testConnection(
            configuration: .init(baseURL: "https://host.example/v1", model: "m"),
            apiKey: "probe-key"
        )

        XCTAssertEqual(RemoteTranscriptionProvider.connectionProbeAudio.samples.count, 3_200)
        XCTAssertEqual(RemoteTranscriptionProvider.connectionProbeAudio.sampleRate, 16_000)
        let capturedRequest = await transport.request
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer probe-key")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertNotNil(body.range(of: Data("filename=\"audio.wav\"".utf8)))
        XCTAssertGreaterThan(body.count, 12_800, "The probe carries 0.2 s of 16 kHz audio (3,200 four-byte samples)")
    }

    func testConnectionProbeMapsAuthenticationFailureLikeTranscription() async {
        let subject = RemoteTranscriptionProvider(transport: RemoteTransportSpy(status: 401, body: "key=secret"))
        do {
            try await subject.testConnection(
                configuration: .init(baseURL: "https://host.example/v1", model: "m"),
                apiKey: "secret"
            )
            XCTFail("Expected failure")
        } catch let failure as DictationFailure {
            XCTAssertEqual(failure.message, "Remote authentication failed.")
            XCTAssertFalse(failure.message.contains("secret"))
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testConnectionProbeWithoutKeySendsNoAuthorizationHeader() async throws {
        let transport = RemoteTransportSpy(status: 200, body: #"{"text":"ok"}"#)

        try await RemoteTranscriptionProvider(transport: transport).testConnection(
            configuration: .init(baseURL: "http://localhost:8080/v1", model: "m"),
            apiKey: nil
        )

        let capturedRequest = await transport.request
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
}

private enum TestFailure: Error { case expected }

@MainActor
private final class AudioRecorderSpy: AudioRecording {
    private let samples: [Float]
    init(samples: [Float] = []) { self.samples = samples }
    func start() throws {}
    func stop() throws -> RecordedAudio { RecordedAudio(samples: samples, sampleRate: 16_000) }
    func cancel() {}
}

private final class CredentialStoreSpy: CredentialStoring {
    var value: String?
    var deleteError: Error?
    init(value: String? = nil, deleteError: Error? = nil) {
        self.value = value
        self.deleteError = deleteError
    }
    func read() throws -> String? { value }
    func write(_ value: String) throws { self.value = value }
    func delete() throws {
        if let deleteError { throw deleteError }
        value = nil
    }
}


private actor RemoteTransportSpy: RemoteTransport {
    let status: Int
    let body: String
    private(set) var request: URLRequest?

    init(status: Int, body: String) {
        self.status = status
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func capturedRequest() -> URLRequest? { request }
}
