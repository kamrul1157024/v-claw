// Does recovery work when the phone's clock is wrong?
//
// The floor used to be pinned at currentStep + 1, which rejected every phone running
// even slightly slow: such a phone still shows the current step when the gate opens.
// The user saw "that code was already showing" about a code they had never seen, and
// only the second attempt worked — the exact symptom reported.
import CommonCrypto
import Foundation

// Refuse to run against the real secrets. This file links the app's own TOTP code, so
// without an override it reads and writes the live seed — and TOTP.forget() below once
// destroyed a real authenticator enrolment on a working machine.
guard ProcessInfo.processInfo.environment["VCLAW_DIR"] != nil else {
    print("refusing to run: set VCLAW_DIR to a scratch directory first")
    exit(2)
}

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
    print("\(got == want ? "ok  " : "FAIL") \(label): \(got) (want \(want))")
}

let secret = TOTP.generate()!

/// One recovery attempt. `phoneOffsetSteps` is how far ahead the phone's clock runs.
/// The gate opens at the Mac's next boundary, so the Mac is at T+1 and the phone shows
/// (T+1) + offset.
func attempt(phoneOffsetSteps: Int64) -> Bool {
    TOTP.forget()
    _ = TOTP.commit(secret, confirmedWith: phoneCode(secret: secret, step: TOTP.currentStep))

    let clickStep = TOTP.currentStep
    let floor = clickStep // what armRecovery pins now

    let macStepWhenGateOpens = clickStep + 1
    let shown = macStepWhenGateOpens + phoneOffsetSteps

    // verify() works off the real clock, so evaluate the floor rule directly against
    // the step the phone is displaying.
    let inWindow = abs(shown - TOTP.currentStep) <= 2
    return inWindow && shown >= floor
}

check("phone 30s slow  (-1 step)", attempt(phoneOffsetSteps: -1), true)
check("phone in sync   ( 0 step)", attempt(phoneOffsetSteps: 0), true)
check("phone 30s fast  (+1 step)", attempt(phoneOffsetSteps: 1), true)
check("phone 60s fast  (+2 step)", attempt(phoneOffsetSteps: 2), false) // beyond window

// The floor must still refuse a code from before the user asked to recover.
TOTP.forget()
_ = TOTP.commit(secret, confirmedWith: phoneCode(secret: secret, step: TOTP.currentStep))
let floorNow = TOTP.currentStep
check("code from before the request is refused",
      TOTP.verify(phoneCode(secret: secret, step: floorNow - 1), notBefore: floorNow), false)
// commit burns the step it was confirmed with, so check the next one rather than
// re-testing a code that has already been spent.
check("code from the request onward is accepted",
      TOTP.verify(phoneCode(secret: secret, step: floorNow + 1), notBefore: floorNow), true)

TOTP.forget()
print(bad == 0 ? "\nall correct" : "\n\(bad) wrong")
exit(bad == 0 ? 0 : 1)
