import AppKit
import Combine
import SwiftUI

/// What the panel is showing. Several dictation states share one look:
/// preparing joins listening so holding the key gives instant feedback, and
/// inserting joins done so the checkmark is drawn as soon as the transcript
/// arrives.
@MainActor
final class RecordingPanelModel: ObservableObject {
    enum Phase: Equatable {
        case listening
        case transcribing
        case done
        case failed(DictationFailure)
    }

    /// Which side of the caret the panel sits on; the content hugs that side.
    enum Edge {
        case below
        case above
    }

    @Published var phase: Phase = .listening
    @Published var edge: Edge = .below
    /// Drives the pop-in and fade-out; the window itself stays opaque.
    @Published var isPresented = false

    static func phase(for state: DictationState) -> Phase? {
        switch state {
        case .idle: nil
        case .preparing, .recording: .listening
        case .processing: .transcribing
        case .inserting, .done: .done
        case .failed(let failure): .failed(failure)
        }
    }
}

/// Shows the dictation panel next to the text caret for the length of one
/// session. The panel is a fixed-size, click-through, non-activating window:
/// it never takes focus from the field being dictated into, and the pill
/// inside it resizes with a SwiftUI animation instead of window resizing.
@MainActor
final class RecordingPanelController {
    /// Large enough for the widest content, the failure card.
    static let panelSize = CGSize(width: 264, height: 120)
    /// How long a session waits for the caret before using the pointer.
    static let anchorWaitLimit: Duration = .milliseconds(150)
    private static let fadeOutDuration: TimeInterval = 0.18

    let model = RecordingPanelModel()
    private let panel: NSPanel
    private let presenter: DictationPresenter
    /// A session is running: the dictation state is anything but idle.
    private var isSessionActive = false
    /// The panel has been positioned and shown for the current session.
    private var isShown = false
    private var anchorWaitTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(presenter: DictationPresenter, levelMeter: AudioLevelMeter) {
        self.presenter = presenter
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // An NSWindow shadow around a transparent canvas would draw a visible
        // rectangle, so the pill renders shadowless.
        panel.hasShadow = false
        panel.contentView = NSHostingView(
            rootView: RecordingPanelView(model: model, levelMeter: levelMeter)
        )
        // `@Published` emits from willSet; hopping to the next main-queue turn
        // makes the presenter's state and anchor agree when they are read.
        presenter.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.stateChanged(state) }
            .store(in: &cancellables)
        presenter.$anchor
            .receive(on: DispatchQueue.main)
            .sink { [weak self] anchor in self?.anchorChanged(anchor) }
            .store(in: &cancellables)
    }

    private func stateChanged(_ state: DictationState) {
        guard let phase = RecordingPanelModel.phase(for: state) else {
            endSession()
            return
        }
        model.phase = phase
        guard !isSessionActive else { return }
        isSessionActive = true
        if let anchor = presenter.anchor {
            present(at: anchor)
        } else {
            // The field is captured off the event-tap callback, a few
            // milliseconds after the press. Sessions that never capture one
            // (copy mode, early failures) fall back to the pointer.
            anchorWaitTask = Task { [weak self] in
                try? await Task.sleep(for: Self.anchorWaitLimit)
                guard !Task.isCancelled, let self, self.isSessionActive, !self.isShown else { return }
                self.present(at: CaretLocator.pointerAnchor(at: NSEvent.mouseLocation))
            }
        }
    }

    private func anchorChanged(_ anchor: CaretAnchor?) {
        guard isSessionActive, !isShown, let anchor else { return }
        present(at: anchor)
    }

    /// The panel stays where it first appeared for the whole session, even
    /// if the caret moves, so it never chases the text being inserted.
    private func present(at anchor: CaretAnchor) {
        anchorWaitTask?.cancel()
        anchorWaitTask = nil
        hideTask?.cancel()
        hideTask = nil
        isShown = true
        let origin = PanelPlacement.origin(
            for: Self.panelSize,
            anchor: anchor.rect,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
        panel.setFrameOrigin(origin)
        model.edge = origin.y >= anchor.rect.maxY ? .above : .below
        model.isPresented = false
        panel.orderFrontRegardless()
        // Present on the next turn so the pop-in animates from the hidden
        // state the window was just ordered in with.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShown else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                self.model.isPresented = true
            }
        }
    }

    private func endSession() {
        isSessionActive = false
        anchorWaitTask?.cancel()
        anchorWaitTask = nil
        guard isShown else { return }
        isShown = false
        withAnimation(.easeOut(duration: Self.fadeOutDuration)) {
            model.isPresented = false
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fadeOutDuration + 0.02))
            guard !Task.isCancelled, let self, !self.isShown else { return }
            self.panel.orderOut(nil)
        }
    }
}
