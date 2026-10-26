import Combine

@MainActor
final class DictationStateRelay: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    /// Where the current session's panel attaches; set once the focused
    /// field has been captured, and cleared between sessions so a session
    /// that never captures one cannot inherit the last caret position.
    @Published private(set) var anchor: CaretAnchor?
    /// How the current session's transcript was delivered; set just before
    /// `.done`.
    @Published private(set) var delivery: DictationDelivery = .inserted

    func publish(_ state: DictationState) {
        if state == .preparing || state == .idle { anchor = nil }
        self.state = state
    }

    func publish(anchor: CaretAnchor?) {
        self.anchor = anchor
    }

    func publish(delivery: DictationDelivery) {
        self.delivery = delivery
    }
}
