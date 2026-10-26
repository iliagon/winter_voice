import Foundation

enum FeatureAvailability: Equatable, Sendable {
    case available
    case planned
}

enum AppShellDestination: String, CaseIterable, Identifiable, Sendable {
    case overview
    case history
    case hotkey
    case settings

    var id: Self { self }

    var availability: FeatureAvailability {
        switch self {
        case .overview, .history, .hotkey, .settings:
            .available
        }
    }
}
