import AltyaziCore
import Foundation
import RemotePlayKit
import Security

/// PS5 eşleşme bilgisi gizlidir; telefonun Anahtar Zinciri'nde saklanır.
enum KeychainStore {
    private static let service = "com.marhilk.app.ps5"
    private static let account = "credentials"

    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    static func load() -> RemotePlayCredentials? {
        var request = query
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(RemotePlayCredentials.self, from: data)
    }

    @discardableResult
    static func save(_ credentials: RemotePlayCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Samsung TV kurulum anahtarları ve sertifikaları

    private static var samsungQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.marhilk.app.samsung", kSecAttrAccount: "signing"]
    }

    static func loadSamsungMaterial() -> SamsungSigningMaterial? {
        var request = samsungQuery
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SamsungSigningMaterial.self, from: data)
    }

    static func saveSamsungMaterial(_ material: SamsungSigningMaterial) {
        guard let data = try? JSONEncoder().encode(material) else { return }
        SecItemDelete(samsungQuery as CFDictionary)
        var item = samsungQuery
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    // MARK: - Yapay zekâ çeviri anahtarı

    private static var aiQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.marhilk.app.ai", kSecAttrAccount: "anthropic-key"]
    }

    static func loadAIKey() -> String? {
        var request = aiQuery
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveAIKey(_ key: String?) {
        SecItemDelete(aiQuery as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var item = aiQuery
        item[kSecValueData] = Data(key.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
