import Testing
import Foundation
@testable import GogglesView
import GogglesXPC

// Roadmap Phase 2 (multi-goggles windows). Everything here is mock/unit
// coverage: only one physical goggles exists, so simultaneous two-device
// streaming is verified only through these routing/registry tests.

private final class StubSession: RegistrableSession {
    let deviceId: String
    var focusCount = 0
    init(_ id: String) { deviceId = id }
    func focus() { focusCount += 1 }
}

@Suite("SessionRegistry")
struct SessionRegistryTests {

    @Test("opening a new device creates one session and makes it active")
    func openCreates() {
        let r = SessionRegistry<StubSession>()
        let (s, created) = r.openOrFocus(deviceId: "A") { StubSession("A") }
        #expect(created)
        #expect(r.count == 1)
        #expect(r.session(for: "A") === s)
        #expect(r.activeSession === s)
    }

    @Test("opening an already-open device focuses it instead of creating a second one")
    func openTwiceFocuses() {
        let r = SessionRegistry<StubSession>()
        let (first, _) = r.openOrFocus(deviceId: "A") { StubSession("A") }
        var factoryCalls = 0
        let (second, created) = r.openOrFocus(deviceId: "A") { factoryCalls += 1; return StubSession("A") }
        #expect(!created)
        #expect(second === first)
        #expect(factoryCalls == 0)
        #expect(first.focusCount == 1)
        #expect(r.count == 1)
    }

    @Test("active session follows markActive; removal falls back to the most recently active")
    func activeTracking() {
        let r = SessionRegistry<StubSession>()
        let a = r.openOrFocus(deviceId: "A") { StubSession("A") }.session
        let b = r.openOrFocus(deviceId: "B") { StubSession("B") }.session
        let c = r.openOrFocus(deviceId: "C") { StubSession("C") }.session
        #expect(r.activeSession === c)
        r.markActive("A")
        #expect(r.activeSession === a)
        r.markActive("B")
        r.remove(deviceId: "B")
        #expect(r.activeSession === a)
        r.remove(deviceId: "A")
        #expect(r.activeSession === c)
        r.remove(deviceId: "C")
        #expect(r.activeSession == nil)
        #expect(r.isEmpty)
        _ = b
    }

    @Test("all keeps open order regardless of focus")
    func openOrder() {
        let r = SessionRegistry<StubSession>()
        ["A", "B", "C"].forEach { id in r.openOrFocus(deviceId: id) { StubSession(id) } }
        r.markActive("A")
        #expect(r.all.map(\.deviceId) == ["A", "B", "C"])
    }

    @Test("removing an unknown device is a no-op; markActive on unknown is ignored")
    func unknownIds() {
        let r = SessionRegistry<StubSession>()
        r.openOrFocus(deviceId: "A") { StubSession("A") }
        #expect(r.remove(deviceId: "zzz") == nil)
        r.markActive("zzz")
        #expect(r.activeSession?.deviceId == "A")
    }

    @Test("observers fire on open, active change and removal (not on no-op changes)")
    func observers() {
        let r = SessionRegistry<StubSession>()
        var fired = 0
        let token = r.addObserver { fired += 1 }
        r.openOrFocus(deviceId: "A") { StubSession("A") }
        r.openOrFocus(deviceId: "B") { StubSession("B") }
        #expect(fired == 2)
        r.markActive("B")          // already active
        #expect(fired == 2)
        r.markActive("A")
        #expect(fired == 3)
        r.remove(deviceId: "A")
        #expect(fired == 4)
        r.removeObserver(token)
        r.remove(deviceId: "B")
        #expect(fired == 4)
    }
}

@Suite("HelperClient per-device routing")
struct HelperClientRoutingTests {

    @Test("callbacks reach only the handlers registered for their deviceId")
    func filtersByDeviceId() {
        let client = HelperClient()
        var aStates: [Int] = [], bStates: [Int] = []
        client.setHandlers(HelperDeviceHandlers(onHelperStateChanged: { s, _ in aStates.append(s) }), for: "A")
        client.setHandlers(HelperDeviceHandlers(onHelperStateChanged: { s, _ in bStates.append(s) }), for: "B")
        client.sendHelperState("A", 1, nil)
        client.sendHelperState("B", 2, nil)
        client.sendHelperState("C", 3, nil)   // nobody registered
        #expect(aStates == [1])
        #expect(bStates == [2])
    }

    @Test("every callback kind is routed per device")
    func allKindsRouted() {
        let client = HelperClient()
        var nal = 0, stats = 0, info: [String?] = [], battery: [Int?] = []
        client.setHandlers(HelperDeviceHandlers(
            onDeviceChanged: { info.append($0?.serial) },
            onNALUnit: { _, _, _, _ in nal += 1 },
            onStats: { _ in stats += 1 },
            onBatteryChanged: { battery.append($0) }
        ), for: "A")
        let dev = DeviceInfo(product: "DJI Goggles 3", serial: "S1", idVendor: 0x2CA3, idProduct: 0x0020, bcdDevice: 0x0100, bus: 1, address: 2)
        let st = StreamStats(fps: 60, bitrateKbps: 1, drops: 0, cumulativeFrames: 1, cumulativeBytes: 1, cumulativeDrops: 0)
        client.sendDeviceInfo("A", dev); client.sendDeviceInfo("B", dev)
        client.sendNAL("A", Data([0, 0, 0, 1, 0x65]), 5, false, 0); client.sendNAL("B", Data([0, 0, 0, 1, 0x65]), 5, false, 0)
        client.sendStats("A", st); client.sendStats("B", st)
        client.sendBattery("A", 80); client.sendBattery("A", -1); client.sendBattery("B", 50)
        #expect(info == ["S1"])
        #expect(nal == 1)
        #expect(stats == 1)
        #expect(battery == [80, nil])
    }

    @Test("removeHandlers stops delivery for that device only")
    func removeHandlers() {
        let client = HelperClient()
        var a = 0, b = 0
        client.setHandlers(HelperDeviceHandlers(onStats: { _ in a += 1 }), for: "A")
        client.setHandlers(HelperDeviceHandlers(onStats: { _ in b += 1 }), for: "B")
        client.removeHandlers(for: "A")
        let st = StreamStats(fps: 60, bitrateKbps: 1, drops: 0, cumulativeFrames: 1, cumulativeBytes: 1, cumulativeDrops: 0)
        client.sendStats("A", st); client.sendStats("B", st)
        #expect(a == 0)
        #expect(b == 1)
    }

    @Test("connection state fans out to every observer plus the legacy closure; removed observers stop")
    func connectionObservers() {
        let client = HelperClient()
        var first: [HelperClientConnectionState] = [], second: [HelperClientConnectionState] = [], legacy = 0
        let t1 = client.addConnectionStateObserver { first.append($0) }
        client.addConnectionStateObserver { second.append($0) }
        client.onConnectionStateChange = { _ in legacy += 1 }
        client.sendConnectionState(.connected)
        client.removeConnectionStateObserver(t1)
        client.sendConnectionState(.disconnected)
        #expect(first == [.connected])
        #expect(second == [.connected, .disconnected])
        #expect(legacy == 2)
    }

    @Test("legacy single closures don't receive callbacks for devices they never started")
    func legacyClosuresScoped() {
        let client = HelperClient()
        var legacy = 0
        client.onHelperStateChanged = { _, _ in legacy += 1 }
        client.sendHelperState("A", 1, nil)  // startStreaming never called -> no legacy device
        #expect(legacy == 0)
    }

    @Test("two coordinators on one client stay independent")
    func twoCoordinators() {
        let client = HelperClient()
        let a = GogglesConnectionCoordinator(client: client, deviceId: "A", startWatchdog: false)
        let b = GogglesConnectionCoordinator(client: client, deviceId: "B", startWatchdog: false)
        client.sendConnectionState(.connected)
        #expect(a.uiState == .noDevice)
        #expect(b.uiState == .noDevice)
        client.sendHelperState("A", GogglesXPC.GogglesState.live.rawValue, nil)
        client.sendHelperState("B", GogglesXPC.GogglesState.claiming.rawValue, nil)
        #expect(a.uiState == .live)
        #expect(b.uiState == .claiming)
        client.sendBattery("B", 42)
        #expect(a.batteryPercent == nil)
        #expect(b.batteryPercent == 42)

        var aNALs = 0
        a.onNALUnit = { _, _, _, _ in aNALs += 1 }
        client.sendNAL("B", Data([0, 0, 0, 1, 0x65]), 5, false, 0)
        #expect(aNALs == 0)
        client.sendNAL("A", Data([0, 0, 0, 1, 0x65]), 5, false, 0)
        #expect(aNALs == 1)
    }

    @Test("detach unhooks one coordinator; the other keeps receiving")
    func detachIsolated() {
        let client = HelperClient()
        let a = GogglesConnectionCoordinator(client: client, deviceId: "A", startWatchdog: false)
        let b = GogglesConnectionCoordinator(client: client, deviceId: "B", startWatchdog: false)
        a.detach()
        #expect(client.router.registeredDeviceIds == ["B"])
        client.sendConnectionState(.connected)
        #expect(a.uiState == .noHelper(reason: nil))
        #expect(b.uiState == .noDevice)
    }

    @Test("a picker and a coordinator share connection-state updates without clobbering")
    func pickerAndCoordinatorCoexist() {
        let client = HelperClient()
        client.enumerateDevicesOverrideForTesting = { [] }
        let coordinator = GogglesConnectionCoordinator(client: client, deviceId: "A", startWatchdog: false)
        let picker = DevicePickerCoordinator(client: client, pollInterval: 999)
        client.sendConnectionState(.versionMismatch(reported: 1, expected: 2))
        #expect(coordinator.uiState.kind == .noHelper)
        guard case .connectionUnavailable = picker.state else {
            Issue.record("picker should also see the failure, got \(picker.state)")
            return
        }
    }
}

@Suite("Multi-window naming, hotkey targeting, unique files, menu-bar summary")
struct MultiWindowMiscTests {

    @Test("device label uses the serial suffix, else the deviceId")
    func deviceLabel() {
        #expect(GogglesSessionNaming.deviceLabel(product: "DJI Goggles 3", serial: "1ABCDE9876", deviceId: "x") == "DJI Goggles 3 (…9876)")
        #expect(GogglesSessionNaming.deviceLabel(product: nil, serial: nil, deviceId: "20:3") == "Goggles (20:3)")
        #expect(GogglesSessionNaming.captureWindowTitle(label: "L") == "GogglesView Capture — L")
        #expect(GogglesSessionNaming.windowMemoryName(deviceId: "A") != GogglesSessionNaming.windowMemoryName(deviceId: "B"))
    }

    @Test("global hotkey notifications target one session; untargeted ones reach all")
    func hotkeyRouting() {
        let a = NSObject(), b = NSObject()
        let targeted = Notification(name: .gogglesToggleRecording, object: a)
        let broadcast = Notification(name: .gogglesToggleRecording, object: nil)
        #expect(GlobalHotkeyRouting.shouldHandle(targeted, session: a))
        #expect(!GlobalHotkeyRouting.shouldHandle(targeted, session: b))
        #expect(GlobalHotkeyRouting.shouldHandle(broadcast, session: b))
    }

    @Test("same-second output names get -2, -3 suffixes")
    func uniqueNames() {
        let base = URL(fileURLWithPath: "/tmp/x/GogglesView-2026-01-01-00-00-00.mov")
        var taken: Set<String> = [base.path]
        let second = UniqueFileURL.firstFree(base) { taken.contains($0.path) }
        #expect(second.lastPathComponent == "GogglesView-2026-01-01-00-00-00-2.mov")
        taken.insert(second.path)
        #expect(UniqueFileURL.firstFree(base) { taken.contains($0.path) }.lastPathComponent == "GogglesView-2026-01-01-00-00-00-3.mov")
        #expect(UniqueFileURL.firstFree(base) { _ in false } == base)
    }

    @Test("reserve never hands out the same name twice in-process")
    func reserveIsExclusive() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniq-\(UUID().uuidString)")
        let base = dir.appendingPathComponent("a.png")
        let first = UniqueFileURL.reserve(base)
        let second = UniqueFileURL.reserve(base)
        #expect(first != second)
    }

    @Test("menu-bar glyph summary: worst state wins")
    func summary() {
        #expect(MenuBarController.summaryCategory([]) == .waiting)
        #expect(MenuBarController.summaryCategory([.live, .live]) == .live)
        #expect(MenuBarController.summaryCategory([.live, .handshaking]) == .waiting)
        #expect(MenuBarController.summaryCategory([.live, .claimFailed, .handshaking]) == .error)
    }
}
