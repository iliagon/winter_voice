import AppKit

/// Resolves where the text caret of a focused Accessibility element is on
/// screen. Sources are tried from most to least precise: the caret's own
/// bounds, then the field's frame, then the mouse pointer. Every AX answer is
/// sanity-checked because Chromium and Electron routinely report empty or
/// off-screen rectangles.
@MainActor
enum CaretLocator {
    /// Fields taller than this are editors, not single lines; anchoring below
    /// their frame would put the panel far from where the user is typing.
    nonisolated static let maximumFieldAnchorHeight: CGFloat = 80

    static func anchor(for element: AXUIElement?) -> CaretAnchor {
        let screens = NSScreen.screens.map(\.frame)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if let element {
            if let caret = caretBounds(of: element),
               let rect = plausibleCocoaRect(fromAX: caret, primaryScreenHeight: primaryHeight, screens: screens) {
                return CaretAnchor(rect: rect, source: .caret)
            }
            if let frame = frame(of: element),
               let rect = plausibleCocoaRect(fromAX: frame, primaryScreenHeight: primaryHeight, screens: screens),
               let anchor = fieldAnchor(for: rect, pointer: NSEvent.mouseLocation) {
                return anchor
            }
        }
        return pointerAnchor(at: NSEvent.mouseLocation)
    }

    // MARK: Pure geometry

    /// Accessibility reports rectangles with the origin at the top-left of
    /// the primary screen and y growing downward; AppKit windows use the
    /// bottom-left with y growing upward.
    nonisolated static func cocoaRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryScreenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts and validates an AX rectangle. Rejects non-finite values, the
    /// all-zero rectangle apps return when they have no real answer, absurd
    /// heights, and anything that is not on a connected screen.
    nonisolated static func plausibleCocoaRect(
        fromAX rect: CGRect,
        primaryScreenHeight: CGFloat,
        screens: [CGRect]
    ) -> CGRect? {
        let values = [rect.origin.x, rect.origin.y, rect.width, rect.height]
        guard values.allSatisfy(\.isFinite),
              rect.origin != .zero || rect.size != .zero,
              rect.height > 0,
              rect.width >= 0,
              primaryScreenHeight > 0 else { return nil }
        let converted = cocoaRect(fromAX: rect, primaryScreenHeight: primaryScreenHeight)
        let probe = CGPoint(x: converted.minX, y: converted.midY)
        guard screens.contains(where: { $0.contains(probe) }) else { return nil }
        return converted
    }

    /// A single-line field anchors at its own frame. A tall editor only
    /// anchors at the pointer when the pointer is inside it, otherwise at its
    /// first line.
    nonisolated static func fieldAnchor(for field: CGRect, pointer: CGPoint) -> CaretAnchor? {
        if field.height <= maximumFieldAnchorHeight {
            return CaretAnchor(rect: field, source: .field)
        }
        if field.contains(pointer) {
            return pointerAnchor(at: pointer)
        }
        let firstLine = CGRect(x: field.minX + 8, y: field.maxY - 24, width: 0, height: 20)
        return CaretAnchor(rect: firstLine, source: .field)
    }

    /// The pointer's hot spot is its tip; the arrow glyph hangs ~20 pt below
    /// it, so the anchor covers that height to keep the panel clear of it.
    nonisolated static func pointerAnchor(at point: CGPoint) -> CaretAnchor {
        CaretAnchor(rect: CGRect(x: point.x, y: point.y - 20, width: 0, height: 20), source: .pointer)
    }

    // MARK: Accessibility queries

    /// Bounds of the insertion point. An empty range has no glyph, so many
    /// apps answer with an empty rectangle; the character just before the
    /// caret (or, at the very start, just after it) stands in for it.
    private static func caretBounds(of element: AXUIElement) -> CGRect? {
        guard let range = selectedRange(of: element) else { return nil }
        if let rect = bounds(of: element, range: CFRange(location: range.location, length: range.length)),
           rect.height > 0 {
            return range.length > 0 ? CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height) : rect
        }
        if range.location > 0,
           let rect = bounds(of: element, range: CFRange(location: range.location - 1, length: 1)),
           rect.height > 0 {
            return CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
        }
        if let rect = bounds(of: element, range: CFRange(location: range.location, length: 1)),
           rect.height > 0 {
            return CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
        }
        return nil
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return range
    }

    private static func bounds(of element: AXUIElement, range: CFRange) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        ) == .success else { return nil }
        return rect(from: value)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func rect(from value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgRect, &rect) else { return nil }
        return rect
    }
}
