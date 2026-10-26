import Combine
import Foundation

protocol CredentialStoring: AnyObject {
    func read() throws -> String?
    func write(_ value: String) throws
    func delete() throws
}

/// Stores the remote API key in an owner-only file under Application Support.
/// Deliberately not the Keychain: Keychain access is bound to the code
/// signature, so every ad-hoc or development rebuild is a different Keychain
/// client and each launch interrupts with a login-password prompt.
final class FileCredentialStore: CredentialStoring {
    private let url: URL
    private let fileManager = FileManager.default

    init(root: URL? = nil) {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let directory = root
            ?? applicationSupport.appendingPathComponent("WinterVoice", isDirectory: true)
        url = directory.appendingPathComponent("remote-api-key")
    }

    func read() throws -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8) else {
            throw DictationFailure(
                message: "Could not read the API key.",
                recovery: "Re-enter the API key in Transcription settings."
            )
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func write(_ value: String) throws {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(value.utf8).write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            throw DictationFailure(
                message: "Could not save the API key.",
                recovery: "Check disk access and try again."
            )
        }
    }

    func delete() throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw DictationFailure(
                message: "Could not remove the API key.",
                recovery: "Remove the remote-api-key file in Application Support/WinterVoice."
            )
        }
    }
}

@MainActor
final class ProviderConfigurationStore: ObservableObject {
    @Published var remote: RemoteProviderConfiguration
    @Published private(set) var hasAPIKey: Bool

    /// The ISO 639-1 code sent as the transcription `language`; `nil` means
    /// auto-detect.
    @Published var languageCode: String? {
        didSet { defaults.set(languageCode ?? Self.autoLanguage, forKey: Keys.language) }
    }

    private static let autoLanguage = "auto"

    private enum Keys {
        static let remote = "transcription.remote.configuration"
        static let language = "transcription.language"
    }
    private let defaults: UserDefaults
    private let credentials: CredentialStoring

    init(defaults: UserDefaults = .standard, credentials: CredentialStoring = FileCredentialStore()) {
        self.defaults = defaults
        self.credentials = credentials
        let remoteData = defaults.data(forKey: Keys.remote)
        remote = remoteData.flatMap { try? JSONDecoder().decode(RemoteProviderConfiguration.self, from: $0) } ?? .init()
        hasAPIKey = ((try? credentials.read()) ?? nil)?.isEmpty == false
        if let stored = defaults.string(forKey: Keys.language) {
            languageCode = stored == Self.autoLanguage ? nil : stored
        } else {
            // One-time adoption of the retired free-text remote "language"
            // field, kept only when it was already a known ISO code.
            let legacy = remoteData
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["language"] as? String }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            languageCode = legacy.flatMap { TranscriptionLanguage.isKnown($0) ? $0 : nil }
        }
    }

    func saveRemote(_ configuration: RemoteProviderConfiguration, apiKey: String?) throws {
        remote = configuration
        defaults.set(try JSONEncoder().encode(configuration), forKey: Keys.remote)
        if let apiKey, !apiKey.isEmpty { try credentials.write(apiKey) }
        hasAPIKey = (try credentials.read())?.isEmpty == false
    }

    func apiKey() throws -> String? { try credentials.read() }

    func removeAPIKey() throws {
        try credentials.delete()
        hasAPIKey = false
    }

    func readiness() -> ProviderReadiness {
        do {
            _ = try RemoteTranscriptionProvider.endpoint(for: remote)
            return .ready(hasAPIKey
                ? "Generic OpenAI-compatible remote provider is configured with a saved API key."
                : "Generic OpenAI-compatible remote provider is configured without authentication.")
        } catch let error as DictationFailure {
            return .unavailable(error.message)
        } catch {
            return .unavailable("Remote configuration is invalid.")
        }
    }

    func status() -> ProviderStatus {
        ProviderStatus(readiness: readiness())
    }
}
