import Foundation

/// Optional third-party runtime libraries (libsrt, NDI). They are never bundled
/// or linked: we `dlopen` them only if the user installed them, which avoids
/// redistribution licensing and notarization issues. A hardened-runtime build
/// needs the `com.apple.security.cs.disable-library-validation` entitlement to
/// load a library signed by a different team.
enum OutputLibrary {
    /// Candidate paths in priority order: user-chosen path (file, or directory
    /// containing `fileName`), then the defaults.
    static func candidates(userPath: String?, fileName: String, defaults: [String]) -> [String] {
        var out: [String] = []
        if let p = userPath?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
            let expanded = (p as NSString).expandingTildeInPath
            out.append(expanded.hasSuffix(".dylib") ? expanded : (expanded as NSString).appendingPathComponent(fileName))
        }
        out += defaults
        return out
    }

    static func resolve(userPath: String?, fileName: String, defaults: [String],
                        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        candidates(userPath: userPath, fileName: fileName, defaults: defaults).first(where: exists)
    }

    static let srtDefaults = ["/opt/homebrew/lib/libsrt.dylib", "/usr/local/lib/libsrt.dylib"]

    /// NDI SDK / runtime locations; `appDirs` are the NDI* entries found in /Applications.
    static func ndiDefaults(appDirs: [String]) -> [String] {
        var d = ["/Library/NDI SDK for Apple/lib/macOS/libndi.dylib", "/usr/local/lib/libndi.dylib"]
        for a in appDirs {
            d.append("/Applications/\(a)/libndi.dylib")
            d.append("/Applications/\(a)/Contents/Frameworks/libndi.dylib")
        }
        return d
    }

    static func ndiAppDirs() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? [])
            .filter { $0.hasPrefix("NDI") }.sorted()
    }

    static func resolveSRT(userPath: String? = SRTPrefs.libraryPath,
                           exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        resolve(userPath: userPath, fileName: "libsrt.dylib", defaults: srtDefaults, exists: exists)
    }

    static func resolveNDI(userPath: String? = NDIPrefs.libraryPath, appDirs: [String]? = nil,
                           exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        resolve(userPath: userPath, fileName: "libndi.dylib",
                defaults: ndiDefaults(appDirs: appDirs ?? ndiAppDirs()), exists: exists)
    }

    /// dlopen + symbol lookup. Returns nil if the library or any symbol is missing.
    static func open(_ path: String, symbols: [String]) -> (handle: UnsafeMutableRawPointer, fns: [String: UnsafeMutableRawPointer])? {
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        var fns: [String: UnsafeMutableRawPointer] = [:]
        for s in symbols {
            guard let f = dlsym(h, s) else { dlclose(h); return nil }
            fns[s] = f
        }
        return (h, fns)
    }

    /// Strips a secret from text before it is shown or logged.
    static func redact(_ text: String, secret: String) -> String {
        secret.isEmpty ? text : text.replacingOccurrences(of: secret, with: "•••")
    }
}
