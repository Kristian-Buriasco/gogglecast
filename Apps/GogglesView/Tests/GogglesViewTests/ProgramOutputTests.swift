import Testing
import Foundation
import CoreGraphics
@testable import GogglesView

@Suite struct ProgramOutputTests {
    @Test func gridDimensions() {
        let expected: [(Int, Int, Int)] = [(1, 1, 1), (2, 2, 1), (3, 2, 2), (4, 2, 2), (5, 3, 2), (6, 3, 2),
                                           (7, 3, 3), (9, 3, 3), (10, 4, 3), (12, 4, 3), (13, 4, 4), (16, 4, 4)]
        for (n, c, r) in expected {
            let g = ProgramLayoutMath.grid(count: n)
            #expect(g.cols == c && g.rows == r, "count \(n): got \(g)")
            #expect(g.cols * g.rows >= n)
        }
        #expect(ProgramLayoutMath.grid(count: 0) == (1, 1))
    }

    @Test func tilesCoverTheScreenWithoutOverlap() {
        let size = CGSize(width: 1920, height: 1080)
        for n in [1, 2, 3, 5, 9, 10] {
            let rects = (0..<n).map { ProgramLayoutMath.tile(index: $0, count: n, in: size) }
            for r in rects { #expect(r.minX >= 0 && r.minY >= 0 && r.maxX <= size.width + 0.001 && r.maxY <= size.height + 0.001) }
            for i in 0..<n { for j in (i + 1)..<max(n, i + 1) { #expect(!rects[i].insetBy(dx: 0.5, dy: 0.5).intersects(rects[j])) } }
        }
        #expect(ProgramLayoutMath.tile(index: 0, count: 1, in: size) == CGRect(origin: .zero, size: size))
    }

    private let screens = [ProgramScreenInfo(id: 1, name: "Built-in", isMain: true),
                           ProgramScreenInfo(id: 7, name: "HDMI", isMain: false)]

    @Test func automaticPicksTheFirstExternalDisplay() {
        #expect(ProgramDisplayChoice.pick(preferred: 0, screens: screens) == 7)
    }

    @Test func automaticNeverCoversTheOnlyScreen() {
        #expect(ProgramDisplayChoice.pick(preferred: 0, screens: [screens[0]]) == nil)
    }

    @Test func explicitChoiceWinsEvenOnTheMainDisplay() {
        #expect(ProgramDisplayChoice.pick(preferred: 1, screens: screens) == 1)
    }

    @Test func unpluggedChoiceDoesNotJumpToAnotherDisplay() {
        #expect(ProgramDisplayChoice.pick(preferred: 9, screens: screens) == nil)
    }

    @Test func defaultNamesAreNumberedAndNeverContainSerials() {
        let names = ProgramFeedNaming.names(deviceIds: ["1581F5FHC23B1234", "bus-2"], custom: [:])
        #expect(names == ["Feed 1", "Feed 2"])
        #expect(!names.joined().contains("1581"))
    }

    @Test func customNamesWinAndAreSanitized() {
        let names = ProgramFeedNaming.names(deviceIds: ["a", "b"], custom: ["a": "  Runner 3\n", "b": "   "])
        #expect(names == ["Runner 3", "Feed 2"])
        #expect(ProgramOutputPrefs.sanitizeName(String(repeating: "x", count: 60)).count == 24)
        #expect(ProgramOutputPrefs.sanitizeName("a\u{0007}b\tc") == "abc")
    }

    @Test func feedNamesAreStoredAndCleared() {
        let d = UserDefaults(suiteName: "program-\(UUID().uuidString)")!
        ProgramOutputPrefs.setFeedName("Runner 1", for: "dev", defaults: d)
        #expect(ProgramOutputPrefs.feedNames(d)["dev"] == "Runner 1")
        ProgramOutputPrefs.setFeedName("  ", for: "dev", defaults: d)
        #expect(ProgramOutputPrefs.feedNames(d)["dev"] == nil)
    }

    @Test func defaultsAreOffWithOneGridOutput() {
        let d = UserDefaults(suiteName: "program-\(UUID().uuidString)")!
        #expect(!ProgramOutputPrefs.enabled(d))
        let outs = ProgramOutputPrefs.outputs(d)
        #expect(outs.count == 1 && outs[0].isGrid && outs[0].showNames && outs[0].display == 0)
    }

    @Test func outputListRoundTripsAndIsCapped() {
        let d = UserDefaults(suiteName: "program-\(UUID().uuidString)")!
        var list = (0..<6).map { i -> ProgramOutputConfig in var o = ProgramOutputConfig(); o.display = UInt32(i); return o }
        list[1].layout = "single"; list[1].feed = "dev"
        ProgramOutputPrefs.setOutputs(list, defaults: d)
        let back = ProgramOutputPrefs.outputs(d)
        #expect(back.count == ProgramOutputPrefs.maxOutputs)
        #expect(back[1].layout == "single" && back[1].feed == "dev" && !back[1].isGrid)
    }

    private let three = [ProgramScreenInfo(id: 1, name: "Built-in", isMain: true),
                         ProgramScreenInfo(id: 7, name: "HDMI 1", isMain: false),
                         ProgramScreenInfo(id: 8, name: "HDMI 2", isMain: false)]

    @Test func twoAutomaticOutputsGetTwoDifferentExternalDisplays() {
        let a = ProgramDisplayChoice.assign(outputs: [ProgramOutputConfig(), ProgramOutputConfig()], screens: three)
        #expect(a == [7, 8])
    }

    @Test func automaticDoesNotStealADisplayPickedByALaterOutput() {
        var second = ProgramOutputConfig(); second.display = 7
        let a = ProgramDisplayChoice.assign(outputs: [ProgramOutputConfig(), second], screens: three)
        #expect(a == [8, 7])
    }

    @Test func twoOutputsOnTheSameDisplayShowOnlyTheFirst() {
        var a = ProgramOutputConfig(); a.display = 7
        var b = ProgramOutputConfig(); b.display = 7
        #expect(ProgramDisplayChoice.assign(outputs: [a, b], screens: three) == [7, nil])
    }

    @Test func moreAutomaticOutputsThanDisplaysLeavesTheRestOff() {
        let outs = [ProgramOutputConfig(), ProgramOutputConfig(), ProgramOutputConfig()]
        #expect(ProgramDisplayChoice.assign(outputs: outs, screens: three) == [7, 8, nil])
    }
}
