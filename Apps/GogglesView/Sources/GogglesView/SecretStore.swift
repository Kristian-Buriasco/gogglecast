import Foundation
import Security
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Keychain-backed storage for secrets (stream key, SRT passphrase, web token,
/// GitHub token, webhook URLs). If the Keychain refuses a write (unsigned dev
/// builds, locked keychain) the value falls back to UserDefaults so the
/// feature keeps working; reads check the Keychain first.
enum SecretStore {
    static let service = "com.kburiasco.gogglesview.secrets"

    /// Pure and testable: storage abstraction so tests do not touch the real Keychain.
    protocol Backend {
        func read(_ key: String) -> String?
        func write(_ value: String, _ key: String) -> Bool
        func remove(_ key: String)
    }

    struct KeychainBackend: Backend {
        private func query(_ key: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: SecretStore.service,
             kSecAttrAccount as String: key]
        }
        func read(_ key: String) -> String? {
            var q = query(key)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        func write(_ value: String, _ key: String) -> Bool {
            let data = Data(value.utf8)
            let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecSuccess { return true }
            guard status == errSecItemNotFound else { return false }
            var add = query(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        func remove(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
    }

    nonisolated(unsafe) static var backend: Backend = KeychainBackend()
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    static func get(_ key: String) -> String {
        backend.read(key) ?? defaults.string(forKey: key) ?? ""
    }

    static func set(_ value: String, for key: String) {
        if value.isEmpty {
            backend.remove(key); defaults.removeObject(forKey: key); return
        }
        if backend.write(value, key) { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
    }

    static var allKeys: [String] {
        [RTMPPrefs.streamKeyKey, SRTPrefs.passphraseKey, WebViewerPrefs.tokenKey, UpdatePrefs.tokenKey]
            + AppEvent.allCases.map { EventHookConfig.webhookKey($0) }
    }

    /// Move any plaintext values left in UserDefaults into the Keychain.
    /// Safe to run on every launch; a value stays in UserDefaults only if the Keychain refuses it.
    static func migrateFromDefaults(keys: [String] = allKeys) {
        for k in keys {
            guard let v = defaults.string(forKey: k), !v.isEmpty else { continue }
            if backend.write(v, k) { defaults.removeObject(forKey: k) }
        }
    }
}

#if canImport(SwiftUI)
/// `@AppStorage` replacement for secrets.
@propertyWrapper
struct KeychainSecret: DynamicProperty {
    private let key: String
    @State private var value: String

    init(_ key: String) {
        self.key = key
        _value = State(initialValue: SecretStore.get(key))
    }

    var wrappedValue: String {
        get { value }
        nonmutating set { value = newValue; SecretStore.set(newValue, for: key) }
    }

    var projectedValue: Binding<String> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
#endif
