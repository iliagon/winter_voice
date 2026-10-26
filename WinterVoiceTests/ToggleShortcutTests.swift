import Carbon.HIToolbox
import XCTest
@testable import WinterVoice

@MainActor
final class CarbonToggleShortcutTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "ToggleShortcutTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private func makeSubject(
        backend: HotkeyBackendFake = HotkeyBackendFake(),
        interactor: ToggleInteractorSpy = ToggleInteractorSpy(),
        systemShortcuts: [String: Any] = [:]
    ) -> (CarbonToggleShortcut, ToggleShortcutStore, HotkeyBindingStore) {
        let store = ToggleShortcutStore(defaults: defaults)
        let primary = HotkeyBindingStore(defaults: defaults)
        let subject = CarbonToggleShortcut(
            interactor: interactor,
            store: store,
            primary: primary,
            backend: backend,
            systemShortcuts: { systemShortcuts }
        )
        return (subject, store, primary)
    }

    func testDefaultRegistersControlOptionSpaceAndPressTogglesDictation() {
        let backend = HotkeyBackendFake()
        let interactor = ToggleInteractorSpy()
        let (subject, _, _) = makeSubject(backend: backend, interactor: interactor)

        XCTAssertEqual(subject.status, .active)
        XCTAssertEqual(backend.registered?.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(backend.registered?.modifiers, UInt32(controlKey | optionKey))

        backend.onPress?()
        backend.onPress?()
        XCTAssertEqual(interactor.toggleCount, 2)
    }

    func testChangingAndTurningOffTheShortcutReregisters() {
        let backend = HotkeyBackendFake()
        let (subject, store, _) = makeSubject(backend: backend)

        store.binding = HotkeyBinding(keyCode: Int64(kVK_ANSI_D), modifiers: [.maskCommand, .maskShift], isModifierOnly: false)
        settle()
        XCTAssertEqual(backend.registered?.keyCode, UInt32(kVK_ANSI_D))
        XCTAssertEqual(backend.registered?.modifiers, UInt32(cmdKey | shiftKey))

        store.binding = nil
        settle()
        XCTAssertNil(backend.registered)
        XCTAssertEqual(subject.status, .off)
        XCTAssertNil(ToggleShortcutStore(defaults: defaults).binding, "Off must persist")
    }

    func testSameKeysAsPushToTalkAreLeftToTheEventTap() {
        let backend = HotkeyBackendFake()
        let (subject, _, primary) = makeSubject(backend: backend)

        primary.selection = ToggleShortcutStore.defaultBinding
        settle()

        XCTAssertNil(backend.registered)
        XCTAssertEqual(subject.status, .sharedWithPrimary)
    }

    func testRegistrationFailureIsReported() {
        let backend = HotkeyBackendFake()
        backend.result = OSStatus(eventHotKeyExistsErr)
        let (subject, _, _) = makeSubject(backend: backend)

        guard case .unavailable = subject.status else {
            return XCTFail("Expected unavailable, got \(subject.status)")
        }
    }

    func testEnabledSystemShortcutOnTheSameKeysBlocksRegistration() {
        let controlOption = NSEvent.ModifierFlags([.control, .option]).rawValue
        let enabled: [String: Any] = ["61": [
            "enabled": true,
            "value": ["parameters": [32, kVK_Space, Int(controlOption)], "type": "standard"],
        ]]
        let backend = HotkeyBackendFake()
        let (subject, _, _) = makeSubject(backend: backend, systemShortcuts: enabled)

        XCTAssertNil(backend.registered)
        guard case .unavailable = subject.status else {
            return XCTFail("Expected unavailable, got \(subject.status)")
        }

        var disabled = enabled
        disabled["61"] = ["enabled": false, "value": ["parameters": [32, kVK_Space, Int(controlOption)]]]
        XCTAssertFalse(CarbonToggleShortcut.conflictsWithSystemShortcut(
            ToggleShortcutStore.defaultBinding,
            symbolicHotKeys: disabled
        ))
    }

    func testRecordingSuspendsTheShortcut() {
        let backend = HotkeyBackendFake()
        let interactor = ToggleInteractorSpy()
        let (subject, _, _) = makeSubject(backend: backend, interactor: interactor)

        subject.suspendMatching()
        XCTAssertNil(backend.registered)
        backend.onPress?()
        XCTAssertEqual(interactor.toggleCount, 0)

        subject.resumeMatching()
        XCTAssertNotNil(backend.registered)
    }

    func testRejectionRules() {
        func binding(_ key: Int, _ modifiers: CGEventFlags, modifierOnly: Bool = false) -> HotkeyBinding {
            HotkeyBinding(keyCode: Int64(key), modifiers: modifiers, isModifierOnly: modifierOnly)
        }
        XCTAssertNil(CarbonToggleShortcut.rejection(for: ToggleShortcutStore.defaultBinding))
        XCTAssertNil(CarbonToggleShortcut.rejection(for: binding(kVK_F13, [])))
        XCTAssertNil(CarbonToggleShortcut.rejection(for: binding(kVK_ANSI_D, [.maskCommand])))
        XCTAssertNotNil(CarbonToggleShortcut.rejection(for: .function), "Modifier-only needs the event tap")
        XCTAssertNotNil(CarbonToggleShortcut.rejection(for: binding(kVK_Space, [.maskAlternate])))
        XCTAssertNotNil(CarbonToggleShortcut.rejection(for: binding(kVK_Space, [.maskAlternate, .maskShift])))
        XCTAssertNotNil(CarbonToggleShortcut.rejection(for: binding(kVK_ANSI_D, [])))
        XCTAssertNotNil(CarbonToggleShortcut.rejection(for: binding(kVK_Space, [.maskSecondaryFn, .maskControl])))
    }
}

@MainActor
private final class HotkeyBackendFake: GlobalHotkeyRegistering {
    var onPress: (() -> Void)?
    var result: OSStatus = noErr
    private(set) var registered: (keyCode: UInt32, modifiers: UInt32)?

    func register(keyCode: UInt32, carbonModifiers: UInt32) -> OSStatus {
        if result == noErr { registered = (keyCode, carbonModifiers) }
        return result
    }

    func unregister() { registered = nil }
}

@MainActor
private final class ToggleInteractorSpy: DictationInteracting {
    private(set) var toggleCount = 0
    func beginPushToTalk() {}
    func endPushToTalk() {}
    func togglePushToTalk() { toggleCount += 1 }
}
