import Foundation

enum AppPermission: CaseIterable, Identifiable, Sendable {
    case microphone
    case inputMonitoring
    case accessibility

    var id: Self { self }
    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .inputMonitoring: "Input Monitoring"
        case .accessibility: "Accessibility"
        }
    }
    var explanation: String {
        switch self {
        case .microphone: "Captures audio while you dictate."
        case .inputMonitoring: "Observes the configured push-to-talk key, such as Fn, without changing keyboard input."
        case .accessibility: "Finds the text caret to show the indicator next to it and types the transcript into the focused field."
        }
    }
    /// Only the microphone is essential. The other two grants need an
    /// administrator password; without them the toggle shortcut and
    /// clipboard delivery keep dictation working.
    var isRequired: Bool { self == .microphone }
    /// What still works when an optional permission is missing.
    var limitationWithout: String? {
        switch self {
        case .microphone: nil
        case .inputMonitoring: "Optional. Without it, start and stop dictation with the toggle shortcut (⌃⌥Space by default) instead of Fn."
        case .accessibility: "Optional. Without it, transcripts are copied to the clipboard for you to paste with ⌘V, and the indicator appears at the mouse pointer."
        }
    }
}

enum PermissionStatus: String, Sendable {
    case notDetermined = "Not requested"
    case authorized = "Allowed"
    case denied = "Denied"
    case restricted = "Restricted"
}

enum PermissionRequestState: Equatable, Sendable {
    case idle
    case requesting(AppPermission)
    case completed(AppPermission, PermissionStatus)
}

struct PermissionSnapshot: Equatable, Sendable {
    var microphone: PermissionStatus
    var inputMonitoring: PermissionStatus
    var accessibility: PermissionStatus

    subscript(_ permission: AppPermission) -> PermissionStatus {
        switch permission {
        case .microphone: microphone
        case .inputMonitoring: inputMonitoring
        case .accessibility: accessibility
        }
    }

    var isFullyAuthorized: Bool {
        AppPermission.allCases.allSatisfy { self[$0] == .authorized }
    }
}
