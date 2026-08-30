// Diagnostic: what codes does v-claw currently accept, and why was one refused?
//
// Prints live codes. They expire within a couple of minutes and this runs on the
// machine that owns them, but do not paste the output anywhere public.
import CommonCrypto
import Foundation

let dir = "/usr/local/var/v-claw"
let seedPath = dir + "/totp.seed"
let usedPath = dir + "/totp.used"

guard let b32 = try? String(contentsOfFile: seedPath, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
else {
    print("no seed at \(seedPath)")
    exit(1)
}

func unbase32(_ s: String) -> Data {
    let alpha = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var out = Data(), buf = 0, bits = 0
    for ch in s.uppercased() where ch != "=" {
        guard let v = alpha.firstIndex(of: ch) else { continue }
        buf = (buf << 5) | v
        bits += 5
        if bits >= 8 {
            out.append(UInt8((buf >> (bits - 8)) & 0xFF))
            bits -= 8
        }
    }
    return out
}

func code(_ key: Data, _ step: Int64) -> String {
    var c = step.bigEndian
    let msg = Data(bytes: &c, count: 8)
    var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    key.withUnsafeBytes { k in
        msg.withUnsafeBytes { m in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),
                   k.baseAddress, k.count, m.baseAddress, m.count, &mac)
        }
    }
    let o = Int(mac[19] & 0x0F)
    let bin = (UInt32(mac[o] & 0x7F) << 24) | (UInt32(mac[o + 1]) << 16)
        | (UInt32(mac[o + 2]) << 8) | UInt32(mac[o + 3])
    return String(format: "%06u", bin % 1_000_000)
}

let key = unbase32(b32)
print("seed length: \(key.count) bytes  (want 20)")

let now = Int64(Date().timeIntervalSince1970)
let step = now / 30
let intoStep = now % 30

let used = (try? String(contentsOfFile: usedPath, encoding: .utf8))
    .flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

print("current step: \(step), \(intoStep)s into it, \(30 - intoStep)s until the next")
print("burned step:  \(used.map(String.init) ?? "none")")
print("")
print("codes v-claw will accept right now (window: 2 steps either side):")
for offset in Int64(-2)...2 {
    let s = step + offset
    let mark = used == s ? "  ALREADY USED, will be refused" : ""
    let age = (step - s) * 30 + intoStep
    let label = offset == 0 ? "current" : (offset > 0 ? "\(offset * 30)s ahead" : "\(age)s old")
    print("  step \(s)  \(code(key, s))   \(label)\(mark)")
}
print("")
print("Compare the 'current' code with your authenticator.")
print("If they differ, the phone holds a different seed and enrolment did not take.")
