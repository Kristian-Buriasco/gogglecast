import XCTest
@testable import GogglesView

final class ShortcutsIntentsTests: XCTestCase {
    func testRequestMapping() {
        XCTAssertEqual(ShortcutsMapping.request(.startRecording, device: nil),
                       AutomationRequest(command: .startRecording, device: nil))
        XCTAssertEqual(ShortcutsMapping.request(.screenshot, device: " ABC-1 "),
                       AutomationRequest(command: .screenshot, device: "ABC-1"))
        XCTAssertEqual(ShortcutsMapping.request(.screenshot, device: "  "),
                       AutomationRequest(command: .screenshot, device: nil))
        XCTAssertNil(ShortcutsMapping.request(.screenshot, device: "../etc"))
        XCTAssertNil(ShortcutsMapping.request(.screenshot, device: "a b"))
    }

    func testMarkerCommand() {
        XCTAssertEqual(ShortcutsMapping.markerCommand(label: nil), .addMarker(label: "Marker"))
        XCTAssertEqual(ShortcutsMapping.markerCommand(label: "  "), .addMarker(label: "Marker"))
        XCTAssertEqual(ShortcutsMapping.markerCommand(label: "Lap 1\n"), .addMarker(label: "Lap 1"))
        XCTAssertEqual(ShortcutsMapping.markerCommand(label: String(repeating: "x", count: 100)),
                       .addMarker(label: String(repeating: "x", count: 64)))
    }

    func testMessages() {
        XCTAssertEqual(ShortcutsMapping.successMessage(.startRecording), "Recording started")
        XCTAssertEqual(ShortcutsMapping.successMessage(.addMarker(label: "Lap 1")), "Marker added: Lap 1")
        XCTAssertNil(ShortcutsMapping.failureMessage(disabled: false, noTarget: false, device: nil))
        XCTAssertTrue(ShortcutsMapping.failureMessage(disabled: false, noTarget: true, device: nil)!.contains("No goggles are live"))
        XCTAssertTrue(ShortcutsMapping.failureMessage(disabled: false, noTarget: true, device: "X")!.contains("match that device"))
        XCTAssertTrue(ShortcutsMapping.failureMessage(disabled: true, noTarget: true, device: nil)!.contains("turned off"))
    }

    func testStatusSummary() {
        XCTAssertEqual(GogglesStatusSnapshot(gogglesCount: 0, recording: false, fps: nil, batteryPercent: nil).summary,
                       "No goggles window is open.")
        XCTAssertEqual(GogglesStatusSnapshot(gogglesCount: 1, recording: true, fps: 60, batteryPercent: 82).summary,
                       "1 goggles connected, recording, 60 fps, battery 82%")
        XCTAssertEqual(GogglesStatusSnapshot(gogglesCount: 2, recording: false, fps: nil, batteryPercent: nil).summary,
                       "2 goggles connected, not recording")
    }
}
