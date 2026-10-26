import SwiftUI

struct MenuBarView: View {
    @ObservedObject var presenter: DictationPresenter
    @ObservedObject var shellPresenter: AppShellPresenter
    @ObservedObject var onboardingPresenter: OnboardingPresenter
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label(
            presenter.statusTitle,
            systemImage: presenter.state == .recording ? "waveform" : "mic"
        )
        .disabled(true)

        Label(
            presenter.hotkeyHealthTitle,
            systemImage: presenter.hotkeyHealth == .listening
                ? "keyboard" : "exclamationmark.triangle"
        )
        .disabled(true)

        Text(shellPresenter.providerStatus.isReady
            ? presenter.hotkeyInstruction
            : "Transcription provider not ready")
            .disabled(true)

        Divider()

        Button(dictationMenuTitle) { presenter.toggleDictation() }

        Divider()

        Button("Open MacVoice") {
            openMainWindow()
        }
        .keyboardShortcut("0", modifiers: .command)

        Button("Open Permission Guide…") {
            onboardingPresenter.restart()
            openMainWindow()
        }

        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")

        Divider()

        Button("Quit MacVoice") { presenter.quit() }
            .keyboardShortcut("q")
    }

    /// A menu click starts or stops a session the same way the toggle
    /// shortcut does, so dictation is reachable even with no hot key at all.
    private var dictationMenuTitle: String {
        let shortcut = shellPresenter.toggleShortcutStore.binding.map { " (\($0.title))" } ?? ""
        switch presenter.state {
        case .preparing, .recording: return "Stop Dictation" + shortcut
        default: return "Start Dictation" + shortcut
        }
    }

    private func openMainWindow() {
        shellPresenter.activateApplication()
        openWindow(id: "main")
    }
}
