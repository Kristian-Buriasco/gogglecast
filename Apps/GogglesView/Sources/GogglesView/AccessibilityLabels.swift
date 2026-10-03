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

    static func recordState(isRecording: Bool, elapsed: String?) -> String {
        isRecording ? "Recording" + (elapsed.map { " \($0)" } ?? "") : "Not recording"
    }
}
