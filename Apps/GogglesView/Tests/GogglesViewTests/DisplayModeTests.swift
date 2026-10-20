import Testing
import Foundation
@testable import GogglesView

private func mode(_ id: Int32, _ w: Int, _ h: Int, hz: Double, hidpi: Bool = false, usable: Bool = true) -> ModeInfo {
    // HiDPI: points are half the pixels.
    ModeInfo(modeID: id, width: hidpi ? w / 2 : w, height: hidpi ? h / 2 : h, pixelWidth: w, pixelHeight: h, hz: hz, usable: usable)
}

private final class FakeConfigurator: DisplayConfigurator {
    var main: UInt32 = 1
    var current: [UInt32: ModeInfo] = [:]
    var available: [UInt32: [ModeInfo]] = [:]
    var sets: [(UInt32, Int32)] = []
    var accept = true
    func isMain(_ d: UInt32) -> Bool { d == main }
    func currentMode(_ d: UInt32) -> ModeInfo? { current[d] }
    func modes(_ d: UInt32) -> [ModeInfo] { available[d] ?? [] }
    func set(_ m: ModeInfo, on d: UInt32) -> Bool {
        sets.append((d, m.modeID)); if accept { current[d] = m }; return accept
    }
}

@Suite struct DisplayModeTests {
    @Test func prefersSameRefreshRate() {
        let modes = [mode(1, 1920, 1080, hz: 30), mode(2, 1920, 1080, hz: 60), mode(3, 1920, 1080, hz: 50)]
        #expect(DisplayModePicker.pick(from: modes, target: (1920, 1080), currentHz: 60)?.modeID == 2)
        #expect(DisplayModePicker.pick(from: modes, target: (1920, 1080), currentHz: 49)?.modeID == 3)
    }

    @Test func ignoresHiDPIWhenNativeExists() {
        let modes = [mode(1, 1920, 1080, hz: 60, hidpi: true), mode(2, 1920, 1080, hz: 30)]
        #expect(DisplayModePicker.pick(from: modes, target: (1920, 1080), currentHz: 60)?.modeID == 2)
    }

    @Test func nilWhenNothingMatchesOrUnusable() {
        #expect(DisplayModePicker.pick(from: [mode(1, 3840, 2160, hz: 60)], target: (1920, 1080), currentHz: 60) == nil)
        #expect(DisplayModePicker.pick(from: [mode(1, 1920, 1080, hz: 60, usable: false)], target: (1920, 1080), currentHz: 60) == nil)
        #expect(DisplayModePicker.pick(from: [], target: (1280, 720), currentHz: 60) == nil)
    }

    @Test func neverChangesTheMainDisplay() {
        let f = FakeConfigurator()
        f.current[1] = mode(10, 3840, 2160, hz: 60); f.available[1] = [mode(11, 1920, 1080, hz: 60)]
        let m = DisplayResolutionManager(configurator: f)
        #expect(m.sync([1: .p1080]) == [1: .refusedMain])
        #expect(f.sets.isEmpty)
    }

    @Test func appliesThenRestoresOriginal() {
        let f = FakeConfigurator()
        f.current[2] = mode(10, 3840, 2160, hz: 60); f.available[2] = [mode(10, 3840, 2160, hz: 60), mode(11, 1920, 1080, hz: 60)]
        let m = DisplayResolutionManager(configurator: f)
        #expect(m.sync([2: .p1080]) == [2: .applied("1920x1080")])
        #expect(f.current[2]?.modeID == 11)
        _ = m.sync([2: .p1080])                       // idempotent: no second switch
        #expect(f.sets.count == 1)
        #expect(m.sync([:]).isEmpty)                  // output closed
        #expect(f.current[2]?.modeID == 10)
        #expect(m.changedDisplays.isEmpty)
    }

    @Test func switchingToDefaultOrQuitRestores() {
        let f = FakeConfigurator()
        f.current[2] = mode(10, 3840, 2160, hz: 60); f.available[2] = [mode(11, 1280, 720, hz: 60)]
        let m = DisplayResolutionManager(configurator: f)
        _ = m.sync([2: .p720])
        _ = m.sync([2: .displayDefault])
        #expect(f.current[2]?.modeID == 10)
        _ = m.sync([2: .p720]); m.restoreAll()
        #expect(f.current[2]?.modeID == 10)
    }

    @Test func noMatchLeavesDisplayAlone() {
        let f = FakeConfigurator()
        f.current[2] = mode(10, 3840, 2160, hz: 60); f.available[2] = [mode(10, 3840, 2160, hz: 60)]
        let m = DisplayResolutionManager(configurator: f)
        #expect(m.sync([2: .p1080]) == [2: .noMatchingMode("1920x1080")])
        #expect(f.sets.isEmpty && m.changedDisplays.isEmpty)
        f.accept = false; f.available[2] = [mode(11, 1920, 1080, hz: 60)]
        #expect(m.sync([2: .p1080]) == [2: .failed])
        #expect(m.changedDisplays.isEmpty, "a refused change must not leave a bogus original to restore")
    }

    @Test func oldConfigJSONDecodesToDisplayDefault() throws {
        let json = #"[{"id":"A","display":5,"layout":"single","feed":"x","showNames":false}]"#
        let list = try JSONDecoder().decode([ProgramOutputConfig].self, from: Data(json.utf8))
        #expect(list[0].outputResolution == .displayDefault)
        var c = list[0]; c.resolution = "1080p"
        let back = try JSONDecoder().decode(ProgramOutputConfig.self, from: JSONEncoder().encode(c))
        #expect(back.outputResolution == .p1080)
        c.resolution = "weird"
        #expect(c.outputResolution == .displayDefault)
    }
}
