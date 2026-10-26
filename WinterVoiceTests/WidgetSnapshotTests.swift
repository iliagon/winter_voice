import AppKit
import SwiftUI
import XCTest
@testable import WinterVoice

/// Renders every widget state to PNGs so layout changes can be reviewed
/// without launching the app. Output lands in the directory named by the
/// WIDGET_SNAPSHOT_DIR environment variable; the test is skipped when the
/// variable is absent (normal CI runs).
@MainActor
final class WidgetSnapshotTests: XCTestCase {
    func testRenderWidgetStates() throws {
        guard let path = ProcessInfo.processInfo.environment["WIDGET_SNAPSHOT_DIR"] else {
            throw XCTSkip("WIDGET_SNAPSHOT_DIR not set")
        }
        let outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let relay = DictationStateRelay()
        let presenter = DictationPresenter(
            interactor: SnapshotInteractorFake(),
            relay: relay,
            hotkeyRelay: HotkeyHealthRelay(),
            permissionManager: SnapshotPermissionFake(),
            router: AppRouter()
        )
        let meter = AudioLevelMeter()
        meter.update(0.8)

        func snap(_ name: String, style: WidgetStyle) throws {
            let view = ZStack {
                Color(red: 0.35, green: 0.42, blue: 0.55)
                RecordingPanelView(presenter: presenter, levelMeter: meter, style: style)
                    .padding(16)
            }
            .fixedSize()
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("Could not render \(name)")
                return
            }
            let url = outputDirectory.appendingPathComponent("\(name).png")
            try png.write(to: url)
            print("SNAPSHOT \(name): \(Int(image.size.width))x\(Int(image.size.height))")
        }

        relay.publish(.idle)
        try snap("idle-labeled", style: .labeled)
        try snap("idle-icon", style: .icon)
        try snap("idle-minimal", style: .minimal)

        relay.publish(.recording)
        try snap("recording", style: .labeled)

        relay.publish(.failed(DictationFailure(
            message: "Microphone access denied.",
            recovery: "Enable it in System Settings."
        )))
        try snap("error-short", style: .labeled)

        relay.publish(.failed(DictationFailure(
            message: "The transcription service could not be reached because the network connection appears to be offline right now.",
            recovery: "Check your internet connection, verify the server URL in Settings, and then try dictating again."
        )))
        try snap("error-long", style: .labeled)

        // The longest strings the app actually ships — these must render in
        // full, unlike the synthetic overflow case above.
        relay.publish(.failed(DictationFailure(
            message: "Remote transcription failed (HTTP 503).",
            recovery: "whisper.cpp models begin with the ggml header. Download a ggml-*.bin model and try again."
        )))
        try snap("error-shipped-longest", style: .labeled)

        relay.publish(.failed(DictationFailure(
            message: "The remote provider returned an invalid response.",
            recovery: "Open Settings and allow MacVoice in Privacy & Security → Accessibility."
        )))
        try snap("error-shipped-wide", style: .labeled)
    }
}

/// The panel is a borderless window sized by hand from the SwiftUI content;
/// if it lags the content, the failure card is squeezed into the idle pill's
/// frame and its text truncates.
@MainActor
final class RecordingPanelSizingTests: XCTestCase {
    func testPanelFrameTracksFailureCard() throws {
        let suite = UserDefaults(suiteName: "recording-panel-sizing-tests")!
        suite.removePersistentDomain(forName: "recording-panel-sizing-tests")
        let relay = DictationStateRelay()
        let presenter = DictationPresenter(
            interactor: SnapshotInteractorFake(),
            relay: relay,
            hotkeyRelay: HotkeyHealthRelay(),
            permissionManager: SnapshotPermissionFake(),
            router: AppRouter()
        )
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = RecordingPanelController(
            presenter: presenter,
            levelMeter: AudioLevelMeter(),
            preferences: WidgetPreferences(defaults: suite),
            defaults: suite
        )
        let panel = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) })
        defer { panel.orderOut(nil); _ = controller }

        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        func assertPanelFitsContent(_ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let fitting = try XCTUnwrap(panel.contentView).fittingSize
            XCTAssertEqual(panel.frame.width, fitting.width, accuracy: 1, label, file: file, line: line)
            XCTAssertEqual(panel.frame.height, fitting.height, accuracy: 1, label, file: file, line: line)
        }

        settle()
        try assertPanelFitsContent("idle")
        let idleSize = panel.frame.size

        relay.publish(.failed(DictationFailure(
            message: "The remote provider returned an invalid response.",
            recovery: "whisper.cpp models begin with the ggml header. Download a ggml-*.bin model and try again."
        )))
        settle()
        try assertPanelFitsContent("failed")
        XCTAssertGreaterThan(panel.frame.width, idleSize.width)
        XCTAssertGreaterThan(panel.frame.height, idleSize.height)

        relay.publish(.idle)
        settle()
        try assertPanelFitsContent("idle again")
        XCTAssertEqual(panel.frame.width, idleSize.width, accuracy: 1)
        XCTAssertEqual(panel.frame.height, idleSize.height, accuracy: 1)
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
