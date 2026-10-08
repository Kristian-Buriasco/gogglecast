import XCTest
@testable import GogglesView

/// Checks the translation files in BundleResources/Localization against each other and
/// the `L` helper. The files are read straight from the repository (via `#filePath`)
/// because the test process has no app bundle with `.lproj` folders.
final class LocalizationTests: XCTestCase {
    private static var localizationDir: URL {
        // Tests/GogglesViewTests/LocalizationTests.swift -> Apps/GogglesView
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BundleResources/Localization", isDirectory: true)
    }

    private static var repoRoot: URL {
        localizationDir.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func languages() throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.localizationDir.path)
        return names.filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) }.sorted()
    }

    private func table(_ lang: String) throws -> [String: String] {
        let path = Self.localizationDir.appendingPathComponent("\(lang).lproj/Localizable.strings").path
        let dict = NSDictionary(contentsOfFile: path) as? [String: String]
        return try XCTUnwrap(dict, "\(lang).lproj/Localizable.strings does not parse")
    }

    /// Kinds of the format specifiers in `s`, in argument order (positional forms resolved).
    static func specifierKinds(_ s: String) -> [String]? {
        let text = s.replacingOccurrences(of: "%%", with: "")
        let pattern = #"%(?:(\d+)\$)?[-+0#]*(?:\d+|\*)?(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSp])"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
        var plain: [String] = []
        var positional: [Int: String] = [:]
        let ns = text as NSString
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let conv = ns.substring(with: m.range(at: 2))
            let kind: String
            switch conv {
            case "@": kind = "object"
            case "s", "S": kind = "string"
            case "f", "F", "e", "E", "g", "G": kind = "float"
            default: kind = "int"
            }
            if m.range(at: 1).location != NSNotFound, let n = Int(ns.substring(with: m.range(at: 1))) {
                positional[n] = kind
            } else {
                plain.append(kind)
            }
        }
        if positional.isEmpty { return plain }
        guard plain.isEmpty, Array(positional.keys).sorted() == Array(1...positional.count) else { return nil }
        return (1...positional.count).map { positional[$0]! }
    }

    func testEnglishTableHasKeys() throws {
        let en = try table("en")
        XCTAssertGreaterThan(en.count, 100)
        for (k, v) in en { XCTAssertEqual(k, v, "en.lproj must map every key to itself") }
    }

    func testEveryLanguageHasEveryEnglishKey() throws {
        let en = try table("en")
        for lang in try languages() where lang != "en" {
            let t = try table(lang)
            let missing = Set(en.keys).subtracting(t.keys)
            XCTAssertTrue(missing.isEmpty, "\(lang) is missing \(missing.count) key(s), e.g. \(missing.sorted().prefix(3))")
            let extra = Set(t.keys).subtracting(en.keys)
            XCTAssertTrue(extra.isEmpty, "\(lang) has \(extra.count) key(s) not in en, e.g. \(extra.sorted().prefix(3))")
        }
    }

    func testFormatSpecifiersMatchTheEnglishKey() throws {
        for lang in try languages() where lang != "en" {
            for (key, value) in try table(lang) {
                let a = Self.specifierKinds(key)
                let b = Self.specifierKinds(value)
                XCTAssertNotNil(b, "\(lang): bad positional specifiers in \(value)")
                XCTAssertEqual(a, b, "\(lang): format specifiers differ\n  key: \(key)\n  value: \(value)")
            }
        }
    }

    func testItalianIsActuallyTranslated() throws {
        let en = try table("en")
        let it = try table("it")
        let same = en.keys.filter { it[$0] == $0 }.count
        // Product names, units and a few shared words stay the same; most text must differ.
        XCTAssertLessThan(Double(same) / Double(en.count), 0.2)
    }

    func testInfoPlistListsEveryLanguage() throws {
        let plist = Self.localizationDir.deletingLastPathComponent().appendingPathComponent("Info.plist")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        XCTAssertEqual(dict["CFBundleDevelopmentRegion"] as? String, "en")
        let declared = Set(try XCTUnwrap(dict["CFBundleLocalizations"] as? [String]))
        XCTAssertEqual(declared, Set(try languages()))
    }

    // MARK: L()

    private func makeBundle(table: String) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loc-test-\(UUID().uuidString)")
        let lproj = dir.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        try table.write(to: lproj.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try XCTUnwrap(Bundle(path: dir.path))
    }

    func testLookupFallsBackToTheKeyWhenTranslationIsMissing() throws {
        let bundle = try makeBundle(table: #""Hello" = "Ciao";"#)
        XCTAssertEqual(Localization.string("Hello", bundle: bundle), "Ciao")
        XCTAssertEqual(Localization.string("Not in the table", bundle: bundle), "Not in the table")
        // A bundle with no table at all behaves the same.
        XCTAssertEqual(Localization.string("Anything", bundle: Bundle(for: LocalizationTests.self)), "Anything")
    }

    func testFormatKeysSubstituteArgumentsAndFallBack() throws {
        let bundle = try makeBundle(table: #""%@ of %lld" = "%2$lld su %1$@";"#)
        XCTAssertEqual(Localization.format("%@ of %lld", ["clip", 3 as Int], bundle: bundle), "3 su clip")
        XCTAssertEqual(Localization.format("Missing %@ in %lld", ["x", 2 as Int], bundle: bundle), "Missing x in 2")
    }

    func testPlainLReturnsEnglishWhenNothingIsTranslated() {
        // The test process has no .lproj folders in Bundle.main, so L is the identity.
        XCTAssertEqual(L("Cancel"), "Cancel")
        XCTAssertEqual(L("Bitrate: %lld Mbps", 12), "Bitrate: 12 Mbps")
        XCTAssertEqual(L("%.1f%% of frames were lost or failed to decode.", 2.5), "2.5% of frames were lost or failed to decode.")
    }

    func testForceEnglishIgnoresTranslations() throws {
        let bundle = try makeBundle(table: #""Hello" = "Ciao";"#)
        XCTAssertEqual(Localization.english { Localization.string("Hello", bundle: bundle) }, "Hello")
        XCTAssertEqual(Localization.string("Hello", bundle: bundle), "Ciao")
    }

    // MARK: Script

    func testCheckScriptPasses() throws {
        let script = Self.repoRoot.appendingPathComponent("scripts/localization.py")
        guard FileManager.default.fileExists(atPath: script.path) else { throw XCTSkip("scripts/localization.py not found") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script.path, "check"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { throw XCTSkip("python3 not available: \(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: data, as: UTF8.self))
    }
}
