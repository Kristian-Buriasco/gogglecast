import Foundation

/// Pure label builders for VoiceOver (kept out of views so they can be unit-tested).
enum AccessibilityLabels {
    /// One-sentence summary of a picker row: "Nick, DJI Goggles 3, serial X, USB 2CA3:0020, bus 20 address 3".
    static func pickerRow(product: String?, serial: String?, nickname: String?, usbID: String, bus: Int, address: Int) -> String {
        var parts: [String] = []
        if let nickname, !nickname.isEmpty { parts.append(nickname) }
        parts.append(product ?? "DJI Goggles 3")
        parts.append(L("serial %@", serial ?? L("unknown")))
        parts.append(L("USB %@", usbID))
        parts.append(L("bus %lld address %lld", bus, address))
        return parts.joined(separator: ", ")
    }

    /// "60 percent" / "3 seconds": value text for sliders, with a spoken unit.
    static func quantity(_ value: Int, unit: String) -> String {
        "\(value) \(unit)"
    }

    static func onOff(_ isOn: Bool) -> String { isOn ? L("On") : L("Off") }

    /// Spoken status for a self-test row, so state isn't conveyed by icon colour alone.
    static func checkStatus(pass: Bool, fail: Bool) -> String {
        pass ? L("Passed") : fail ? L("Failed") : L("Not checked")
    }

    /// Value for a stream toggle: the error text, "Stopped", "Waiting for peer" or "Connected".
    static func streamState(isStreaming: Bool, connected: Bool, error: String?) -> String {
        if let error, !error.isEmpty { return error }
        guard isStreaming else { return L("Stopped") }
        return connected ? L("Connected") : L("Waiting for peer")
    }

    static func recordState(isRecording: Bool, elapsed: String?) -> String {
        isRecording ? L("Recording") + (elapsed.map { " \($0)" } ?? "") : L("Not recording")
    }

    /// Setup assistant row: "Step 2 of 4, Goggles on USB, done. Your goggles are connected over USB."
    static func setupStep(number: Int, of total: Int, title: String, state: SetupDiagnosis.Step.State, message: String) -> String {
        let status: String
        switch state {
        case .done: status = L("done")
        case .attention: status = L("needs attention")
        case .pending: status = L("waiting for earlier steps")
        }
        return L("Step %lld of %lld, %@, %@. %@", number, total, title, status, message)
    }

    /// OBS status line: "OBS Studio: Connected to OBS 30.2.3" or the error text.
    static func obsStatus(enabled: Bool, status: String, error: String?) -> String {
        guard enabled else { return L("OBS Studio integration is off") }
        if let error, !error.isEmpty { return "\(status). \(error)" }
        return status
    }

    /// Scene picker: "Scene when live, Gameplay" / "Scene when lost, left unchanged".
    static func obsScene(role: String, scene: String) -> String {
        let name = scene.isEmpty ? L("left unchanged") : scene
        return role == "live" ? L("Scene when live, %@", name) : L("Scene when lost, %@", name)
    }
}
