import CoreGraphics

/// Where the recording panel should attach on screen, in Cocoa global
/// coordinates (origin at the bottom-left of the primary screen, y up).
struct CaretAnchor: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// The text caret reported by the focused element.
        case caret
        /// The focused field's frame; its caret was not exposed.
        case field
        /// The mouse pointer; nothing usable was exposed.
        case pointer
    }

    let rect: CGRect
    let source: Source
}
