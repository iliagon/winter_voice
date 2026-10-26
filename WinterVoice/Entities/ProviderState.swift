import Foundation

struct RemoteProviderConfiguration: Equatable, Codable, Sendable {
    var baseURL = ""
    var model = ""
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
