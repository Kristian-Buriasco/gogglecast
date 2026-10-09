import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import GogglesView

private final class Collector: SampleBufferRendering {
    private let lock = NSLock()
    private(set) var keyflags: [Bool] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return keyflags.count }
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.lock(); keyflags.append(Recorder.isKeyframe(sampleBuffer)); lock.unlock()
    }
    func flush() {}
    var snapshot: [Bool] { lock.lock(); defer { lock.unlock() }; return keyflags }
}

@Suite(.serialized)
struct ReencodeHubTests {
    private func frame(format: OSType, w: Int = 640, h: Int = 360, seed: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, format, [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buf) {
            if let base = CVPixelBufferGetBaseAddressOfPlane(buf, plane) {
                let len = CVPixelBufferGetBytesPerRowOfPlane(buf, plane) * CVPixelBufferGetHeightOfPlane(buf, plane)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for i in 0..<len { p[i] = UInt8(truncatingIfNeeded: i / 64) &+ seed }
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    /// Feeds frames at ~100 fps for `seconds` and returns what a subscriber saw.
    private func run(format: OSType, seconds: Double) -> [Bool] {
        var n: UInt8 = 0
        let hub = ReencodeHub(source: { n &+= 3; return self.frame(format: format, seed: n) }, bitrateMbps: { 8 })
        let c = Collector()
        hub.subscribe(c)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { hub.pollOnce(); Thread.sleep(forTimeInterval: 0.01) }
        let wait = Date().addingTimeInterval(3)
        while c.count == 0 && Date() < wait { Thread.sleep(forTimeInterval: 0.05) }
        hub.unsubscribe(c)
        return c.snapshot
    }

    @Test func firstFrameIsAKeyframeAndKeyframesRepeat() {
        let flags = run(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, seconds: 2.6)
        #expect(flags.count > 8, "slow CI machines encode fewer frames, got \(flags.count)")
        #expect(flags.first == true)
        #expect(flags.filter { $0 }.count >= 2, "a keyframe at least every ~1 s")
        #expect(flags.filter { !$0 }.count >= 3, "most frames are predicted")
    }

    @Test func tenBitInputIsConverted() {
        let flags = run(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, seconds: 2.5)
        #expect(flags.count >= 2, "slow machines encode fewer frames, got \(flags.count)")
        #expect(flags.first == true)
    }

    @Test func halfRateEncodesEveryOtherPicture() {
        func encoded(half: Bool) -> Int {
            var seq: UInt64 = 0
            let hub = ReencodeHub(source: { self.frame(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, seed: UInt8(truncatingIfNeeded: seq)) },
                                  sequence: { seq }, bitrateMbps: { 8 }, halfRate: { half })
            let c = Collector()
            hub.subscribe(c)
            for _ in 0..<40 { seq += 1; hub.pollOnce(); Thread.sleep(forTimeInterval: 0.005) }
            let wait = Date().addingTimeInterval(3)
            while c.count == 0 && Date() < wait { Thread.sleep(forTimeInterval: 0.05) }
            Thread.sleep(forTimeInterval: 0.3)
            hub.unsubscribe(c)
            return hub.framesEncoded
        }
        let full = encoded(half: false), half = encoded(half: true)
        #expect(half >= 15 && half <= 25, "half rate encoded \(half) of 40")
        #expect(full > half, "full rate encoded \(full), half \(half)")
    }

    @Test func halfRatePrefDefaultsOff() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: ReencodePrefs.halfRateKey)
        defer { if let saved { d.set(saved, forKey: ReencodePrefs.halfRateKey) } else { d.removeObject(forKey: ReencodePrefs.halfRateKey) } }
        d.removeObject(forKey: ReencodePrefs.halfRateKey)
        #expect(!ReencodePrefs.halfRate)
        d.set(true, forKey: ReencodePrefs.halfRateKey)
        #expect(ReencodePrefs.halfRate)
    }

    @Test func stopsEncodingWhenLastSubscriberLeaves() {
        let hub = ReencodeHub(source: { self.frame(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, seed: 1) })
        let c = Collector()
        hub.subscribe(c)
        #expect(hub.subscriberCount == 1)
        hub.unsubscribe(c)
        #expect(hub.subscriberCount == 0)
    }

    @Test func prefsDefaultOnWithClampedBitrate() {
        let d = UserDefaults.standard
        let saved = (d.object(forKey: ReencodePrefs.enabledKey), d.object(forKey: ReencodePrefs.bitrateKey))
        defer { d.set(saved.0, forKey: ReencodePrefs.enabledKey); d.set(saved.1, forKey: ReencodePrefs.bitrateKey) }
        d.removeObject(forKey: ReencodePrefs.enabledKey)
        #expect(ReencodePrefs.enabled)
        d.set(500, forKey: ReencodePrefs.bitrateKey)
        #expect(ReencodePrefs.bitrateMbps == 60)
        d.set(1, forKey: ReencodePrefs.bitrateKey)
        #expect(ReencodePrefs.bitrateMbps == 4)
    }
}
