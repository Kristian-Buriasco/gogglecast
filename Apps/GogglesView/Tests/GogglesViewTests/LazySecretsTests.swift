import Foundation
import Testing
@testable import GogglesView

private final class CountingBackend: SecretStore.Backend {
    var items: [String: String] = [:]
    var reads = 0
    func read(_ key: String) -> String? { reads += 1; return items[key] }
    func write(_ value: String, _ key: String) -> Bool { items[key] = value; return true }
    func remove(_ key: String) { items[key] = nil }
}

/// A Keychain read is what makes macOS ask for the login password, so launch-time paths must not do one.
// An extension, so these join SecretStoreTests' serialized suite: the backend is process-global.
extension SecretStoreTests {
    private func lazyFixture() -> CountingBackend {
        let b = CountingBackend()
        SecretStore.backend = b
        SecretStore.defaults = UserDefaults(suiteName: "LazySecretsTests-\(UUID().uuidString)")!
        return b
    }

    @Test func buildingSecretFieldsReadsNothing() {
        let b = lazyFixture()
        let fields = [KeychainSecret(RTMPPrefs.streamKeyKey), KeychainSecret(WebViewerPrefs.tokenKey),
                      KeychainSecret(OBSPrefs.passwordKey), KeychainSecret(SRTPrefs.passphraseKey)]
        #expect(fields.allSatisfy { $0.wrappedValue.isEmpty })
        #expect(b.reads == 0)
    }

    @Test func postingEventsWithKnownEmptyHooksReadsNothing() {
        let b = lazyFixture()
        EventHookConfig.noteConfigured(false)
        EventBus.shared.post(.streamLive)
        #expect(b.reads == 0)
    }

    @Test func firstEventAfterUpgradeChecksOnceThenRemembers() {
        let b = lazyFixture()
        EventBus.shared.post(.streamLive)
        let first = b.reads
        #expect(first > 0)
        EventBus.shared.post(.streamLost)
        #expect(b.reads == first)
        #expect(!EventHookConfig.mayHaveHooks)
    }

    @Test func startingAFeatureReadsItsSecretOnce() {
        let b = lazyFixture()
        b.items[RTMPPrefs.streamKeyKey] = "live_123"
        #expect(RTMPPrefs.streamKey == "live_123")
        #expect(RTMPPrefs.streamKey == "live_123")
        #expect(b.reads == 1)
    }

    @Test func savingUpdatesTheCacheWithoutAnotherRead() {
        let b = lazyFixture()
        SecretStore.set("a", for: "k")
        #expect(SecretStore.get("k") == "a")
        #expect(b.reads == 0)
    }
}
