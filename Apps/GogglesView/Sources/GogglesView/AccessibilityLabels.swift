import Foundation

/// Pure label builders for VoiceOver (kept out of views so they can be unit-tested).
enum AccessibilityLabels {
    /// One-sentence summary of a picker row: "Nick, DJI Goggles 3, serial X, USB 2CA3:0020, bus 20 address 3".
    static func pickerRow(product: String?, serial: String?, nickname: String?, usbID: String, bus: Int, address: Int) -> String {
        var parts: [String] = []
        if let nickname, !nickname.isEmpty { parts.append(nickname) }
        parts.append(product ?? "DJI Goggles 3")
        parts.append("serial \(serial ?? "unknown")")
        parts.append("USB \(usbID)")
        parts.append("bus \(bus) address \(address)")
        return parts.joined(separator: ", ")
    }

    /// "60 percent" / "3 seconds": value text for sliders, with a spoken unit.
    static func quantity(_ value: Int, unit: String) -> String {
        "\(value) \(unit)"
    }

    static func onOff(_ isOn: Bool) -> String { isOn ? "On" : "Off" }

    /// Spoken status for a self-test row, so state isn't conveyed by icon colour alone.
    static func checkStatus(pass: Bool, fail: Bool) -> String {
        pass ? "Passed" : fail ? "Failed" : "Not checked"
    }

    /// Value for a stream toggle: the error text, "Stopped", "Waiting for peer" or "Connected".
    static func streamState(isStreaming: Bool, connected: Bool, error: String?) -> String {
        if let error, !error.isEmpty { return error }
        guard isStreaming else { return "Stopped" }
        return connected ? "Connected" : "Waiting for peer"
    }

    static func recordState(isRecording: Bool, elapsed: String?) -> String {
        isRecording ? "Recording" + (elapsed.map { " \($0)" } ?? "") : "Not recording"
    }
}
