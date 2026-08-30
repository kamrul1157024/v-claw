// A time-based one-time code, RFC 6238, as a second way past the virtual lock.
//
// Why this exists at all: the other recovery path is a restart, and a restart destroys
// the thing v-claw is for. People keep a machine awake for days because long-running
// work is on it, so "forgot your password? reboot" throws away exactly what the app was
// protecting. A code from your phone gets you back in without losing the session.
//
// This is a second credential, not an escape valve. It cannot be provoked by breaking
// something, it needs possession of the phone holding the seed, and each code is valid
// for about a minute. Restart remains the fallback for when the phone is not to hand.
//
// The seed is a real secret, unlike the password record which is only a hash. It lives
// in a 0600 file and is therefore readable by anything running as this user. That is a
// smaller weakness than it sounds: anything that can read the seed can also delete the
// password record outright, so it grants no capability the attacker lacked.
import CommonCrypto
import CoreImage
import Foundation

enum TOTP {
    private static let digits = 6
    private static let period: Int64 = 30
    /// The acceptance window, two steps either side, so ±60 seconds plus the current
    /// step.
    ///
    /// Phone clocks drift, and they drift forwards as often as backwards. A phone
    /// running 30 seconds fast shows the code for the *next* step, which a tight
    /// forward window rejects outright; the user then waits, the Mac advances a step,
    /// and the following code works. That is the failure this width exists to absorb,
    /// and it was measured on a real device rather than guessed at.
    ///
    /// The cost is five live codes instead of three. With each step burned on use and
    /// a growing delay after every wrong attempt, guessing one is not a practical
    /// attack. Being forgiving matters more here than in an ordinary login: this code
    /// is what stands between the user and losing every long-running task on the
    /// machine, and it is needed at precisely the moment nothing else is working.
    private static let stepsBack: Int64 = 2
    private static let stepsForward: Int64 = 2

    /// How far the accepted code was from the current step, in seconds, last time one
    /// worked. Non-zero means a clock is drifting and something should say so.
    private(set) static var lastSkewSeconds: Int64 = 0

    private static var seedFile: URL { Storage.dir.appendingPathComponent("totp.seed") }
    private static var usedFile: URL { Storage.dir.appendingPathComponent("totp.used") }

    static var isConfigured: Bool { secret() != nil }

    /// Why the last code was refused. Never contains the code itself. Logged so a
    /// recurrence leaves evidence rather than a guess.
    private(set) static var lastRejection = ""

    // MARK: setup

    /// Generates a seed and returns it base32-encoded. Deliberately does NOT persist.
    ///
    /// Nothing reaches disk until the user proves their authenticator holds it, for two
    /// reasons. A scan that silently failed, or went into the wrong app, would otherwise
    /// only be discovered while locked out — the worst possible moment to find out. And
    /// an abandoned setup would leave a live seed behind that nobody ever scanned, after
    /// it had already been displayed on screen.
    static func generate() -> String? {
        var raw = [UInt8](repeating: 0, count: 20)
        guard SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw) == errSecSuccess else {
            return nil
        }
        return base32(Data(raw))
    }

    /// Checks a code against a seed that is not stored yet. Used to confirm enrolment.
    static func matches(_ entered: String, secret: String) -> Bool {
        let cleaned = entered.filter(\.isNumber)
        guard cleaned.count == digits, let key = unbase32(secret) else { return false }

        let step = Int64(Date().timeIntervalSince1970) / period
        for offset in -stepsBack ... stepsForward
            where constantTimeEqual(code(key: key, step: step + offset), cleaned)
        {
            return true
        }
        return false
    }

    /// Persists a seed the user has just proved they hold.
    @discardableResult
    static func commit(_ secret: String) -> Bool {
        guard Storage.write(Data(secret.utf8), to: seedFile) else { return false }
        try? FileManager.default.removeItem(at: usedFile)
        return true
    }

    static func forget() {
        try? FileManager.default.removeItem(at: seedFile)
        try? FileManager.default.removeItem(at: usedFile)
    }

    /// The otpauth:// URI an authenticator app expects behind a QR code.
    static func uri(secret: String, account: String) -> String {
        let issuer = "v-claw"
        let label = "\(issuer):\(account)"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? issuer
        return "otpauth://totp/\(label)?secret=\(secret)&issuer=\(issuer)&digits=\(digits)&period=\(period)"
    }

    static func qr(for uri: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(uri.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else { return nil }

        let scaled = out.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    // MARK: verification

    /// Checks a code and, on success, burns the time step it came from.
    ///
    /// Without the burn, a code stays valid for its whole window, so anyone who watched
    /// it being typed could reuse it. One use per step closes that.
    static func verify(_ entered: String) -> Bool {
        let cleaned = entered.filter(\.isNumber)
        guard cleaned.count == digits, let key = secret() else { return false }

        let step = Int64(Date().timeIntervalSince1970) / period
        var sawUsed = false

        for offset in -stepsBack ... stepsForward {
            let candidate = step + offset
            let matches = constantTimeEqual(code(key: key, step: candidate), cleaned)
            guard matches else { continue }

            if isUsed(candidate) {
                // The digits were right but this code has already been spent. Worth
                // distinguishing in the log from a code that simply did not match.
                sawUsed = true
                continue
            }
            markUsed(candidate)
            lastSkewSeconds = offset * period
            return true
        }

        lastRejection = sawUsed ? "code already used" : "no matching code in the window"
        return false
    }

    private static func code(key: Data, step: Int64) -> String {
        var counter = step.bigEndian
        let msg = Data(bytes: &counter, count: 8)

        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        key.withUnsafeBytes { k in
            msg.withUnsafeBytes { m in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),
                       k.baseAddress, k.count, m.baseAddress, m.count, &mac)
            }
        }

        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary =
            (UInt32(mac[offset] & 0x7F) << 24) |
            (UInt32(mac[offset + 1]) << 16) |
            (UInt32(mac[offset + 2]) << 8) |
            UInt32(mac[offset + 3])

        let mod = UInt32(pow(10, Double(digits)))
        return String(format: "%0\(digits)u", binary % mod)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: storage

    private static func secret() -> Data? {
        guard let text = try? String(contentsOf: seedFile, encoding: .utf8) else { return nil }
        return unbase32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isUsed(_ step: Int64) -> Bool {
        guard let text = try? String(contentsOf: usedFile, encoding: .utf8) else { return false }
        return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) == step
    }

    private static func markUsed(_ step: Int64) {
        _ = Storage.write(Data(String(step).utf8), to: usedFile)
    }

    // MARK: base32, RFC 4648 without padding

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static func base32(_ data: Data) -> String {
        var out = "", buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    private static func unbase32(_ s: String) -> Data? {
        var out = Data(), buffer = 0, bits = 0
        for ch in s.uppercased() where ch != "=" {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | v
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out.isEmpty ? nil : out
    }
}

/// Shared file location and permissions for both secrets.
enum Storage {
    static var dir: URL {
        let shared = "/usr/local/var/v-claw"
        if FileManager.default.fileExists(atPath: shared) {
            return URL(fileURLWithPath: shared)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/v-claw")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}
