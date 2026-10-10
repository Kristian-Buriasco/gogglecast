import Testing
import Foundation
@testable import GogglesView

@Suite struct StaleHelperCheckTests {
    private let installed = Date(timeIntervalSince1970: 1_000_000)

    @Test func helperStartedBeforeTheNewFileIsStale() {
        #expect(StaleHelperCheck.isStale(processStart: installed.addingTimeInterval(-3600), binaryInstalled: installed))
    }

    @Test func helperStartedAfterTheFileIsFine() {
        #expect(!StaleHelperCheck.isStale(processStart: installed.addingTimeInterval(60), binaryInstalled: installed))
        #expect(!StaleHelperCheck.isStale(processStart: installed.addingTimeInterval(-1), binaryInstalled: installed), "within the slack")
    }

    @Test func unknownTimesAreNeverTreatedAsStale() {
        #expect(!StaleHelperCheck.isStale(processStart: nil, binaryInstalled: installed))
        #expect(!StaleHelperCheck.isStale(processStart: installed, binaryInstalled: nil))
    }

    @Test func aProcessThatDoesNotExistHasNoStartTime() {
        #expect(StaleHelperCheck.runningHelperStart(name: "NoSuchProcessNameXYZ") == nil)
    }

    @Test func aRootProcessStartTimeIsReadable() {
        // launchd runs as root, like the helper daemon
        let start = StaleHelperCheck.runningHelperStart(name: "launchd")
        #expect(start != nil && start! < Date())
    }
}
