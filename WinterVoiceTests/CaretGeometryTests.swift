import CoreGraphics
import XCTest
@testable import WinterVoice

final class CaretLocatorGeometryTests: XCTestCase {
    private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testAXRectIsFlippedIntoCocoaCoordinates() {
        let ax = CGRect(x: 100, y: 50, width: 2, height: 18)
        let cocoa = CaretLocator.cocoaRect(fromAX: ax, primaryScreenHeight: 900)
        XCTAssertEqual(cocoa, CGRect(x: 100, y: 832, width: 2, height: 18))
    }

    func testPlausibleRectAcceptsZeroWidthCaretOnScreen() {
        let rect = CaretLocator.plausibleCocoaRect(
            fromAX: CGRect(x: 300, y: 400, width: 0, height: 17),
            primaryScreenHeight: 900,
            screens: [primary]
        )
        XCTAssertEqual(rect, CGRect(x: 300, y: 483, width: 0, height: 17))
    }

    func testPlausibleRectRejectsJunkAnswers() {
        let junk: [CGRect] = [
            .zero,
            CGRect(x: 10, y: 10, width: 5, height: 0),
            CGRect(x: 5000, y: 100, width: 0, height: 18),
            CGRect(x: 100, y: -2000, width: 0, height: 18),
            CGRect(x: CGFloat.nan, y: 10, width: 0, height: 18),
            CGRect(x: 10, y: 10, width: 0, height: CGFloat.infinity),
        ]
        for rect in junk {
            XCTAssertNil(
                CaretLocator.plausibleCocoaRect(fromAX: rect, primaryScreenHeight: 900, screens: [primary]),
                "Expected rejection for \(rect)"
            )
        }
    }

    func testRectOnSecondaryScreenAboveThePrimaryIsAccepted() {
        // A display arranged above the primary has negative AX y values.
        let upper = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        let rect = CaretLocator.plausibleCocoaRect(
            fromAX: CGRect(x: 200, y: -500, width: 0, height: 18),
            primaryScreenHeight: 900,
            screens: [primary, upper]
        )
        XCTAssertEqual(rect?.minY, 1382)
    }

    func testSingleLineFieldAnchorsAtItsFrame() {
        let field = CGRect(x: 100, y: 400, width: 300, height: 24)
        let anchor = CaretLocator.fieldAnchor(for: field, pointer: CGPoint(x: 900, y: 100))
        XCTAssertEqual(anchor, CaretAnchor(rect: field, source: .field))
    }

    func testTallEditorAnchorsAtPointerWhenPointerIsInside() {
        let editor = CGRect(x: 100, y: 100, width: 600, height: 500)
        let pointer = CGPoint(x: 300, y: 350)
        let anchor = CaretLocator.fieldAnchor(for: editor, pointer: pointer)
        XCTAssertEqual(anchor?.source, .pointer)
        XCTAssertEqual(anchor?.rect.minX, 300)
    }

    func testTallEditorAnchorsAtFirstLineWhenPointerIsOutside() {
        let editor = CGRect(x: 100, y: 100, width: 600, height: 500)
        let anchor = CaretLocator.fieldAnchor(for: editor, pointer: CGPoint(x: 1000, y: 50))
        XCTAssertEqual(anchor?.source, .field)
        XCTAssertEqual(anchor?.rect.minX, 108)
        XCTAssertEqual(anchor?.rect.maxY, 596)
    }

    func testPointerAnchorClearsTheArrowGlyph() {
        let anchor = CaretLocator.pointerAnchor(at: CGPoint(x: 50, y: 500))
        XCTAssertEqual(anchor.rect, CGRect(x: 50, y: 480, width: 0, height: 20))
    }
}

final class PanelPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 264, height: 120)

    func testPlacesPanelJustBelowCaretAlignedToIt() {
        let caret = CGRect(x: 500, y: 600, width: 0, height: 18)
        let origin = PanelPlacement.origin(for: size, anchor: caret, visibleFrames: [screen])
        XCTAssertEqual(origin.x, 500 - PanelPlacement.leadingInset)
        XCTAssertEqual(origin.y + size.height, 600 - PanelPlacement.gap)
    }

    func testFlipsAboveCaretNearTheBottomOfTheScreen() {
        let caret = CGRect(x: 500, y: 60, width: 0, height: 18)
        let origin = PanelPlacement.origin(for: size, anchor: caret, visibleFrames: [screen])
        XCTAssertEqual(origin.y, 78 + PanelPlacement.gap)
    }

    func testClampsToTheRightEdge() {
        let caret = CGRect(x: 1430, y: 600, width: 0, height: 18)
        let origin = PanelPlacement.origin(for: size, anchor: caret, visibleFrames: [screen])
        XCTAssertEqual(origin.x, screen.maxX - size.width - PanelPlacement.margin)
    }

    func testUsesTheScreenTheCaretIsOn() {
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let caret = CGRect(x: 2000, y: 900, width: 0, height: 18)
        let origin = PanelPlacement.origin(for: size, anchor: caret, visibleFrames: [screen, right])
        XCTAssertEqual(origin.x, 2000 - PanelPlacement.leadingInset)
        XCTAssertEqual(origin.y + size.height, 900 - PanelPlacement.gap)
    }

    func testOffScreenAnchorIsPulledOntoTheNearestScreen() {
        let caret = CGRect(x: -300, y: 400, width: 0, height: 18)
        let origin = PanelPlacement.origin(for: size, anchor: caret, visibleFrames: [screen])
        XCTAssertEqual(origin.x, PanelPlacement.margin)
    }
}
