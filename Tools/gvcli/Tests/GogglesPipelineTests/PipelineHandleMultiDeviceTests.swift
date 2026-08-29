// Multi-device picker design item 3: regression tests for the
// process-wide-globals bug fix. `currentTransport`/`currentSink` used to be
// plain module-level `var`s any concurrently-running `runPipeline` call
// shared -- harmless with exactly one call ever in flight (the pre-
// multi-device reality), a real bug the instant two devices' pipelines run
// concurrently (device A unplugging could read/act on device B's
// transport, since both wrote through the same two globals). These tests
// run two `runPipeline` invocations concurrently against two independent
// fake transports (no real hardware/MockTransport .gvcap fixture needed --
// this is exercising `PipelineHandle` isolation, not frame parsing) and
// confirm each has its own private view of its own transport, matching the
// design's own "mock-tested, not hardware-tested" verification story for
// multi-claim (only one physical Goggles 3 unit was available this
// session).

import Testing
import Foundation
import GogglesProtocol
@testable import GogglesPipeline

/// Minimal `GogglesTransport` conformer for these tests: no `.gvcap`
/// parsing, no Ethernet/RNDIS framing -- just a controllable `inbound`
/// stream and a `send` recorder, which is all `runPipeline`'s
/// handle-isolation behavior needs to be exercised deterministically.
private final class FakeTransport: GogglesTransport {
    let inbound: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private(set) var sentFrames: [Data] = []

    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream<Data> { cont = $0 }
        self.continuation = cont
    }

    func send(_ frame: Data) throws {
        sentFrames.append(frame)
    }

    /// Simulates the transport going away (e.g. a real unplug ending
    /// `RNDISTransport.inbound`) -- ends `runPipeline`'s inbound-consumer
    /// loop for exactly this transport, without touching any other.
    func finish() {
        continuation.finish()
    }
}

// `.serialized`: `releaseAllActivePipelines()` is deliberately process-wide
// (it's the SIGINT/SIGTERM process-exit cleanup path -- see Pipeline.swift's
// doc comment), so if Swift Testing ran these two tests' pipelines
// concurrently (its default), one test's `releaseAllActivePipelines()` call
// would release the *other* test's still-active handles too -- a test-
// isolation artifact of that intentionally-global side effect, not a
// product bug. Serializing this suite avoids that cross-test interference.
@Suite("PipelineHandle multi-device isolation", .serialized)
struct PipelineHandleMultiDeviceTests {

    @Test("two concurrent pipelines never see each other's transport through their handles")
    func handlesAreIsolatedAcrossConcurrentDevices() async throws {
        let transportA = FakeTransport()
        let transportB = FakeTransport()
        let handleA = PipelineHandle()
        let handleB = PipelineHandle()

        let taskA = Task { try? await runPipeline(transport: transportA, sink: nil, stats: false, handle: handleA) }
        let taskB = Task { try? await runPipeline(transport: transportB, sink: nil, stats: false, handle: handleB) }

        // Both pipelines' first statement (handle.transport = transport)
        // runs before either ever suspends on transport.inbound -- give the
        // scheduler a moment to actually run that far.
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect((handleA.transport as? FakeTransport) === transportA)
        #expect((handleB.transport as? FakeTransport) === transportB)

        // The exact regression scenario the old shared globals were
        // vulnerable to: device A ("transportA") disconnects. Only
        // handleA may observe that; handleB (device B) must be completely
        // unaffected -- this is what the old currentTransport/currentSink
        // globals could NOT have guaranteed, since both pipelines wrote
        // through the same two variables.
        transportA.finish()
        _ = await taskA.value

        #expect(handleA.transport == nil)
        #expect((handleB.transport as? FakeTransport) === transportB, "device B's handle must survive device A's disconnect untouched")

        transportB.finish()
        _ = await taskB.value
        #expect(handleB.transport == nil)
    }

    @Test("releaseAllActivePipelines releases every currently-active handle, not just one")
    func releaseAllActivePipelinesReleasesEveryHandle() async throws {
        let transportA = FakeTransport()
        let transportB = FakeTransport()
        let handleA = PipelineHandle()
        let handleB = PipelineHandle()

        let taskA = Task { try? await runPipeline(transport: transportA, sink: nil, stats: false, handle: handleA) }
        let taskB = Task { try? await runPipeline(transport: transportB, sink: nil, stats: false, handle: handleB) }
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(handleA.transport != nil)
        #expect(handleB.transport != nil)

        // Mirrors what gvcli's SIGINT handler / GogglesHelper's SIGTERM
        // handler now do on process exit (Pipeline.swift/
        // SignalHandling.swift) -- process-wide cleanup is legitimate here
        // (every claimed device really should be released before the
        // process dies), unlike the old bug, which was globals being read
        // for *control-flow* decisions, not process-exit cleanup.
        releaseAllActivePipelines()

        #expect(handleA.transport == nil)
        #expect(handleB.transport == nil)

        // Let both pipeline Tasks actually finish so nothing leaks past
        // this test.
        transportA.finish()
        transportB.finish()
        _ = await taskA.value
        _ = await taskB.value
    }
}
