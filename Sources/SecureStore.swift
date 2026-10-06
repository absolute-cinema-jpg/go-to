import CryptoKit
import Foundation
import Security

/// Encrypts the files Go To keeps on disk (file index, history) with AES-GCM.
/// The key lives in the login keychain, so other processes can't read file names
/// out of the cache without triggering a keychain prompt. If the keychain is
/// unavailable or access is denied, nothing is persisted at all.
enum SecureStore {
    private static let service = "local.goto.GoTo"
    private static let account = "storage-key"
    private static let lock = NSLock()
    private static var cachedKey: SymmetricKey?
    private static var keyUnavailable = false

    /// Fetches the key, creating it on first use. May block on a keychain prompt; call off the main thread.
    static func key() -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        if keyUnavailable { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            cachedKey = SymmetricKey(data: data)
            return cachedKey
        }
        // Only create a key when none exists; a denied prompt must not spawn a second item.
        guard status == errSecItemNotFound else {
            NSLog("GoTo: keychain key unavailable (\(status)); not persisting index or history")
            keyUnavailable = true
            return nil
        }
        let newKey = SymmetricKey(size: .bits256)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Go To storage key",
            kSecValueData as String: newKey.withUnsafeBytes { Data($0) },
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            NSLog("GoTo: could not store keychain key (\(addStatus)); not persisting index or history")
            keyUnavailable = true
            return nil
        }
        cachedKey = newKey
        return newKey
    }

    static func seal(_ data: Data, key: SymmetricKey) -> Data? { try? AES.GCM.seal(data, using: key).combined }

    static func open(_ sealed: Data, key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    /// Encrypts and writes `data` (owner-only, excluded from backups). Returns false if not persisted.
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        guard let key = key(), let sealed = seal(data, key: key) else { return false }
        do {
            try sealed.write(to: url, options: .atomic)
            restrict(url)
            return true
        } catch {
            return false
        }
    }

    /// Reads and decrypts. Returns nil if missing, tampered with, or the key is unavailable.
    static func read(from url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path),
              let key = key(),
              let sealed = try? Data(contentsOf: url) else { return nil }
        return open(sealed, key: key)
    }

    /// Owner-only permissions and no Time Machine copies.
    static func restrict(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}
