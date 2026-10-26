import Combine

@MainActor
final class AppShellPresenter: ObservableObject {
    @Published private(set) var selection: AppShellDestination
    let dictationPresenter: DictationPresenter
    let providerConfiguration: ProviderConfigurationStore
    let history: HistoryStore
    let hotkeyBinding: HotkeyBindingStore
    let microphonePreferences: MicrophonePreferences
    let behaviorPreferences: BehaviorPreferences
    let transcriptionSettings: TranscriptionSettingsController
    let toggleShortcutStore: ToggleShortcutStore
    let toggleShortcut: CarbonToggleShortcut?
    let hotkeyCaptureSuspender: HotkeyCaptureSuspending?
    private let router: AppRouter
    private var cancellables = Set<AnyCancellable>()

    init(
        dictationPresenter: DictationPresenter,
        router: AppRouter,
        providerConfiguration: ProviderConfigurationStore,
        history: HistoryStore,
        hotkeyBinding: HotkeyBindingStore,
        microphonePreferences: MicrophonePreferences = MicrophonePreferences(),
        behaviorPreferences: BehaviorPreferences = BehaviorPreferences(),
        toggleShortcutStore: ToggleShortcutStore = ToggleShortcutStore(),
        toggleShortcut: CarbonToggleShortcut? = nil,
        hotkeyCaptureSuspender: HotkeyCaptureSuspending? = nil
    ) {
        self.dictationPresenter = dictationPresenter
        self.router = router
        self.providerConfiguration = providerConfiguration
        self.history = history
        self.hotkeyBinding = hotkeyBinding
        self.microphonePreferences = microphonePreferences
        self.behaviorPreferences = behaviorPreferences
        self.toggleShortcutStore = toggleShortcutStore
        self.toggleShortcut = toggleShortcut
        self.hotkeyCaptureSuspender = hotkeyCaptureSuspender
        transcriptionSettings = TranscriptionSettingsController(configuration: providerConfiguration)
        selection = router.selection
        router.$selection.assign(to: &$selection)
        providerConfiguration.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        history.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func navigate(to destination: AppShellDestination) {
        router.navigate(to: destination)
    }

    func refresh() {
        dictationPresenter.refreshPermissions()
    }

    func activateApplication() {
        router.activateApplication()
    }

    var providerStatus: ProviderStatus {
        providerConfiguration.status()
    }
}
