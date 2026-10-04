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

    /// Waits for `pid` to exit, swaps the bundle (restoring the old one if the copy fails), clears quarantine, optionally relaunches.
    static func make(pid: Int32, staged: String, dest: String, relaunch: Bool) -> String {
        """
        #!/bin/sh
        STAGED=\(quote(staged))
        DEST=\(quote(dest))
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        OLD="$DEST.old"
        rm -rf "$OLD"
        mv "$DEST" "$OLD" || exit 1
        if /usr/bin/ditto "$STAGED" "$DEST"; then
          /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
          rm -rf "$OLD" "$STAGED"
        else
          rm -rf "$DEST"; mv "$OLD" "$DEST"
        fi
        \(relaunch ? "/usr/bin/open \"$DEST\"" : "")
        """
    }
}

enum UpdatePrefs2 {
    static let autoInstallKey = "updateAutoInstall"
    static let helperChangedKey = "updateHelperChanged"
}

final class UpdateInstaller: ObservableObject {
    static let shared = UpdateInstaller()

    enum State: Equatable {
        case idle
        case downloading
        case staged(version: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var stagedApp: URL?
    private var stagedVersion = ""
    private var scriptSpawned = false
    private var terminateObserver: NSObjectProtocol?

    var bundleURL: URL { Bundle.main.bundleURL }

    func isRecordingNow() -> Bool { SessionControlBoard.shared.anyRecording }

    /// Download, verify and stage `asset`. Does not touch the installed app.
    func stage(asset: UpdateAsset, version: String) {
        guard state != .downloading else { return }
        guard FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            state = .failed("GogglesView's folder isn't writable. Download the release manually."); return
        }
        state = .downloading
        Task.detached { [self] in
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: asset.url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed") }
                let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
                if let want = asset.sha256 {
                    let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard got == want else { throw UpdateError("Checksum mismatch; update discarded") }
                }
                let app = try Self.extractApp(dmg: tmp, expectedVersion: version, current: Bundle.main.bundleURL)
                await MainActor.run {
                    self.stagedApp = app; self.stagedVersion = version
                    self.state = .staged(version: version)
                    self.armInstallOnQuit()
                }
            } catch {
                await MainActor.run { self.state = .failed((error as? UpdateError)?.message ?? error.localizedDescription) }
            }
        }
    }

    /// Install and relaunch now.
    func installAndRestart() {
        guard case .staged = state else { return }
        spawnScript(relaunch: true)
        NSApp.terminate(nil)
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
        let script = UpdateInstallScript.make(pid: ProcessInfo.processInfo.processIdentifier,
                                              staged: staged.path, dest: bundleURL.path, relaunch: relaunch)
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

    static func extractApp(dmg: URL, expectedVersion: String, current: URL?) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("gogglesview-update-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mnt"), out = work.appendingPathComponent("out")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let dmgCopy = work.appendingPathComponent("u.dmg")
        try fm.copyItem(at: dmg, to: dmgCopy)
        guard try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, dmgCopy.path]) == 0 else {
            throw UpdateError("Couldn't open the update disk image")
        }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
        let src = mount.appendingPathComponent("GogglesView.app")
        guard fm.fileExists(atPath: src.path) else { throw UpdateError("Update does not contain GogglesView.app") }
        let dst = out.appendingPathComponent("GogglesView.app")
        guard try run("/usr/bin/ditto", [src.path, dst.path]) == 0 else { throw UpdateError("Couldn't copy the update") }
        try verify(staged: dst, current: current, expectedVersion: expectedVersion)
        return dst
    }

    /// Signature must be valid, same bundle id, same team (when the running app has one), and a newer version.
    static func verify(staged: URL, current: URL?, expectedVersion: String) throws {
        func info(_ url: URL) throws -> (id: String?, team: String?) {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
                throw UpdateError("Update is not a valid app")
            }
            guard SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), nil, nil) == errSecSuccess else {
                throw UpdateError("Update's code signature is invalid")
            }
            var dict: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dict) == errSecSuccess,
                  let d = dict as? [String: Any] else { throw UpdateError("Couldn't read update signature") }
            return (d[kSecCodeInfoIdentifier as String] as? String, d[kSecCodeInfoTeamIdentifier as String] as? String)
        }
        let new = try info(staged)
        if let current {
            let cur = try info(current)
            guard new.id == cur.id else { throw UpdateError("Update has a different app identity") }
            if let team = cur.team, new.team != team { throw UpdateError("Update is signed by a different team") }
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
