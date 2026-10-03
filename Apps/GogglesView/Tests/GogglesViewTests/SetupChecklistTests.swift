import Testing
import Foundation
@testable import GogglesView

struct SetupChecklistTests {
    private func status(_ items: [SetupChecklist.Item], _ id: String) -> SetupChecklist.Status {
        items.first { $0.id == id }!.status
    }

    @Test func allGood() {
        let i = SetupChecklist.items(registration: .enabled, reachability: .connected, devicesFound: 1)
        #expect(i.map(\.status) == [.pass, .pass, .pass])
        #expect(i.allSatisfy { $0.fix == nil })
    }

    @Test func noDevicesShowsOTGFix() {
        let i = SetupChecklist.items(registration: .enabled, reachability: .connected, devicesFound: 0)
        #expect(status(i, "usb-device") == .fail)
        #expect(i[2].fix?.contains("OTG Wired Connection") == true)
    }

    @Test func requiresApprovalHasLoginItemsAction() {
        let i = SetupChecklist.items(registration: .requiresApproval, reachability: .disconnected, devicesFound: nil)
        #expect(status(i, "helper-registered") == .fail)
        #expect(i[0].action == .openLoginItems)
        #expect(status(i, "helper-reachable") == .fail)
        #expect(status(i, "usb-device") == .unknown)
    }

    @Test func versionMismatchFailsReachability() {
        let i = SetupChecklist.items(registration: .enabled, reachability: .versionMismatch, devicesFound: nil)
        #expect(status(i, "helper-reachable") == .fail)
        #expect(status(i, "usb-device") == .unknown)
    }

    @Test func unknownInputsStayUnknown() {
        let i = SetupChecklist.items(registration: .unknown, reachability: .unknown, devicesFound: nil)
        #expect(i.map(\.status) == [.unknown, .unknown, .unknown])
    }

    @Test func connectingIsUnknownNotFail() {
        let i = SetupChecklist.items(registration: .enabled, reachability: .connecting, devicesFound: 0)
        #expect(status(i, "helper-reachable") == .unknown)
        #expect(status(i, "usb-device") == .unknown)
    }

    @Test func meterFps() {
        var m = StreamTestMeter()
        #expect(!m.gotFirstFrame && m.fps(endingAt: 10) == nil)
        for k in 0..<61 { m.recordFrame(at: 1 + Double(k) / 60) }
        #expect(m.gotFirstFrame)
        #expect(abs(m.fps(endingAt: 2)! - 60) < 0.001)
    }

    @Test func meterSingleFrameNoFps() {
        var m = StreamTestMeter()
        m.recordFrame(at: 1)
        #expect(m.fps(endingAt: 6) == nil)
    }
}
