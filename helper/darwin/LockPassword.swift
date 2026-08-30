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
//   * In a 0600 file next to the state, never in state.json, which is world-readable
//     by design.
//
// Not the Keychain, though that was the first attempt. v-claw is built from source and
// ad-hoc signed, so every rebuild has a different code identity and the Keychain treats
// it as a different application: reading the item raises an authorisation prompt. Behind
// a full-screen lock that prompt is invisible and the call blocks forever, which traps
// the user with no way out. A blocking call is unacceptable anywhere the lock screen
// depends on it.
//
// A file is weaker at rest, and that is an accepted trade. What is stored is a
// 310,000-round PBKDF2 hash rather than the secret, the disk is covered by FileVault,
// and the virtual lock was never a security boundary.
//
// Forgetting it costs a restart, and nothing more. The password is bound to the current
// boot: the stored record carries the boot time, and a record from an earlier boot is
// discarded on sight. So a reboot always clears both the lock and the password.
//
// That is the whole recovery story, and it is deliberately something anyone can do
// without a terminal, a second machine, or this documentation. A lock that can shut you
// out of your own computer is worse than no lock, and this one cannot: it is a window,
// not a security boundary.
//
// The cost is re-setting the password after each restart. On a machine v-claw is built
// for — one kept awake for days at a time — that is rare enough to be worth the
// guarantee.
import CommonCrypto
import Foundation
import Security

enum LockPassword {
    /// Beside the state file, so it follows the same directory resolution.
    private static var file: URL { Storage.dir.appendingPathComponent("lock.secret") }

    private static let saltBytes = 16
    private static let hashBytes = 32
    private static let bootBytes = 8
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

        return store(Data(salt) + Data(hash) + bootTimeBytes())
    }

    static func verify(_ attempt: String) -> Bool {
        guard let blob = load() else { return false }
        // Layout is salt | hash | boot time. Index from the front: the boot stamp sits
        // at the end, so taking the hash from the back would slice through it.
        let salt = [UInt8](blob.prefix(saltBytes))
        let expected = [UInt8](blob.dropFirst(saltBytes).prefix(hashBytes))
        guard let actual = derive(attempt, salt: salt) else { return false }
        return constantTimeEqual(actual, expected)
    }

    @discardableResult
    static func clear() -> Bool {
        try? FileManager.default.removeItem(at: file)
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

    // MARK: storage

    private static func store(_ blob: Data) -> Bool { Storage.write(blob, to: file) }

    /// Seconds since the epoch at which this machine last booted. Records carrying any
    /// other value belong to a previous boot and are discarded.
    private static func currentBoot() -> Int64 {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return Int64(tv.tv_sec)
    }

    private static func bootTimeBytes() -> Data {
        var v = currentBoot().littleEndian
        return Data(bytes: &v, count: bootBytes)
    }

    private static func load() -> Data? {
        guard let blob = try? Data(contentsOf: file),
              blob.count == saltBytes + hashBytes + bootBytes
        else { return nil }

        // A record from a previous boot is stale by design. Delete it rather than
        // merely ignore it, so a forgotten password cannot linger in the Keychain.
        let stored = blob.suffix(bootBytes).withUnsafeBytes {
            $0.loadUnaligned(as: Int64.self).littleEndian
        }
        guard stored == currentBoot() else {
            clear()
            return nil
        }
        return blob
    }
}
