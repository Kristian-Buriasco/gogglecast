// Task 1.3: reassembler tests (design §9.1 item 3). No golden vectors exist
// for this task (the Python prototype's reassembly logic is inline in
// stream.py's main loop, not exposed as a pure testable function), so these
// are hand-written unit tests covering every case §9.1 item 3 calls out:
// in-order fragments, out-of-order fragments, a dropped fragment (discard,
// not merge, with the drop counter incrementing), frame-number wrap
// (255 -> 0), and the specific stale-entry regression that stream.py's
// "only ever evict the current frame number" logic gets wrong.

import Testing
import Foundation
@testable import GogglesProtocol

// MARK: - Test helpers

/// Builds a video-packet payload as `FrameReassembler.process` expects it:
/// post outer-header (i.e. starting at what design §5.2 calls offset 8 of
/// the full packet -- local offset 0 here). Bytes 0..7 are the "not decoded
/// by the prototype" span and are filled with a recognizable non-zero
/// pattern to make sure the implementation truly ignores them; byte 11 is
/// similarly ignored padding.
private func makeVideoPayload(frameNum: UInt8, fragNum: UInt8, fragCount: UInt8, chunk: [UInt8]) -> Data {
    var bytes = [UInt8](repeating: 0xAA, count: 12)
    bytes[8] = frameNum
    bytes[9] = (fragCount & 0x7F) | ((fragNum & 0x01) << 7)
    bytes[10] = (fragNum >> 1) & 0x1F
    bytes[11] = 0xAA
    return Data(bytes) + Data(chunk)
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

// MARK: - mod-256 distance formula

@Test func mod256DistanceWrapsForward() {
    // design §5.2 worked example: old=250, current=3 -> distance 9
    // (250 -> 255 -> 0 -> 1 -> 2 -> 3), not |250-3| = 247.
    #expect(FrameReassembler.mod256Distance(from: 250, to: 3) == 9)
    #expect(FrameReassembler.mod256Distance(from: 5, to: 5) == 0)
    #expect(FrameReassembler.mod256Distance(from: 5, to: 6) == 1)
    #expect(FrameReassembler.mod256Distance(from: 255, to: 0) == 1)
}

// MARK: - in-order fragments

@Test func inOrderFragmentsProduceCorrectNAL() {
    let r = FrameReassembler()
    #expect(r.process(videoPayload: makeVideoPayload(frameNum: 10, fragNum: 0, fragCount: 3, chunk: [0x01, 0x02]), receivedAt: t0) == nil)
    #expect(r.process(videoPayload: makeVideoPayload(frameNum: 10, fragNum: 1, fragCount: 3, chunk: [0x03, 0x04]), receivedAt: t0) == nil)
    let result = r.process(videoPayload: makeVideoPayload(frameNum: 10, fragNum: 2, fragCount: 3, chunk: [0x05]), receivedAt: t0)
    #expect(result == Data([0x00, 0x00, 0x00, 0x01, 0x01, 0x02, 0x03, 0x04, 0x05]))
    #expect(r.droppedFrameCount == 0)
}

@Test func startCodeNotDuplicatedIfAlreadyPresent() {
    let r = FrameReassembler()
    #expect(r.process(videoPayload: makeVideoPayload(frameNum: 1, fragNum: 0, fragCount: 2, chunk: [0x00, 0x00, 0x00, 0x01, 0x67]), receivedAt: t0) == nil)
    let result = r.process(videoPayload: makeVideoPayload(frameNum: 1, fragNum: 1, fragCount: 2, chunk: [0x42]), receivedAt: t0)
    #expect(result == Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42]))
}

// MARK: - out-of-order fragments

@Test func outOfOrderFragmentsProduceSameNAL() {
    let r = FrameReassembler()
    #expect(r.process(videoPayload: makeVideoPayload(frameNum: 20, fragNum: 2, fragCount: 3, chunk: [0x05]), receivedAt: t0) == nil)
    #expect(r.process(videoPayload: makeVideoPayload(frameNum: 20, fragNum: 0, fragCount: 3, chunk: [0x01, 0x02]), receivedAt: t0) == nil)
    let result = r.process(videoPayload: makeVideoPayload(frameNum: 20, fragNum: 1, fragCount: 3, chunk: [0x03, 0x04]), receivedAt: t0)
    #expect(result == Data([0x00, 0x00, 0x00, 0x01, 0x01, 0x02, 0x03, 0x04, 0x05]))
    #expect(r.droppedFrameCount == 0)
}

// MARK: - dropped fragment: discard, not merge, drop counter increments

@Test func droppedFragmentDiscardsFrameAndCountsIt() {
    let r = FrameReassembler()

    // Frame 40 expects 3 fragments; only fragment 0 ever arrives (1 is
    // lost on the wire, 2 never sent because the sender moved on).
    #expect(r.process(videoPayload: makeVideoPayload(frameNum: 40, fragNum: 0, fragCount: 3, chunk: [0xDE, 0xAD]), receivedAt: t0) == nil)
    #expect(r.droppedFrameCount == 0)

    // Advance the frame number past the mod-256 distance threshold (5)
    // with unrelated, individually-complete single-fragment frames. Each
    // call runs eviction, so once distance from 40 exceeds 5 the stale
    // entry is evicted and discarded (not merged into anything).
    for n: UInt8 in 41...46 {
        let out = r.process(videoPayload: makeVideoPayload(frameNum: n, fragNum: 0, fragCount: 1, chunk: [n]), receivedAt: t0)
        #expect(out != nil, "single-fragment frame \(n) should complete immediately")
    }

    #expect(r.droppedFrameCount == 1, "the incomplete frame 40 should have been evicted and counted exactly once")

    // A later, unrelated frame 40 (wrapped around, or just reused) must
    // start clean -- not see the old fragment 0 bytes. Deliberately tagged
    // fragNum: 1 (not 0) so this packet does NOT resend the fragment index
    // ([0xDE, 0xAD]) the stale entry occupied -- a dictionary-key
    // overwrite at index 0 would "self-heal" a broken/no-op eviction and
    // let a naive byte-content assertion pass even without real eviction
    // (see review finding on this test). With only index 1 ever written,
    // a naive impl that fails to evict would merge into the stale
    // {0: [0xDE, 0xAD]} entry, producing fragments {0: [0xDE, 0xAD],
    // 1: [0x99]}; since count (2) >= this packet's fragCount (1) it would
    // complete immediately with the stale bytes spliced in front, which
    // the assertions below catch.
    let result = r.process(videoPayload: makeVideoPayload(frameNum: 40, fragNum: 1, fragCount: 1, chunk: [0x99]), receivedAt: t0)
    #expect(result == Data([0x00, 0x00, 0x00, 0x01, 0x99]))
    #expect(!(result?.contains(0xDE) ?? false), "reassembled NAL must not contain any byte from the stale, evicted fragment")
    #expect(!(result?.contains(0xAD) ?? false), "reassembled NAL must not contain any byte from the stale, evicted fragment")
}

// MARK: - frame-number wrap 255 -> 0

@Test func frameNumberWrapHandledCorrectly() {
    let r = FrameReassembler()
    #expect(r.process(videoPayload: makeVideoPayload(frameNum: 255, fragNum: 0, fragCount: 2, chunk: [0x01]), receivedAt: t0) == nil)
    let f255 = r.process(videoPayload: makeVideoPayload(frameNum: 255, fragNum: 1, fragCount: 2, chunk: [0x02]), receivedAt: t0)
    #expect(f255 == Data([0x00, 0x00, 0x00, 0x01, 0x01, 0x02]))

    #expect(r.process(videoPayload: makeVideoPayload(frameNum: 0, fragNum: 0, fragCount: 2, chunk: [0x03]), receivedAt: t0) == nil)
    let f0 = r.process(videoPayload: makeVideoPayload(frameNum: 0, fragNum: 1, fragCount: 2, chunk: [0x04]), receivedAt: t0)
    #expect(f0 == Data([0x00, 0x00, 0x00, 0x01, 0x03, 0x04]))

    #expect(r.droppedFrameCount == 0)
}

// MARK: - time-based eviction (same frame number, no distance signal)

@Test func staleEntryEvictedByAgeAlone() {
    // Same frame number reused with a >250ms gap: mod-256 distance is 0
    // (can't detect this), so only the wall-clock check can catch it.
    let r = FrameReassembler()
    #expect(r.process(videoPayload: makeVideoPayload(frameNum: 7, fragNum: 0, fragCount: 2, chunk: [0x11]), receivedAt: t0) == nil)

    let later = t0.addingTimeInterval(0.300) // > 250ms
    // This packet is itself frame 7's continuation attempt, but eviction
    // runs before the new fragment is folded in, so it must not merge
    // with the 300ms-old fragment 0.
    let result = r.process(videoPayload: makeVideoPayload(frameNum: 7, fragNum: 1, fragCount: 2, chunk: [0x22]), receivedAt: later)
    // Only fragment 1 is present in the fresh entry -> incomplete (needs
    // fragCount 2, has 1), so nothing emitted yet, and the stale fragment
    // 0 must have been dropped, not merged.
    #expect(result == nil)
    #expect(r.droppedFrameCount == 1)
}

// MARK: - the stale-entry regression (design §5.2's required test)
//
// This is the load-bearing test in this file. It reproduces exactly the
// scenario that corrupts data under stream.py's actual logic (frames dict
// only ever evicted for the *current* frame number) and asserts our
// age/distance-based eviction handles it correctly instead.
//
// Python trace for the same sequence of calls, to make the failure mode
// concrete:
//   1. frame_num=250 fragment 0/2 arrives. frames[250] = {0: b"OLD"}.
//   2. Frames 251..255, 0 each arrive as complete single-fragment frames.
//      flush_frame is called for *those* frame numbers only; frames[250]
//      is never touched -- current_frame_num moves on, but nothing ever
//      calls flush_frame(250) or pops frames[250].
//   3. ~256 frames later frame_num=250 comes around again with fragment
//      1/2 of a brand-new, unrelated frame. Python does:
//        frames.setdefault(250, {})[1] = b"NEW"
//      but frames[250] already exists from step 1 -- setdefault returns
//      the *existing* dict, so this merges into it:
//        frames[250] == {0: b"OLD", 1: b"NEW"}
//      got == frag_count (2) -> flush_frame(250) emits b"OLD" + b"NEW",
//      a corrupt NAL splicing two unrelated frames together.
//
// Our implementation must not do this: the stale frame-250 entry is aged
// out (mod-256 distance > 5) long before frame_num cycles back to 250, so
// the second frame-250 sequence starts from a clean entry.
@Test func staleEntryRegressionDoesNotMergeUnrelatedFrames() {
    let r = FrameReassembler()

    // Step 1: frame 250, fragment 0 of 2 arrives; fragment 1 is lost.
    let oldFragment: [UInt8] = [0x4F, 0x4C, 0x44] // "OLD"
    #expect(r.process(videoPayload: makeVideoPayload(frameNum: 250, fragNum: 0, fragCount: 2, chunk: oldFragment), receivedAt: t0) == nil)

    // Step 2: the sender moves on to subsequent frames (251..255, then
    // wraps to 0) well within 250ms, each a complete single-fragment
    // frame of its own. Naive "only evict current frame number" logic
    // (stream.py) would never touch frames[250] here.
    var t = t0
    for n: UInt8 in [251, 252, 253, 254, 255, 0] {
        t = t.addingTimeInterval(0.010)
        let out = r.process(videoPayload: makeVideoPayload(frameNum: n, fragNum: 0, fragCount: 1, chunk: [n]), receivedAt: t)
        #expect(out != nil)
    }
    // By now mod-256 distance from 250 to 0 is 6 (> 5), so the stale
    // fragment-0-only entry for frame 250 must already be evicted and
    // counted as dropped.
    #expect(r.droppedFrameCount == 1)

    // Step 3: frame number 250 comes around again (well under 256 more
    // frames later in a real stream, but the reassembler doesn't care how
    // it got here) carrying an entirely new, unrelated frame's two
    // fragments -- deliberately tagged at indices 1 and 2, NOT index 0,
    // the index the stale entry occupied.
    //
    // This is a deliberate departure from a literal fragment-index-0/1
    // frame: if the new frame instead resent index 0, the dictionary
    // write `entry.fragments[0] = chunk` would silently overwrite the
    // stale "OLD" value regardless of whether eviction ever actually ran
    // -- a broken/no-op eviction implementation would still pass a
    // byte-content assertion in that case (this was the exact gap an
    // earlier version of this test had, per review). By never writing to
    // index 0 at all, this version can only produce a result free of
    // "OLD"'s bytes if the stale entry was genuinely evicted first; a
    // naive impl that fails to evict would merge into the stale
    // {0: "OLD"} entry and produce a completed frame containing "OLD"'s
    // bytes on the very first of these two packets, which the assertions
    // below catch.
    let newFragment1: [UInt8] = [0x4E, 0x45] // "NE" (fragment index 1)
    let newFragment2: [UInt8] = [0x57]       // "W"  (fragment index 2)
    t = t.addingTimeInterval(0.010)
    #expect(r.process(videoPayload: makeVideoPayload(frameNum: 250, fragNum: 1, fragCount: 2, chunk: newFragment1), receivedAt: t) == nil)
    t = t.addingTimeInterval(0.010)
    let result = r.process(videoPayload: makeVideoPayload(frameNum: 250, fragNum: 2, fragCount: 2, chunk: newFragment2), receivedAt: t)

    // Must be exactly the new frame's two fragments concatenated (index 1
    // then index 2) -- NOT the old fragment 0 ("OLD") spliced in front of
    // anything.
    let expected = Data([0x00, 0x00, 0x00, 0x01]) + Data(newFragment1) + Data(newFragment2)
    #expect(result == expected)
    #expect(!(result?.contains(0x4F) ?? false), "reassembled NAL must not contain any byte from the stale, evicted fragment")
}
