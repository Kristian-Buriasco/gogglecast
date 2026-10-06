import Foundation
import AppKit
import CryptoKit
import Security
import SwiftUI

/// The DMG attached to a GitHub release, plus its published SHA-256 when the API provides one.
struct UpdateAsset: Equatable {
    let name: String
    let url: URL
    let sha256: String?

    static let allowedPrefix = "https://github.com/Kristian-Buriasco/gogglecast/releases/download/"

    /// Pure: pick the `.dmg` asset from a GitHub release JSON. Rejects any URL outside this repo's release downloads.
    static func from(releaseJSON data: Data) -> UpdateAsset? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        for a in assets {
            guard let name = a["name"] as? String, name.hasSuffix(".dmg"),
                  let s = a["browser_download_url"] as? String, s.hasPrefix(allowedPrefix),
                  let url = URL(string: s) else { continue }
            var digest: String?
            if let d = a["digest"] as? String, d.hasPrefix("sha256:") { digest = String(d.dropFirst(7)).lowercased() }
            return UpdateAsset(name: name, url: url, sha256: digest)
        }
        return nil
    }
}

enum UpdateInstallScript {
    /// Single-quote for /bin/sh.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Waits for `pid` to exit, swaps the bundle, re-verifies the code signature of the copy at the
    /// destination and rolls back to the old bundle if the copy or that check fails, then removes the
    /// staging directory and itself and optionally relaunches. It never touches quarantine attributes:
    /// Gatekeeper approval is never granted implicitly.
    static func make(pid: Int32, staged: String, dest: String, relaunch: Bool, cleanup: String? = nil) -> String {
        let cleanupCmd = cleanup.map { "rm -rf \(quote($0))" } ?? ":"
        let open = relaunch ? "/usr/bin/open \"$DEST\"" : ""
        return """
        #!/bin/sh
        STAGED=\(quote(staged))
        DEST=\(quote(dest))
        cleanup() {
          \(cleanupCmd)
          rm -f "$0"
        }
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        OLD="$DEST.old"
        rm -rf "$OLD"
        mv "$DEST" "$OLD" || { cleanup; exit 1; }
        if /usr/bin/ditto "$STAGED" "$DEST" && /usr/bin/codesign --verify --strict --deep "$DEST" 2>/dev/null; then
          rm -rf "$OLD" "$STAGED"
        else
          rm -rf "$DEST"; mv "$OLD" "$DEST"
        fi
        cleanup
        \(open)
        """
    }
}

enum UpdatePrefs2 {
    static let autoInstallKey = "updateAutoInstall"
    static let helperChangedKey = "updateHelperChanged"
}

/// What the staged update must be signed by, derived from the running app.
enum SignaturePin {
    /// Pin to this code requirement (text form), taken from the running app.
    case requirement(String)
    /// Running app is ad-hoc signed or unsigned: nothing to pin to, so no automatic install.
    case none
    /// Tests only: check integrity but not authenticity.
    case integrityOnlyForTests
}

enum UpdateSignature {
    /// `anchor apple generic and certificate leaf[subject.OU] = "<TEAM>"`; nil if `team` is not a plain team id.
    static func teamRequirement(_ team: String) -> String? {
        guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func signingInfo(_ code: SecStaticCode) -> [String: Any]? {
        var dict: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dict) == errSecSuccess else { return nil }
        return dict as? [String: Any]
    }

    /// True when the code at `url` is ad-hoc signed (or has no usable signature at all).
    static func isAdHocOrUnsigned(_ url: URL) -> Bool {
        guard let code = staticCode(url), let info = signingInfo(code) else { return true }
        let flags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return true }
        return info[kSecCodeInfoIdentifier as String] == nil
    }

    /// The running app's designated requirement when it is signed with a real identity; otherwise
    /// the team-id requirement; otherwise `.none`.
    static func pin(forRunningApp url: URL) -> SignaturePin {
        guard !isAdHocOrUnsigned(url), let code = staticCode(url) else { return .none }
        var req: SecRequirement?
        var text: CFString?
        if SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess, let req,
           SecRequirementCopyString(req, [], &text) == errSecSuccess, let text {
            return .requirement(text as String)
        }
        if let team = signingInfo(code)?[kSecCodeInfoTeamIdentifier as String] as? String,
           let r = teamRequirement(team) { return .requirement(r) }
        return .none
    }

    /// Strict validity check of `url` against `requirement` (all architectures, nested code).
    /// `requirement == nil` checks validity only.
    static func satisfies(_ url: URL, requirement: String?) -> Bool {
        guard let code = staticCode(url) else { return false }
        var req: SecRequirement?
        if let requirement {
            guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, req != nil else { return false }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidityWithErrors(code, flags, req, nil) == errSecSuccess
    }

    static func identifier(_ url: URL) -> String? {
        staticCode(url).flatMap(signingInfo)?[kSecCodeInfoIdentifier as String] as? String
    }
}

final class UpdateInstaller: ObservableObject {
    static let shared = UpdateInstaller()

    enum State: Equatable {
        case idle
        case downloading
        case staged(version: String)
        case failed(String)
        /// Automatic install isn't possible (e.g. ad-hoc signed build); the releases page was opened.
        case manual(String)
    }

    @Published private(set) var state: State = .idle
    /// Why the last Install & Restart was refused (recording or streaming in progress).
    @Published private(set) var blockedReason: String?
    private var stagedApp: URL?
    private var stagedVersion = ""
    private var scriptSpawned = false
    private var terminateObserver: NSObjectProtocol?

    /// Injection points for tests.
    var isBusyProbe: () -> Bool = { SessionControlBoard.shared.anyActiveOutput }
    var terminateApp: () -> Void = { NSApp.terminate(nil) }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var pinProvider: () -> SignaturePin = { UpdateSignature.pin(forRunningApp: Bundle.main.bundleURL) }

    var bundleURL: URL { Bundle.main.bundleURL }

    /// True while anything is being recorded or sent (recorder, UDP, RTMP, SRT, NDI, web viewer, replay save).
    func isRecordingNow() -> Bool { isBusyProbe() }

    /// Download, verify and stage `asset`. Does not touch the installed app.
    func stage(asset: UpdateAsset, version: String) {
        guard state != .downloading else { return }
        let pin = pinProvider()
        if case .none = pin {
            state = .manual("This build isn't signed with a developer identity, so it can't verify an update's authenticity. Opened the releases page; download and install it manually.")
            openURL(UpdatePrefs.releasesPage)
            return
        }
        guard let want = asset.sha256, !want.isEmpty else {
            state = .failed("The release publishes no checksum, so the update can't be verified. Download it manually from the releases page."); return
        }
        guard FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            state = .failed("GogglesView's folder isn't writable. Download the release manually."); return
        }
        state = .downloading
        Task.detached { [self] in
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: asset.url)
                defer { try? FileManager.default.removeItem(at: tmp) }
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed") }
                let app = try Self.extractApp(dmg: tmp, expectedVersion: version, pin: pin, expectedSHA256: want)
                await MainActor.run { self.markStaged(app: app, version: version, arm: true) }
            } catch {
                await MainActor.run { self.state = .failed((error as? UpdateError)?.message ?? error.localizedDescription) }
            }
        }
    }

    func markStaged(app: URL, version: String, arm: Bool) {
        stagedApp = app; stagedVersion = version
        state = .staged(version: version)
        if arm { armInstallOnQuit() }
    }

    /// Install and relaunch now. Refuses while anything is being recorded or sent.
    func installAndRestart() {
        guard case .staged = state else { return }
        if isRecordingNow() {
            blockedReason = "Not installing while recording or streaming. Stop it first."
            return
        }
        blockedReason = nil
        spawnScript(relaunch: true)
        if scriptSpawned { terminateApp() }
    }

    /// Staged updates are applied on the next normal quit (no relaunch).
    private func armInstallOnQuit() {
        guard terminateObserver == nil else { return }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.spawnScript(relaunch: false)
        }
    }

    private func spawnScript(relaunch: Bool) {
        guard !scriptSpawned, let staged = stagedApp else { return }
        scriptSpawned = true
        if Self.helperBinaryDiffers(old: bundleURL, new: staged) {
            UserDefaults.standard.set(stagedVersion, forKey: UpdatePrefs2.helperChangedKey)
        }
        let work = staged.deletingLastPathComponent().deletingLastPathComponent()
        let script = UpdateInstallScript.make(pid: ProcessInfo.processInfo.processIdentifier,
                                              staged: staged.path, dest: bundleURL.path, relaunch: relaunch,
                                              cleanup: work.path)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("gogglesview-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: path, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [path.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run()
        } catch {
            scriptSpawned = false
            try? FileManager.default.removeItem(at: path)
            state = .failed("Couldn't start the installer: \(error.localizedDescription)")
        }
    }

    // MARK: staging helpers

    struct UpdateError: Error { let message: String; init(_ m: String) { message = m } }

    private static func run(_ exe: String, _ args: [String]) throws -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit(); return p.terminationStatus
    }

    static func sha256Hex(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copies `dmg`, hashes that exact copy against `expectedSHA256`, mounts the copy, extracts the app
    /// and verifies it against `pin`. On success only `<work>/out/GogglesView.app` remains (mount point
    /// and DMG copy are removed); on any failure the whole work directory is removed.
    static func extractApp(dmg: URL, expectedVersion: String, pin: SignaturePin, expectedSHA256: String,
                           current: URL? = Bundle.main.bundleURL) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("gogglesview-update-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mnt"), out = work.appendingPathComponent("out")
        let dmgCopy = work.appendingPathComponent("u.dmg")
        var mounted = false
        var succeeded = false
        defer {
            if mounted { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
            if succeeded {
                try? fm.removeItem(at: mount)
                try? fm.removeItem(at: dmgCopy)
            } else {
                try? fm.removeItem(at: work)
            }
        }
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        try fm.copyItem(at: dmg, to: dmgCopy)
        // Hash exactly what will be mounted, not the download's temp file.
        guard try sha256Hex(of: dmgCopy) == expectedSHA256.lowercased() else {
            throw UpdateError("Checksum mismatch; update discarded")
        }
        guard try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, dmgCopy.path]) == 0 else {
            throw UpdateError("Couldn't open the update disk image")
        }
        mounted = true
        let src = mount.appendingPathComponent("GogglesView.app")
        guard fm.fileExists(atPath: src.path) else { throw UpdateError("Update does not contain GogglesView.app") }
        let dst = out.appendingPathComponent("GogglesView.app")
        guard try run("/usr/bin/ditto", [src.path, dst.path]) == 0 else { throw UpdateError("Couldn't copy the update") }
        try verify(staged: dst, current: current, pin: pin, expectedVersion: expectedVersion)
        succeeded = true
        return dst
    }

    /// The staged app must satisfy the pinned requirement (so it is signed by the same identity as the
    /// running app, not merely validly signed), have the same bundle id, and be the expected newer version.
    static func verify(staged: URL, current: URL?, pin: SignaturePin, expectedVersion: String) throws {
        switch pin {
        case .none:
            throw UpdateError("This build can't verify update authenticity")
        case .requirement(let r):
            guard UpdateSignature.satisfies(staged, requirement: r) else {
                throw UpdateError("Update isn't signed by the same identity as this app")
            }
        case .integrityOnlyForTests:
            guard UpdateSignature.satisfies(staged, requirement: nil) else {
                throw UpdateError("Update's code signature is invalid")
            }
        }
        if let current, let cid = UpdateSignature.identifier(current), UpdateSignature.identifier(staged) != cid {
            throw UpdateError("Update has a different app identity")
        }
        let plist = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        let v = plist?["CFBundleShortVersionString"] as? String ?? ""
        guard VersionComparator.isNewer(remote: v, than: UpdateChecker.currentVersion),
              VersionComparator.components(v) == VersionComparator.components(expectedVersion) else {
            throw UpdateError("Update version doesn't match the release")
        }
    }

    static func helperBinaryDiffers(old: URL, new: URL) -> Bool {
        let rel = "Contents/MacOS/GogglesHelper"
        guard let a = try? Data(contentsOf: old.appendingPathComponent(rel)),
              let b = try? Data(contentsOf: new.appendingPathComponent(rel)) else { return true }
        return SHA256.hash(data: a) != SHA256.hash(data: b)
    }

    /// Launch hook: if the last update replaced the helper, re-register so launchd runs the new binary.
    static func finishPendingHelperUpdate() {
        let d = UserDefaults.standard
        guard let v = d.string(forKey: UpdatePrefs2.helperChangedKey), v == UpdateChecker.currentVersion else { return }
        d.removeObject(forKey: UpdatePrefs2.helperChangedKey)
        _ = try? HelperRegistration.unregister()
        _ = try? HelperRegistration.register()
    }
}
