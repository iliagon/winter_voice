import AppKit
import Carbon.HIToolbox
import Combine

/// Whether the permission-free toggle shortcut is live.
enum ToggleShortcutStatus: Equatable, Sendable {
    case off
    case active
    /// The Push-to-Talk shortcut uses the same keys and already handles them.
    case sharedWithPrimary
    case unavailable(String)
}

@MainActor
protocol GlobalHotkeyRegistering: AnyObject {
    var onPress: (() -> Void)? { get set }
    /// Returns `noErr` when the shortcut was registered.
    func register(keyCode: UInt32, carbonModifiers: UInt32) -> OSStatus
    func unregister()
}

/// Listens for the toggle shortcut through Carbon's `RegisterEventHotKey`.
/// Unlike the Quartz event tap behind Push-to-Talk, this needs no Input
/// Monitoring permission: macOS delivers only the registered chord, never the
/// rest of the keyboard. It cannot observe a bare modifier such as Fn, so the
/// shortcut is always a key plus modifiers.
@MainActor
final class CarbonToggleShortcut: ObservableObject, HotkeyCaptureSuspending {
    @Published private(set) var status: ToggleShortcutStatus = .off

    private weak var interactor: DictationInteracting?
    private let store: ToggleShortcutStore
    private let primary: HotkeyBindingStore
    private let backend: GlobalHotkeyRegistering
    private let systemShortcuts: () -> [String: Any]
    private var isSuspended = false
    private var cancellables = Set<AnyCancellable>()

    init(
        interactor: DictationInteracting,
        store: ToggleShortcutStore,
        primary: HotkeyBindingStore,
        backend: GlobalHotkeyRegistering = CarbonHotkeyBackend(),
        systemShortcuts: @escaping () -> [String: Any] = CarbonToggleShortcut.readSystemShortcuts
    ) {
        self.interactor = interactor
        self.store = store
        self.primary = primary
        self.backend = backend
        self.systemShortcuts = systemShortcuts
        backend.onPress = { [weak self] in
            guard let self, !self.isSuspended else { return }
            self.interactor?.togglePushToTalk()
        }
        // Published values arrive from willSet; read them from the next turn.
        store.$binding
            .combineLatest(primary.$selection)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.reconcile() }
            .store(in: &cancellables)
        reconcile()
    }

    func reconcile() {
        backend.unregister()
        guard let binding = store.binding else {
            status = .off
            return
        }
        if primary.selection == binding {
            status = .sharedWithPrimary
            return
        }
        if let problem = Self.rejection(for: binding) {
            status = .unavailable(problem)
            return
        }
        if Self.conflictsWithSystemShortcut(binding, symbolicHotKeys: systemShortcuts()) {
            status = .unavailable("macOS uses \(binding.title) for another action. Pick other keys, or turn that shortcut off in System Settings → Keyboard → Keyboard Shortcuts.")
            return
        }
        guard !isSuspended else { return }
        let result = backend.register(
            keyCode: UInt32(binding.keyCode),
            carbonModifiers: Self.carbonModifiers(for: binding.modifiers)
        )
        status = result == noErr
            ? .active
            : .unavailable("Another app already uses \(binding.title). Pick other keys.")
    }

    // MARK: HotkeyCaptureSuspending

    /// While a new shortcut is being recorded the current one is released, so
    /// pressing it lands in the recorder instead of starting a dictation.
    func suspendMatching() {
        isSuspended = true
        backend.unregister()
    }

    func resumeMatching() {
        isSuspended = false
        reconcile()
    }

    // MARK: Rules

    /// Why macOS would refuse or misbehave with this shortcut, or `nil`.
    nonisolated static func rejection(for binding: HotkeyBinding) -> String? {
        if binding.isModifierOnly {
            return "Use a key together with modifiers, for example ⌃⌥Space. Modifier-only shortcuts need Input Monitoring."
        }
        let modifiers = binding.modifiers
        if modifiers.contains(.maskSecondaryFn) {
            return "Fn cannot be part of this shortcut. Use ⌃, ⌥, ⇧ or ⌘."
        }
        // macOS 15 refuses global shortcuts whose only modifiers are ⌥ and ⇧.
        if !modifiers.isEmpty, modifiers.isSubset(of: [.maskAlternate, .maskShift]) {
            return "macOS does not allow shortcuts that use only ⌥ or ⇧. Add ⌃ or ⌘."
        }
        if modifiers.isEmpty, !functionKeyCodes.contains(Int(binding.keyCode)) {
            return "Add a modifier such as ⌃ or ⌘, otherwise the key could no longer be typed."
        }
        return nil
    }

    nonisolated static func carbonModifiers(for flags: CGEventFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.maskCommand) { result |= UInt32(cmdKey) }
        if flags.contains(.maskShift) { result |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { result |= UInt32(optionKey) }
        if flags.contains(.maskControl) { result |= UInt32(controlKey) }
        return result
    }

    /// System shortcuts (input source switching, Spotlight, Mission Control…)
    /// win over registered hotkeys without any error, so they are checked
    /// against the user's `com.apple.symbolichotkeys` preferences. Each entry
    /// stores `parameters = (character, keyCode, NSEvent modifier mask)`.
    nonisolated static func conflictsWithSystemShortcut(
        _ binding: HotkeyBinding,
        symbolicHotKeys: [String: Any]
    ) -> Bool {
        let wanted = cocoaModifierMask(for: binding.modifiers)
        return symbolicHotKeys.values.contains { entry in
            guard let entry = entry as? [String: Any],
                  (entry["enabled"] as? Bool) == true || (entry["enabled"] as? Int) == 1,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Int],
                  parameters.count >= 3 else { return false }
            let modifiers = UInt(parameters[2]) & cocoaModifierBits
            return Int64(parameters[1]) == binding.keyCode && modifiers == wanted
        }
    }

    nonisolated static func readSystemShortcuts() -> [String: Any] {
        CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        ) as? [String: Any] ?? [:]
    }

    private nonisolated static let cocoaModifierBits: UInt =
        NSEvent.ModifierFlags([.shift, .control, .option, .command]).rawValue

    private nonisolated static func cocoaModifierMask(for flags: CGEventFlags) -> UInt {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result.rawValue
    }

    private nonisolated static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
}

/// The real Carbon registration. One application-level handler receives
/// every hot-key event; this app registers at most one hot key at a time.
@MainActor
final class CarbonHotkeyBackend: GlobalHotkeyRegistering {
    var onPress: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// 'MVDT' — identifies this app's hot key in the event.
    nonisolated static let signature: OSType = 0x4D56_4454

    func register(keyCode: UInt32, carbonModifiers: UInt32) -> OSStatus {
        unregister()
        let installStatus = installHandlerIfNeeded()
        guard installStatus == noErr else { return installStatus }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        return RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard handlerRef == nil else { return noErr }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // The backend lives for the whole app session (owned by the
        // composition root), so an unretained pointer stays valid.
        return InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == CarbonHotkeyBackend.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let backend = Unmanaged<CarbonHotkeyBackend>.fromOpaque(userData).takeUnretainedValue()
                // Carbon dispatches application events on the main thread.
                MainActor.assumeIsolated { backend.onPress?() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }
}

/// Fans one recorder's suspend/resume out to every global shortcut listener.
@MainActor
final class HotkeyCaptureSuspenders: HotkeyCaptureSuspending {
    private let members: [HotkeyCaptureSuspending]

    init(_ members: [HotkeyCaptureSuspending]) {
        self.members = members
    }

    func suspendMatching() { members.forEach { $0.suspendMatching() } }
    func resumeMatching() { members.forEach { $0.resumeMatching() } }
}
