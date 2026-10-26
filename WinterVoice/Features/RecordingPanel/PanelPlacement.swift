import CoreGraphics

/// Positions the recording panel next to a caret anchor: just below it,
/// flipped above when the screen has no room below, and always kept inside
/// the visible frame of the screen the anchor is on. All values are Cocoa
/// global coordinates.
enum PanelPlacement {
    /// Space between the anchor and the panel's frame. The panel's content
    /// carries its own transparent padding on top of this.
    static let gap: CGFloat = 2
    /// Minimum distance kept from the edges of the visible frame.
    static let margin: CGFloat = 4
    /// Shifts the panel left so the pill's leading edge, not its transparent
    /// padding, lines up with the caret.
    static let leadingInset: CGFloat = 4

    static func origin(for size: CGSize, anchor: CGRect, visibleFrames: [CGRect]) -> CGPoint {
        let probe = CGPoint(x: anchor.minX, y: anchor.midY)
        let frame = visibleFrames.first { $0.contains(probe) }
            ?? visibleFrames.min { distance(from: probe, to: $0) < distance(from: probe, to: $1) }
            ?? CGRect(origin: .zero, size: size)

        var x = anchor.minX - leadingInset
        x = min(max(x, frame.minX + margin), frame.maxX - size.width - margin)

        let below = anchor.minY - gap - size.height
        let above = anchor.maxY + gap
        var y = below >= frame.minY + margin ? below : above
        y = min(max(y, frame.minY + margin), frame.maxY - size.height - margin)
        return CGPoint(x: x, y: y)
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
