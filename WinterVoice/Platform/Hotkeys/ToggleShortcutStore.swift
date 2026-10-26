import Carbon.HIToolbox
import Combine
import Foundation

/// The second, permission-free dictation shortcut: one press starts a
/// recording, the next press stops it and delivers the text. `nil` means the
/// user turned it off.
@MainActor
final class ToggleShortcutStore: ObservableObject {
    static let defaultBinding = HotkeyBinding(
        keyCode: Int64(kVK_Space),
        modifiers: [.maskControl, .maskAlternate],
        isModifierOnly: false
    )

    @Published var binding: HotkeyBinding? {
        didSet {
            if let binding {
                defaults.set(try? JSONEncoder().encode(binding), forKey: Self.key)
            } else {
                defaults.set(Self.offValue, forKey: Self.key)
            }
        }
    }

    private static let key = "hotkey.toggleShortcut"
    private static let offValue = "off"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.string(forKey: Self.key) == Self.offValue {
            binding = nil
        } else {
            binding = defaults.data(forKey: Self.key)
                .flatMap { try? JSONDecoder().decode(HotkeyBinding.self, from: $0) }
                ?? Self.defaultBinding
        }
    }
}
