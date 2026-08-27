import Foundation

/// Shared loader for `Fixtures/golden.json`, the Python-vs-Swift wire-
/// protocol parity vectors (see `Tools/gen_golden.py`'s docstring for the
/// exact schema). Used by this task's framing-primitive tests and reusable
/// as-is by later tasks (e.g. 1.2's buildOuter/handshake/ack/DUML vectors).
enum GoldenVectors {

    struct Vector {
        let name: String
        let description: String
        let inputs: [String: Any]
        let output: Any?
    }

    /// Locates `Fixtures/golden.json` relative to this source file's own
    /// location (not an absolute path baked in for one developer's home
    /// directory), so it works from any checkout location.
    ///
    /// This file lives at
    /// `Packages/GogglesProtocol/Tests/GogglesProtocolTests/GoldenVectors.swift`;
    /// walking up 5 directories from the file reaches the repo root, where
    /// `Fixtures/golden.json` lives.
    static func goldenJSONURL(callerFilePath: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: callerFilePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("Fixtures/golden.json")
    }

    private static var cache: [String: Vector]?

    /// Loads and parses all vectors from golden.json, keyed by vector name.
    /// Cached after first load since many tests hit this.
    static func all() throws -> [String: Vector] {
        if let cache { return cache }
        let url = goldenJSONURL()
        let data = try Data(contentsOf: url)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GoldenVectorError.malformedJSON
        }
        var byName: [String: Vector] = [:]
        for entry in raw {
            guard let name = entry["name"] as? String,
                  let description = entry["description"] as? String,
                  let inputs = entry["inputs"] as? [String: Any]
            else {
                throw GoldenVectorError.malformedEntry
            }
            // `output` may legitimately be JSON null (Python None), so use
            // the raw Any? rather than requiring a non-optional cast.
            let output = entry["output"]
            byName[name] = Vector(name: name, description: description, inputs: inputs, output: output)
        }
        cache = byName
        return byName
    }

    /// Fetches a single vector by name, failing loudly (not returning nil)
    /// if it's missing -- a missing vector in this task's fixed list is a
    /// test-setup bug, not a runtime possibility to handle gracefully.
    static func vector(_ name: String) throws -> Vector {
        guard let v = try all()[name] else {
            throw GoldenVectorError.vectorNotFound(name)
        }
        return v
    }

    enum GoldenVectorError: Error, CustomStringConvertible {
        case malformedJSON
        case malformedEntry
        case vectorNotFound(String)

        var description: String {
            switch self {
            case .malformedJSON: return "golden.json is not a JSON array of objects"
            case .malformedEntry: return "a golden.json entry is missing name/description/inputs"
            case .vectorNotFound(let name): return "no golden vector named \(name)"
            }
        }
    }
}

// MARK: - Field-decoding helpers

extension GoldenVectors.Vector {
    /// Decodes a hex-string input/output field (per golden.json's
    /// convention: lowercase hex, no spaces/prefix, "" for empty bytes)
    /// into `Data`.
    static func dataFromHex(_ hex: String) -> Data {
        var data = Data()
        let chars = Array(hex)
        precondition(chars.count % 2 == 0, "odd-length hex string: \(hex)")
        var i = 0
        while i < chars.count {
            let byteStr = String(chars[i]) + String(chars[i + 1])
            guard let byte = UInt8(byteStr, radix: 16) else {
                preconditionFailure("invalid hex byte \(byteStr) in \(hex)")
            }
            data.append(byte)
            i += 2
        }
        return data
    }

    func hexInput(_ key: String) -> Data {
        guard let s = inputs[key] as? String else {
            preconditionFailure("missing/non-string hex input '\(key)' in vector \(name)")
        }
        return Self.dataFromHex(s)
    }

    func stringInput(_ key: String) -> String {
        guard let s = inputs[key] as? String else {
            preconditionFailure("missing/non-string input '\(key)' in vector \(name)")
        }
        return s
    }

    func intInput(_ key: String) -> Int {
        guard let n = inputs[key] as? NSNumber else {
            preconditionFailure("missing/non-numeric input '\(key)' in vector \(name)")
        }
        return n.intValue
    }

    var outputHex: String? {
        output as? String
    }

    var outputData: Data? {
        guard let s = outputHex else { return nil }
        return Self.dataFromHex(s)
    }

    var outputInt: Int? {
        (output as? NSNumber)?.intValue
    }

    var outputObject: [String: Any]? {
        output as? [String: Any]
    }

    var outputArray: [Any]? {
        output as? [Any]
    }

    var outputIsNull: Bool {
        output == nil || output is NSNull
    }
}
