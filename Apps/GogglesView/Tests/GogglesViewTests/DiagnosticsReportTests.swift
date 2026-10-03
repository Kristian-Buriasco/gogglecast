import Testing
import Foundation
@testable import GogglesView

struct DiagnosticsReportTests {
    @Test func redactsHome() {
        #expect(DiagnosticsReport.redactHome("/Users/bob/Movies/x", home: "/Users/bob") == "~/Movies/x")
        #expect(DiagnosticsReport.redactHome("/tmp/x", home: "/Users/bob") == "/tmp/x")
    }
    @Test func redactsSerial() {
        #expect(DiagnosticsReport.redactSerial("ABCDEF123456") == "…3456")
        #expect(DiagnosticsReport.redactSerial("abc") == "***")
    }
    @Test func tailKeepsLastLines() {
        let t = (1...300).map(String.init).joined(separator: "\n") + "\n"
        let out = DiagnosticsReport.tail(t, lines: 150)
        #expect(out.split(separator: "\n").count == 150)
        #expect(out.hasSuffix("300"))
    }
    @Test func tailTruncatesBytes() {
        let out = DiagnosticsReport.tail(String(repeating: "a", count: 1000), maxBytes: 100)
        #expect(out.hasPrefix("[truncated]"))
        #expect(out.utf8.count <= 100 + 12)
    }
    @Test func formatsSettingsAndSections() {
        let s = DiagnosticsReport.formatSettings([("recordingFolder", "/Users/bob/Movies"), ("n", 3)], home: "/Users/bob")
        #expect(s == "  recordingFolder = ~/Movies\n  n = 3")
        #expect(DiagnosticsReport.assemble(sections: [("A", "x")]) == "== A ==\nx\n")
    }
}
