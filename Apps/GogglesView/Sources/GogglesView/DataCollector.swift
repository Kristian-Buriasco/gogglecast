import Foundation
import SwiftUI
import Combine

/// Quick research logger: while on, writes one JSON line per video frame with
/// the proprietary SEI (type 240) payload, plus battery changes and user markers.
final class DataCollector: ObservableObject {
    @Published private(set) var isCollecting = false
    @Published private(set) var frames = 0
    @Published private(set) var lastMarker: String?

    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "datacollector")
    private(set) var fileURL: URL?
    private var start: UInt64 = 0

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/GogglesView-data", isDirectory: true)
    }

    /// Extracts SEI payload-type-240 bodies from an Annex-B access unit.
    static func seiPayloads(in data: Data) -> [Data] {
        var out: [Data] = []
        let b = [UInt8](data)
        var i = 0
        while i + 4 < b.count {
            let sc3 = b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1
            let sc4 = i + 4 < b.count && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 0 && b[i + 3] == 1
            guard sc3 || sc4 else { i += 1; continue }
            var j = i + (sc4 ? 4 : 3)
            if j < b.count, b[j] & 0x1F == 6 {
                j += 1
                var t = 0
                while j < b.count, b[j] == 255 { t += 255; j += 1 }
                if j < b.count { t += Int(b[j]); j += 1 }
                var s = 0
                while j < b.count, b[j] == 255 { s += 255; j += 1 }
                if j < b.count { s += Int(b[j]); j += 1 }
                if t == 240, j + s <= b.count { out.append(Data(b[j..<(j + s)])) }
            }
            i = j
        }
        return out
    }

    func startCollecting() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let url = Self.directory.appendingPathComponent("collect-\(f.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        fileURL = url
        start = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { self.frames = 0; self.lastMarker = nil; self.isCollecting = true }
    }

    func stopCollecting() {
        queue.sync { try? handle?.close(); handle = nil }
        DispatchQueue.main.async { self.isCollecting = false }
    }

    private func write(_ obj: [String: Any]) {
        queue.async { [weak self] in
            guard let self, let h = self.handle,
                  let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
            h.write(d); h.write(Data([0x0A]))
        }
    }

    private func t(_ ns: UInt64) -> Double { Double(ns &- start) / 1e9 }

    func logNAL(_ data: Data, hostTime: UInt64) {
        guard isCollecting else { return }
        let sei = Self.seiPayloads(in: data)
        write(["k": "frame", "t": t(hostTime), "bytes": data.count, "sei": sei.map { $0.map { String(format: "%02x", $0) }.joined() }])
        DispatchQueue.main.async { self.frames += 1 }
    }

    func logBattery(_ percent: Int?) {
        guard isCollecting else { return }
        write(["k": "battery", "t": t(DispatchTime.now().uptimeNanoseconds), "percent": percent as Any? ?? NSNull()])
    }

    func mark(_ label: String) {
        guard isCollecting else { return }
        write(["k": "marker", "t": t(DispatchTime.now().uptimeNanoseconds), "label": label])
        DispatchQueue.main.async { self.lastMarker = label }
    }
}

struct DataCollectControl: View {
    @ObservedObject var session: DecodeSession
    var batteryPercent: Int?
    @StateObject private var collector = DataCollector()
    private let markers = ["still", "gimbal up", "gimbal down", "exposure change", "pan left", "pan right", "other"]

    var body: some View {
        HStack(spacing: 6) {
            if collector.isCollecting {
                Menu {
                    ForEach(markers, id: \.self) { m in Button(m) { collector.mark(m) } }
                } label: {
                    Image(systemName: "flag").foregroundStyle(Color.orange)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Drop a marker in the data log")
                Text("\(collector.frames)").font(.caption.monospacedDigit()).foregroundStyle(.orange)
                if let m = collector.lastMarker { Text(m).font(.caption2).foregroundStyle(.secondary) }
            }
            Button {
                if collector.isCollecting {
                    collector.stopCollecting(); session.onRawNAL = nil
                    if let url = collector.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } else {
                    collector.startCollecting()
                    session.onRawNAL = { [weak collector] data, _, isParam, host in
                        if !isParam { collector?.logNAL(data, hostTime: host) }
                    }
                    collector.logBattery(batteryPercent)
                }
            } label: {
                Image(systemName: collector.isCollecting ? "waveform.circle.fill" : "waveform.circle")
                    .foregroundStyle(collector.isCollecting ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(collector.isCollecting ? "Stop collecting and show the log" : "Collect research data (frame metadata, markers) to ~/Documents/GogglesView-data")
        }
        .onChange(of: batteryPercent) { p in collector.logBattery(p) }
    }
}
