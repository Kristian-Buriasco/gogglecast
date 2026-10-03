import Testing
import Foundation
@testable import GogglesView

@Suite("Optional output libraries")
struct OutputLibrariesTests {
    @Test("SRT resolution order: user file, user dir, then defaults")
    func srtOrder() {
        let all: (String) -> Bool = { _ in true }
        #expect(OutputLibrary.resolveSRT(userPath: "/x/libsrt.dylib", exists: all) == "/x/libsrt.dylib")
        #expect(OutputLibrary.resolveSRT(userPath: "/x/lib", exists: all) == "/x/lib/libsrt.dylib")
        #expect(OutputLibrary.resolveSRT(userPath: "", exists: all) == "/opt/homebrew/lib/libsrt.dylib")
        #expect(OutputLibrary.resolveSRT(userPath: nil, exists: { $0 == "/usr/local/lib/libsrt.dylib" }) == "/usr/local/lib/libsrt.dylib")
        #expect(OutputLibrary.resolveSRT(userPath: nil, exists: { _ in false }) == nil)
    }

    @Test("NDI candidates include SDK, /usr/local and /Applications/NDI*")
    func ndiOrder() {
        let c = OutputLibrary.candidates(userPath: "~/n.dylib", fileName: "libndi.dylib",
                                         defaults: OutputLibrary.ndiDefaults(appDirs: ["NDI Tools"]))
        #expect(c[0].hasSuffix("/n.dylib") && !c[0].hasPrefix("~"))
        #expect(c[1] == "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib")
        #expect(c.contains("/Applications/NDI Tools/Contents/Frameworks/libndi.dylib"))
        #expect(OutputLibrary.resolveNDI(userPath: nil, appDirs: [], exists: { _ in false }) == nil)
    }

    @Test("SRT pref clamping and validation")
    func srtClamp() {
        #expect(SRTPrefs.clampPort(0) == 9000 && SRTPrefs.clampPort(70000) == 9000 && SRTPrefs.clampPort(4000) == 4000)
        #expect(SRTPrefs.clampLatency(nil) == 120 && SRTPrefs.clampLatency(1) == 20 && SRTPrefs.clampLatency(99999) == 8000)
        #expect(SRTPrefs.clampHost("  ") == "127.0.0.1" && SRTPrefs.clampHost(" a.b ") == "a.b")
        #expect(SRTPrefs.passphraseValid("") && !SRTPrefs.passphraseValid("short") && SRTPrefs.passphraseValid("0123456789"))
        #expect(!SRTPrefs.passphraseValid(String(repeating: "a", count: 80)))
        #expect(NDIPrefs.clampName(" ") == "GogglesView" && NDIPrefs.clampName("Cam") == "Cam")
    }

    @Test("Receiver hints and redaction")
    func hints() {
        #expect(SRTPrefs.receiverHint(mode: .caller, port: 9000, hasPassphrase: false).contains("srt://:9000?mode=listener"))
        let l = SRTPrefs.receiverHint(mode: .listener, port: 9001, hasPassphrase: true)
        #expect(l.contains("srt://<this-mac-ip>:9001?mode=caller") && l.contains("passphrase="))
        #expect(OutputLibrary.redact("bad key hunter2hunter2", secret: "hunter2hunter2") == "bad key •••")
        #expect(SRTOutput.messageSize == 1316)
    }

    @Test("NDI struct sizes match expected C layout (tripwire, not proof)")
    func ndiLayout() {
        #expect(MemoryLayout<NDIABI.SendCreate>.stride == NDIABI.expectedSendCreateSize)
        #expect(MemoryLayout<NDIABI.VideoFrameV2>.stride == NDIABI.expectedVideoFrameSize)
    }
}
