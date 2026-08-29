import os

// Task 4.1: mirrors the helper's and app's own `Logging.swift` split (own
// subsystem, one category for the Mach-lookup spike specifically so
// `log show`/Console.app can isolate this throwaway code's output).
enum Logging {
    static let subsystem = "com.kburiasco.gogglesview.camera"
    static let spike = Logger(subsystem: subsystem, category: "MachLookupSpike")
}
