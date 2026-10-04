import Foundation
import Testing
@testable import GogglesView

private final class MemoryBackend: SecretStore.Backend {
    var items: [String: String] = [:]
    var failWrites = false
    func read(_ key: String) -> String? { items[key] }
    func write(_ value: String, _ key: String) -> Bool {
        if failWrites { return false }
        items[key] = value; return true
    }
    func remove(_ key: String) { items[key] = nil }
}

@Suite(.serialized)
struct SecretStoreTests {
    private func fixture() -> (MemoryBackend, UserDefaults) {
        let b = MemoryBackend()
        let d = UserDefaults(suiteName: "SecretStoreTests-\(UUID().uuidString)")!
        SecretStore.backend = b
        SecretStore.defaults = d
        return (b, d)
    }

    @Test func setStoresInBackendNotDefaults() {
        let (b, d) = fixture()
        SecretStore.set("abc", for: "k")
        #expect(b.items["k"] == "abc")
        #expect(d.string(forKey: "k") == nil)
        #expect(SecretStore.get("k") == "abc")
    }

    @Test func fallsBackToDefaultsWhenKeychainRefuses() {
        let (b, d) = fixture()
        b.failWrites = true
        SecretStore.set("abc", for: "k")
        #expect(d.string(forKey: "k") == "abc")
        #expect(SecretStore.get("k") == "abc")
    }

    @Test func emptyValueRemovesEverywhere() {
        let (b, d) = fixture()
        SecretStore.set("abc", for: "k")
        d.set("old", forKey: "k")
        SecretStore.set("", for: "k")
        #expect(b.items["k"] == nil)
        #expect(d.string(forKey: "k") == nil)
        #expect(SecretStore.get("k") == "")
    }

    @Test func migrationMovesPlaintextAndClearsIt() {
        let (b, d) = fixture()
        d.set("streamkey", forKey: RTMPPrefs.streamKeyKey)
        d.set("https://hook.example/x", forKey: EventHookConfig.webhookKey(.streamLive))
        SecretStore.migrateFromDefaults()
        #expect(b.items[RTMPPrefs.streamKeyKey] == "streamkey")
        #expect(b.items[EventHookConfig.webhookKey(.streamLive)] == "https://hook.example/x")
        #expect(d.string(forKey: RTMPPrefs.streamKeyKey) == nil)
        #expect(SecretStore.get(RTMPPrefs.streamKeyKey) == "streamkey")
    }

    @Test func migrationKeepsDefaultsIfKeychainRefuses() {
        let (b, d) = fixture()
        b.failWrites = true
        d.set("streamkey", forKey: RTMPPrefs.streamKeyKey)
        SecretStore.migrateFromDefaults()
        #expect(d.string(forKey: RTMPPrefs.streamKeyKey) == "streamkey")
    }

    @Test func coversAllKnownSecrets() {
        let keys = SecretStore.allKeys
        for k in [RTMPPrefs.streamKeyKey, SRTPrefs.passphraseKey, WebViewerPrefs.tokenKey, UpdatePrefs.tokenKey] {
            #expect(keys.contains(k))
        }
        #expect(keys.count == 4 + AppEvent.allCases.count)
    }
}
