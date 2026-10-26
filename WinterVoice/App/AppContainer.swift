import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class PermissionHotkeyReconciler {
    private let cancellable: AnyCancellable

    init(presenter: DictationPresenter, hotkey: HotkeyReconciling) {
        cancellable = presenter.$permissions
            .removeDuplicates()
            .sink { _ in hotkey.reconcile() }
    }
}

@MainActor
final class AppContainer {
    let presenter: DictationPresenter
    let shellPresenter: AppShellPresenter
    let onboardingPresenter: OnboardingPresenter
    let providerConfiguration: ProviderConfigurationStore
    let history: HistoryStore
    let hotkeyBinding: HotkeyBindingStore
    private let hotkey: RightOptionEventTap
    private let permissionHotkeyReconciler: PermissionHotkeyReconciler
    private let panelController: RecordingPanelController
    private let recordingFeedback: RecordingSessionFeedback

    init() {
        let relay = DictationStateRelay()
        let hotkeyRelay = HotkeyHealthRelay()
        let permissionManager = SystemPermissionManager()
        let providerConfiguration = ProviderConfigurationStore()
        let history = HistoryStore()
        let hotkeyBinding = HotkeyBindingStore()
        self.providerConfiguration = providerConfiguration
        self.history = history
        self.hotkeyBinding = hotkeyBinding
        let microphonePreferences = MicrophonePreferences()
        let behaviorPreferences = BehaviorPreferences()
        let audioRecorder = SystemAudioRecorder(preferences: microphonePreferences)
        let interactor = DictationInteractor(
            relay: relay,
            transcriber: ConfiguredTranscriber(
                recorder: audioRecorder,
                configuration: providerConfiguration
            ),
            injector: SystemTextInjector(),
            permissions: permissionManager,
            history: history,
            behavior: behaviorPreferences
        )
        recordingFeedback = RecordingSessionFeedback(
            relay: relay,
            preferences: behaviorPreferences
        )
        let router = AppRouter()
        // Dev affordance: `open MacVoice.app --args -WVOpenPage settings`
        // jumps straight to a shell page on launch.
        let arguments = ProcessInfo.processInfo.arguments
        if let flagIndex = arguments.firstIndex(of: "-WVOpenPage"),
           let destination = AppShellDestination(rawValue: arguments.dropFirst(flagIndex + 1).first ?? "") {
            router.navigate(to: destination)
        }
        // Dev affordance: `-WVThemeFlipAfter 3` toggles Black/Light once after
        // N seconds, so live theme switching is verifiable in screenshot runs.
        if let flagIndex = arguments.firstIndex(of: "-WVThemeFlipAfter"),
           let delay = TimeInterval(arguments.dropFirst(flagIndex + 1).first ?? "") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                let store = ThemeStore.shared
                store.mode = store.mode == .black ? .light : .black
            }
        }
        // Dev affordance: `-WVWidgetDemo` loops the widget through the
        // dictation states with synthetic voice levels, so the recording
        // waveform is filmable without microphone or hotkey permissions.
        if arguments.contains("-WVWidgetDemo") {
            let demoLevelMeter = audioRecorder.levelMeter
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                while !Task.isCancelled {
                    relay.publish(.preparing)
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    relay.publish(.recording)
                    let recordingStart = Date()
                    while Date().timeIntervalSince(recordingStart) < 4.2 {
                        let time = Date().timeIntervalSinceReferenceDate
                        // Bursts separated by pauses so the bars read as speech.
                        let speaking = sin(time * 1.9) > -0.35
                        let level = speaking
                            ? Float(0.2 + 0.65 * abs(sin(time * 9.3) * sin(time * 3.7)))
                            : Float(0.04)
                        demoLevelMeter.update(level)
                        try? await Task.sleep(nanoseconds: 40_000_000)
                    }
                    relay.publish(.processing)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    relay.publish(.inserting)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    relay.publish(.idle)
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                }
            }
        }
        let presenter = DictationPresenter(
            interactor: interactor,
            relay: relay,
            hotkeyRelay: hotkeyRelay,
            permissionManager: permissionManager,
            router: router,
            hotkeyBinding: hotkeyBinding
        )
        self.presenter = presenter
        let hotkey = RightOptionEventTap(
            interactor: interactor,
            relay: hotkeyRelay,
            binding: hotkeyBinding
        )
        self.hotkey = hotkey
        let widgetPreferences = WidgetPreferences()
        shellPresenter = AppShellPresenter(
            dictationPresenter: presenter,
            router: router,
            providerConfiguration: providerConfiguration,
            history: history,
            hotkeyBinding: hotkeyBinding,
            widgetPreferences: widgetPreferences,
            microphonePreferences: microphonePreferences,
            behaviorPreferences: behaviorPreferences,
            hotkeyCaptureSuspender: hotkey
        )
        onboardingPresenter = OnboardingPresenter(
            dictationPresenter: presenter,
            interactor: OnboardingInteractor(
                completionStore: UserDefaultsOnboardingCompletionStore()
            )
        )
        permissionHotkeyReconciler = PermissionHotkeyReconciler(
            presenter: presenter,
            hotkey: hotkey
        )
        let panel = RecordingPanelController(
            presenter: presenter,
            levelMeter: audioRecorder.levelMeter,
            preferences: widgetPreferences
        )
        panelController = panel
        hotkey.onShowWidget = { [weak panel] in panel?.showWidget() }
    }

    func start() {
        presenter.reconcilePermissionsAfterActivation()
    }
}
