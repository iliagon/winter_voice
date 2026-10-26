import Foundation

enum RemoteProviderKind: String, Codable, CaseIterable, Sendable {
    /// Any `/audio/transcriptions` endpoint speaking the OpenAI API shape.
    case openAICompatible
    /// ChatGPT's own dictation endpoint, authenticated with the web session's
    /// access token pasted by the user (it expires after about ten days).
    case chatGPTWeb

    var title: String {
        switch self {
        case .openAICompatible: "OpenAI-compatible"
        case .chatGPTWeb: "ChatGPT (access token)"
        }
    }
}

struct RemoteProviderConfiguration: Equatable, Codable, Sendable {
    var kind: RemoteProviderKind = .openAICompatible
    var baseURL = ""
    var model = ""
}

extension RemoteProviderConfiguration {
    private enum CodingKeys: String, CodingKey { case kind, baseURL, model }

    /// Configurations saved before `kind` existed decode as OpenAI-compatible.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(RemoteProviderKind.self, forKey: .kind) ?? .openAICompatible
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
    }
}

enum ProviderReadiness: Equatable, Sendable {
    case ready(String)
    case unavailable(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var detail: String {
        switch self {
        case .ready(let detail), .unavailable(let detail): detail
        }
    }
}

struct ProviderStatus: Equatable, Sendable {
    let readiness: ProviderReadiness

    var title: String { "Remote API" }
    var isReady: Bool { readiness.isReady }
    var stateLabel: String { isReady ? "Ready" : "Not ready" }

    var overviewSummary: String {
        if isReady {
            return "Transcription is ready. Hold the configured push-to-talk key, then release to transcribe and insert text."
        }
        return readiness.detail
    }

    var privacySummary: String {
        isReady
            ? "Audio is sent only to your configured remote endpoint when you dictate. Optional API keys are stored locally on this Mac, unauthenticated endpoints receive no Authorization header, and audio or transcripts are not logged."
            : "Transcription is not configured, so dictation attempts do not record or send audio."
    }
}
