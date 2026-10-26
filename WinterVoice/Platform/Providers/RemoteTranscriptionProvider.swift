import Darwin
import Foundation

protocol RemoteTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: RemoteTransport {}

struct RemoteTranscriptionProvider: Sendable {
    private struct Response: Decodable { let text: String }
    private let transport: any RemoteTransport

    init(transport: any RemoteTransport = URLSession.shared) { self.transport = transport }

    static let chatGPTEndpoint = URL(string: "https://chatgpt.com/backend-api/transcribe")!

    static func endpoint(for configuration: RemoteProviderConfiguration) throws -> URL {
        if configuration.kind == .chatGPTWeb { return chatGPTEndpoint }
        _ = try validatedModel(for: configuration)
        let raw = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw), let host = components.host else {
            throw DictationFailure(message: "Enter a valid remote base URL.", recovery: "Use HTTPS, or explicit HTTP for localhost or a LAN address.")
        }
        guard components.user == nil, components.password == nil else {
            throw DictationFailure(message: "Remote URL credentials are not allowed.", recovery: "Enter the API key in Transcription settings instead.")
        }
        guard components.fragment == nil else {
            throw DictationFailure(message: "Remote URL fragments are not allowed.", recovery: "Remove the fragment and try again.")
        }
        let isHTTPS = components.scheme?.lowercased() == "https"
        let isHTTP = components.scheme?.lowercased() == "http"
        guard isHTTPS || (isHTTP && isLocalOrLAN(host)) else {
            throw DictationFailure(message: "That remote URL is not allowed.", recovery: "Use HTTPS. HTTP is allowed only for explicit localhost or LAN endpoints.")
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/audio/transcriptions") { path += "/audio/transcriptions" }
        components.path = path
        guard let endpoint = components.url else {
            throw DictationFailure(message: "Enter a valid remote base URL.", recovery: "Check the URL and try again.")
        }
        return endpoint
    }

    func transcribe(
        audio: RecordedAudio,
        configuration: RemoteProviderConfiguration,
        language: String?,
        apiKey: String?
    ) async throws -> String {
        let (data, response) = try await send(
            audio: audio,
            configuration: configuration,
            language: language,
            apiKey: apiKey
        )
        return try Self.decode(data: data, response: response, kind: configuration.kind)
    }

    /// Probes the given configuration without any side effects on stored
    /// settings: reachability, authentication, and response shape only.
    func testConnection(configuration: RemoteProviderConfiguration, apiKey: String?) async throws {
        let (data, response) = try await send(
            audio: Self.connectionProbeAudio,
            configuration: configuration,
            language: nil,
            apiKey: apiKey
        )
        try Self.validateConnectionTestResponse(data: data, response: response, kind: configuration.kind)
    }

    /// 0.2 s of silence: enough to satisfy providers that enforce a minimum
    /// audio duration (OpenAI rejects anything under 0.1 s).
    static var connectionProbeAudio: RecordedAudio {
        RecordedAudio(samples: [Float](repeating: 0, count: 3_200), sampleRate: 16_000)
    }

    private func send(
        audio: RecordedAudio,
        configuration: RemoteProviderConfiguration,
        language: String?,
        apiKey: String?
    ) async throws -> (Data, URLResponse) {
        let endpoint = try Self.endpoint(for: configuration)
        let request = try Self.makeRequest(
            endpoint: endpoint,
            audio: audio,
            configuration: configuration,
            language: language,
            apiKey: apiKey,
            boundary: "WinterVoice-\(UUID().uuidString)"
        )
        do { return try await transport.data(for: request) } catch {
            let nsError = error as NSError
            if error is CancellationError
                || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                throw CancellationError()
            }
            throw DictationFailure(message: "Could not reach the remote provider.", recovery: "Check the endpoint and network connection.")
        }
    }

    static func makeRequest(
        endpoint: URL,
        audio: RecordedAudio,
        configuration: RemoteProviderConfiguration,
        language: String?,
        apiKey: String?,
        boundary: String
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let fields: [(String, String)]
        switch configuration.kind {
        case .openAICompatible:
            let model = try validatedModel(for: configuration)
            if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            // The language comes from the fixed picker list, never free text;
            // an unknown value is dropped rather than sent.
            let knownLanguage = language.flatMap { TranscriptionLanguage.isKnown($0) ? $0 : nil }
            fields = [("model", model)] + (knownLanguage.map { [("language", $0)] } ?? [])
        case .chatGPTWeb:
            guard let token = apiKey.flatMap(ChatGPTAccessToken.init) else {
                throw DictationFailure(message: "Paste a ChatGPT access token.", recovery: ChatGPTAccessToken.recovery)
            }
            request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
            if let accountID = token.accountID { request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id") }
            // The same form the ChatGPT web composer sends; it has no
            // language field, ChatGPT always detects the language itself.
            let durationMs = Double(audio.samples.count) / audio.sampleRate * 1_000
            fields = [
                ("dictation_session_id", UUID().uuidString.lowercased()),
                ("attempt_id", UUID().uuidString.lowercased()),
                ("duration_ms", String(durationMs))
            ]
        }
        request.httpBody = MultipartAudioBody.make(audio: audio, fields: fields, boundary: boundary)
        return request
    }

    private static func validatedModel(
        for configuration: RemoteProviderConfiguration
    ) throws -> String {
        guard !containsLineBreak(configuration.model) else {
            throw DictationFailure(message: "Remote model contains an invalid line break.", recovery: "Remove line breaks and try again.")
        }
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw DictationFailure(message: "Enter a remote model name.", recovery: "Use the model identifier expected by your endpoint.")
        }
        return model
    }

    private static func containsLineBreak(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value == 0x0D || $0.value == 0x0A }
    }

    static func decode(data: Data, response: URLResponse, kind: RemoteProviderKind = .openAICompatible) throws -> String {
        let http = try validatedHTTPResponse(response)
        try validateStatus(http, kind: kind)
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data), !decoded.text.isEmpty else {
            throw DictationFailure(message: "The remote provider returned an invalid response.", recovery: "Expected an OpenAI-compatible JSON response containing text.")
        }
        return decoded.text
    }

    static func validateConnectionTestResponse(
        data: Data,
        response: URLResponse,
        kind: RemoteProviderKind = .openAICompatible
    ) throws {
        let http = try validatedHTTPResponse(response)
        try validateStatus(http, kind: kind)
        // Silence legitimately transcribes to empty text; the probe validates
        // reachability, auth, and response shape — not recognition output.
        guard (try? JSONDecoder().decode(Response.self, from: data)) != nil else {
            throw DictationFailure(message: "The remote provider returned an invalid response.", recovery: "Expected an OpenAI-compatible JSON response containing text.")
        }
    }

    private static func validatedHTTPResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw DictationFailure(message: "The remote provider returned an invalid response.", recovery: "Check provider compatibility.")
        }
        return http
    }

    private static func validateStatus(_ http: HTTPURLResponse, kind: RemoteProviderKind) throws {
        switch (http.statusCode, kind) {
        case (200..<300, _): break
        case (403, .chatGPTWeb) where http.value(forHTTPHeaderField: "cf-mitigated") != nil:
            throw DictationFailure(message: "ChatGPT blocked the request with a Cloudflare challenge.", recovery: "Try again later; the web endpoint does not accept this client right now.")
        case (401, .chatGPTWeb), (403, .chatGPTWeb):
            throw DictationFailure(message: "ChatGPT rejected the access token.", recovery: ChatGPTAccessToken.recovery)
        case (401, _), (403, _):
            throw DictationFailure(message: "Remote authentication failed.", recovery: "Check the saved API key in Transcription settings.")
        case (404, _):
            throw DictationFailure(message: "Remote transcription endpoint was not found.", recovery: "Check the base URL.")
        default:
            throw DictationFailure(message: "Remote transcription failed (HTTP \(http.statusCode)).", recovery: "Check the provider configuration and try again.")
        }
    }

    static func isLocalOrLAN(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        // The host must BE an IP literal, not merely contain numeric labels:
        // "10.1.2.3.attacker.com" is a public DNS name and must not pass.
        let bracketless = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v6 = in6_addr()
        if inet_pton(AF_INET6, bracketless, &v6) == 1 {
            return bracketless == "::1"
        }
        var v4 = in_addr()
        guard inet_pton(AF_INET, host, &v4) == 1 else { return false }
        let address = UInt32(bigEndian: v4.s_addr)
        let octet1 = (address >> 24) & 0xFF
        let octet2 = (address >> 16) & 0xFF
        return octet1 == 10
            || octet1 == 127
            || (octet1 == 192 && octet2 == 168)
            || (octet1 == 172 && (16...31).contains(octet2))
    }
}

/// The ChatGPT web session's access token: a JWT whose payload carries the
/// account id ChatGPT expects as a header and the expiry shown in settings.
/// The signature is not checked here; only ChatGPT can verify it.
struct ChatGPTAccessToken: Equatable, Sendable {
    static let recovery = "Open chatgpt.com/api/auth/session while signed in, copy the accessToken value, and save it in Transcription settings."

    let value: String
    let accountID: String?
    let expiresAt: Date?

    /// Accepts the bare token or a pasted "Bearer …" header value.
    init?(_ raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("bearer ") {
            value = value.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }),
              let payload = Self.base64URLDecoded(parts[1]),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        self.value = value
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        // Only a plain UUID-like id may become a header value.
        accountID = (auth?["chatgpt_account_id"] as? String).flatMap { id in
            !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == "-") } ? id : nil
        }
        expiresAt = (claims["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    func isExpired(at now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }

    private static func base64URLDecoded(_ segment: Substring) -> Data? {
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

private enum MultipartAudioBody {
    static func make(audio: RecordedAudio, fields: [(String, String)], boundary: String) -> Data {
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        for (name, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wavData(audio))
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func wavData(_ audio: RecordedAudio) -> Data {
        let sampleData = audio.samples.withUnsafeBytes { Data($0) }
        var data = Data()
        func ascii(_ value: String) { data.append(Data(value.utf8)) }
        func le<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; data.append(Data(bytes: &value, count: MemoryLayout<T>.size)) }
        ascii("RIFF"); le(UInt32(36 + sampleData.count)); ascii("WAVEfmt "); le(UInt32(16)); le(UInt16(3)); le(UInt16(1))
        le(UInt32(audio.sampleRate)); le(UInt32(audio.sampleRate * 4)); le(UInt16(4)); le(UInt16(32)); ascii("data"); le(UInt32(sampleData.count)); data.append(sampleData)
        return data
    }
}
