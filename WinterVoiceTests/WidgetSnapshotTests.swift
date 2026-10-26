import AppKit
import SwiftUI
import XCTest
@testable import WinterVoice

/// Renders every panel phase to PNGs so layout changes can be reviewed
/// without launching the app. Output lands in the directory named by the
/// WIDGET_SNAPSHOT_DIR environment variable; the test is skipped when the
/// variable is absent (normal CI runs).
@MainActor
final class WidgetSnapshotTests: XCTestCase {
    func testRenderPanelPhases() throws {
        guard let path = ProcessInfo.processInfo.environment["WIDGET_SNAPSHOT_DIR"] else {
            throw XCTSkip("WIDGET_SNAPSHOT_DIR not set")
        }
        let outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let model = RecordingPanelModel()
        model.isPresented = true
        let meter = AudioLevelMeter()
        meter.update(0.8)

        func write(_ name: String, _ content: some View) throws {
            let renderer = ImageRenderer(content: content.fixedSize())
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("Could not render \(name)")
                return
            }
            try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
            print("SNAPSHOT \(name): \(Int(image.size.width))x\(Int(image.size.height))")
        }

        /// The panel at its real size over a fake text line, so the caret's
        /// relation to the pill is visible.
        func snap(_ name: String) throws {
            let caretY: CGFloat = model.edge == .below
                ? 0
                : RecordingPanelController.panelSize.height + PanelPlacement.gap
            let scene = ZStack(alignment: .topLeading) {
                Color(red: 0.93, green: 0.93, blue: 0.95)
                Text("Hello, this is a text field")
                    .font(.system(size: 13))
                    .foregroundStyle(.black)
                    .offset(x: 24, y: caretY + 2)
                Rectangle()
                    .fill(Color.blue)
                    .frame(width: 1.5, height: 18)
                    .offset(x: 40, y: caretY)
                RecordingPanelView(model: model, levelMeter: meter, drawsCheckmarkInstantly: true)
                    .frame(
                        width: RecordingPanelController.panelSize.width,
                        height: RecordingPanelController.panelSize.height
                    )
                    .offset(x: 40 - PanelPlacement.leadingInset, y: model.edge == .below ? 20 : 0)
            }
            .frame(width: 320, height: RecordingPanelController.panelSize.height + 40)
            try write(name, scene)
        }

        model.phase = .listening
        try snap("1-listening")
        model.phase = .transcribing
        try snap("2-transcribing")
        model.phase = .done
        try snap("3-done")
        model.phase = .failed(DictationFailure(
            message: "Remote transcription failed (HTTP 503).",
            recovery: "Open Settings and allow MacVoice in Privacy & Security → Accessibility."
        ))
        try snap("4-failed")
        model.edge = .above
        model.phase = .listening
        try snap("5-listening-above")
    }
}

/// The panel is a fixed-size click-through window placed next to the caret;
/// it must appear for a session, sit by the published anchor, and go away
/// when the session ends.
@MainActor
final class RecordingPanelControllerTests: XCTestCase {
    func testPanelAppearsBelowAnchorAndHidesWhenIdle() throws {
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let relay = DictationStateRelay()
        let presenter = DictationPresenter(
            interactor: SnapshotInteractorFake(),
            relay: relay,
            hotkeyRelay: HotkeyHealthRelay(),
            permissionManager: SnapshotPermissionFake(),
            router: AppRouter()
        )
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = RecordingPanelController(presenter: presenter, levelMeter: AudioLevelMeter())
        let panel = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) })
        defer { panel.orderOut(nil) }

        func settle(_ seconds: TimeInterval = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isVisible)

        let caret = CGRect(x: screen.midX, y: screen.midY, width: 0, height: 18)
        relay.publish(.preparing)
        relay.publish(anchor: CaretAnchor(rect: caret, source: .caret))
        settle()
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame.minX, caret.minX - PanelPlacement.leadingInset, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY, caret.minY - PanelPlacement.gap, accuracy: 0.5)
        XCTAssertEqual(controller.model.edge, .below)
        XCTAssertEqual(controller.model.phase, .listening)

        relay.publish(.recording)
        relay.publish(.processing)
        settle()
        XCTAssertEqual(controller.model.phase, .transcribing)
        XCTAssertEqual(panel.frame.minX, caret.minX - PanelPlacement.leadingInset, accuracy: 0.5,
                       "The panel must not move during a session")

        relay.publish(.inserting)
        relay.publish(.done)
        settle()
        XCTAssertEqual(controller.model.phase, .done)

        relay.publish(.idle)
        settle(0.4)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(controller.model.isPresented)
    }

    func testSessionWithoutAnchorFallsBackToPointer() throws {
        let relay = DictationStateRelay()
        let presenter = DictationPresenter(
            interactor: SnapshotInteractorFake(),
            relay: relay,
            hotkeyRelay: HotkeyHealthRelay(),
            permissionManager: SnapshotPermissionFake(),
            router: AppRouter()
        )
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = RecordingPanelController(presenter: presenter, levelMeter: AudioLevelMeter())
        let panel = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) })
        defer { panel.orderOut(nil); _ = controller }

        relay.publish(.failed(DictationFailure(message: "No editable field is focused.", recovery: "Focus one.")))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(panel.isVisible, "The panel waits briefly for a caret before falling back")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(panel.isVisible)
    }
}

@MainActor
final class SidebarSnapshotTests: XCTestCase {
    func testRenderSidebar() throws {
        guard let path = ProcessInfo.processInfo.environment["WIDGET_SNAPSHOT_DIR"] else {
            throw XCTSkip("WIDGET_SNAPSHOT_DIR not set")
        }
        let outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-snapshot", isDirectory: true)
        let presenter = AppShellPresenter(
            dictationPresenter: DictationPresenter(
                interactor: SnapshotInteractorFake(),
                relay: DictationStateRelay(),
                hotkeyRelay: HotkeyHealthRelay(),
                permissionManager: SnapshotPermissionFake(),
                router: AppRouter()
            ),
            router: AppRouter(),
            providerConfiguration: ProviderConfigurationStore(),
            history: HistoryStore(root: temp),
            hotkeyBinding: HotkeyBindingStore()
        )

        let view = WVSidebar(presenter: presenter)
            .frame(height: 480)
            .background(Color(nsColor: .windowBackgroundColor))
            .fixedSize()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Could not render sidebar")
            return
        }
        try png.write(to: outputDirectory.appendingPathComponent("sidebar.png"))
        print("SNAPSHOT sidebar: \(Int(image.size.width))x\(Int(image.size.height))")
    }
}

@MainActor
final class SnapshotInteractorFake: DictationInteracting {
    func beginPushToTalk() {}
    func endPushToTalk() {}
    func togglePushToTalk() {}
}

@MainActor
private final class SnapshotPermissionFake: PermissionManaging {
    func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(microphone: .authorized, inputMonitoring: .authorized, accessibility: .authorized)
    }

    func request(_ permission: AppPermission) async -> PermissionStatus { .authorized }
}
