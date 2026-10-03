import XCTest
@testable import GogglesView

final class EventHooksTests: XCTestCase {
    func testPayloadJSON() throws {
        let s = EventHookLogic.payloadJSON(event: .screenshotSaved, fields: ["path": "/tmp/a.png"], date: Date(timeIntervalSince1970: 0))
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
        XCTAssertEqual(obj["event"] as? String, "screenshotSaved")
        XCTAssertEqual(obj["path"] as? String, "/tmp/a.png")
        XCTAssertEqual(obj["timestamp"] as? String, "1970-01-01T00:00:00Z")
    }

    func testPayloadDropsNonJSONValues() throws {
        let s = EventHookLogic.payloadJSON(event: .streamLive, fields: ["bad": Date(), "n": 3])
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
        XCTAssertNil(obj["bad"])
        XCTAssertEqual(obj["n"] as? Int, 3)
    }

    func testEnvironment() {
        let env = EventHookLogic.environment(base: ["A": "1"], event: .batteryLow, payload: "{}")
        XCTAssertEqual(env["GOGGLES_EVENT"], "batteryLow")
        XCTAssertEqual(env["GOGGLES_PAYLOAD"], "{}")
        XCTAssertEqual(env["A"], "1")
    }

    func testBatteryCrossing() {
        XCTAssertTrue(EventHookLogic.batteryCrossedBelow(previous: 15, current: 14, threshold: 15))
        XCTAssertFalse(EventHookLogic.batteryCrossedBelow(previous: 14, current: 13, threshold: 15))
        XCTAssertFalse(EventHookLogic.batteryCrossedBelow(previous: nil, current: 5, threshold: 15))
        XCTAssertFalse(EventHookLogic.batteryCrossedBelow(previous: 50, current: nil, threshold: 15))
        XCTAssertFalse(EventHookLogic.batteryCrossedBelow(previous: 10, current: 90, threshold: 15))
    }

    func testStreamEvents() {
        XCTAssertEqual(EventHookLogic.streamEvent(from: .waitingForKeyframe, to: .live), .streamLive)
        XCTAssertEqual(EventHookLogic.streamEvent(from: .live, to: .stalled), .streamLost)
        XCTAssertNil(EventHookLogic.streamEvent(from: .live, to: .live))
        XCTAssertNil(EventHookLogic.streamEvent(from: nil, to: .noDevice))
    }

    func testWebhookValidation() {
        XCTAssertNotNil(EventHookLogic.validWebhook("https://example.com/x"))
        XCTAssertNil(EventHookLogic.validWebhook("file:///etc/passwd"))
        XCTAssertNil(EventHookLogic.validWebhook("example.com"))
    }
}
