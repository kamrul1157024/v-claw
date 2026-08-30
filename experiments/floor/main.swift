// Checks that a code showing before the user asked to recover is refused, even though
// it still falls inside the skew window.
import CommonCrypto
import Foundation

func phoneCode(secret: String, step: Int64) -> String {
    let alpha = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var key = Data(), buf = 0, bits = 0
    for ch in secret.uppercased() where ch != "=" {
        guard let v = alpha.firstIndex(of: ch) else { continue }
        buf = (buf << 5) | v
        bits += 5
        if bits >= 8 {
            key.append(UInt8((buf >> (bits - 8)) & 0xFF))
            bits -= 8
        }
    }
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

var bad = 0
func check(_ label: String, _ got: Bool, _ want: Bool) {
    if got != want { bad += 1 }
    print("\(got == want ? "ok  " : "FAIL") \(label): \(got), want \(want)")
}

TOTP.forget()
let secret = TOTP.generate()!
let now = TOTP.currentStep
_ = TOTP.commit(secret, confirmedWith: phoneCode(secret: secret, step: now))

// The user presses "Use recovery code" now, so only step now+1 onwards may be used.
let floor = TOTP.currentStep + 1

check("code showing before the request is refused",
      TOTP.verify(phoneCode(secret: secret, step: now), notBefore: floor), false)
check("  reason names it", TOTP.lastRejection == "code predates the recovery request", true)

check("the one before that is refused too",
      TOTP.verify(phoneCode(secret: secret, step: now - 1), notBefore: floor), false)

check("a code minted after the request is accepted",
      TOTP.verify(phoneCode(secret: secret, step: floor), notBefore: floor), true)

check("and it cannot be replayed",
      TOTP.verify(phoneCode(secret: secret, step: floor), notBefore: floor), false)

// Without a floor the old code is still inside the window, which is what made the
// gate cosmetic before this change.
check("no floor means the old code still works",
      TOTP.verify(phoneCode(secret: secret, step: now)), true)

TOTP.forget()
print(bad == 0 ? "\nall correct" : "\n\(bad) wrong")
exit(bad == 0 ? 0 : 1)
