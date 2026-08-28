import os

// ─────────────────────────────────────────────────────────────────────────
// Task 3.1: mirrors `Helper/GogglesHelper/Sources/GogglesHelper/Logging.swift`'s
// subsystem/category split, one level down (the app's own subsystem, not
// the helper's -- `log show`/Console.app should be able to tell
// "HelperClient's view of the connection" apart from "the helper's own
// view" even though they're describing the same XPC conversation from
// opposite ends).
// ─────────────────────────────────────────────────────────────────────────
enum Logging {
    static let subsystem = "com.kburiasco.gogglesview.app"

    /// Connection lifecycle: connect/resume, interruption, invalidation,
    /// reconnection scheduling, protocol-version check result.
    static let xpc = Logger(subsystem: subsystem, category: "XPC")
    /// `deviceChanged`/`stateChanged`/`stats` callback fan-out as received
    /// by this client.
    static let client = Logger(subsystem: subsystem, category: "Client")
    /// The client-side, NAL-callback-driven fps counter (Task 3.1 exit
    /// criterion: "app receives NAL callbacks and logs fps matching
    /// gvcli").
    static let stats = Logger(subsystem: subsystem, category: "Stats")
}
