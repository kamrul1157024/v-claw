// The virtual lock's own password.
//
// v-claw deliberately does NOT use the macOS account password here. Asking someone to
// type their login password into a full-screen window drawn by a third-party app is
// the exact shape of a screen-locker phishing attack, and training that reflex is
// worse than anything this lock protects against. A separate secret also matches what
// the virtual lock honestly is: a privacy screen, not a security boundary.
//
// What is stored, and where:
//   * Never the password. A random 16-byte salt and a PBKDF2-HMAC-SHA256 hash.
//   * In the login Keychain, so it is encrypted at rest and never touches state.json,
//     which is world-readable by design.
//
// If you forget it, nothing is lost: quitting v-claw drops the lock, because it is a
// window and not a security boundary. `v-claw lock-reset` clears it.
import CommonCrypto
import Foundation
import Security

enum LockPassword {
    private static let service = "com.vclaw.virtual-lock"
    private static let account = "primary"

    private static let saltBytes = 16
    private static let hashBytes = 32
    // Deliberately high: the only realistic attack on a local hash is offline guessing.
    private static let rounds: UInt32 = 310_000

    static var isSet: Bool { load() != nil }

    /// Replaces any existing password. An empty string clears it.
    @discardableResult
    static func set(_ password: String) -> Bool {
        guard !password.isEmpty else { return clear() }

        var salt = [UInt8](repeating: 0, count: saltBytes)
        guard SecRandomCopyBytes(kSecRandomDefault, saltBytes, &salt) == errSecSuccess,
              let hash = derive(password, salt: salt)
        else { return false }

        return store(Data(salt) + Data(hash))
    }

    static func verify(_ attempt: String) -> Bool {
        guard let blob = load(), blob.count == saltBytes + hashBytes else { return false }
        let salt = [UInt8](blob.prefix(saltBytes))
        let expected = [UInt8](blob.suffix(hashBytes))
        guard let actual = derive(attempt, salt: salt) else { return false }
        return constantTimeEqual(actual, expected)
    }

    @discardableResult
    static func clear() -> Bool {
        SecItemDelete(baseQuery() as CFDictionary)
        return true
    }

    // MARK: crypto

    private static func derive(_ password: String, salt: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: hashBytes)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.utf8.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            rounds,
            &out, out.count)
        return status == kCCSuccess ? out : nil
    }

    /// Compares every byte regardless of where the first difference is, so the time
    /// taken reveals nothing about the stored hash.
    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    // MARK: keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func store(_ blob: Data) -> Bool {
        SecItemDelete(baseQuery() as CFDictionary)
        var item = baseQuery()
        item[kSecValueData as String] = blob
        // Available without unlocking anything extra, but never leaves this machine.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func load() -> Data? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}
