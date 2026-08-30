// Checks the recovery countdown arithmetic without drawing anything.
//
// The lock screen's timing is the part that was wrong twice, so it is worth exercising
// on its own rather than only by eye.
import Foundation

func armTime(now: Double) -> Double { (floor(now / 30) + 1) * 30 }

var failures = 0
func check(_ label: String, _ got: Int, _ want: Int) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(label): got \(got)s, want \(want)s")
}

// Pressing the button 1s into a step should wait 29s for the next one.
var now = 59_603_400.0 + 1
check("wait when 1s into a step", Int((armTime(now: now) - now).rounded(.up)), 29)

// Pressing it 29s in should wait only 1s, not a flat 30.
now = 59_603_400.0 + 29
check("wait when 29s into a step", Int((armTime(now: now) - now).rounded(.up)), 1)

// Once armed, the code has a full window.
now = armTime(now: 59_603_400.0 + 29)
check("life of a fresh code", 30 - Int(now) % 30, 30)

// Halfway through, half the window is left.
check("life halfway through", 30 - Int(now + 15) % 30, 15)

// The amber warning should appear at seven seconds or fewer.
let amberAt = (0 ..< 30).filter { 30 - Int(now + Double($0)) % 30 <= 7 }.min() ?? -1
check("amber starts", amberAt, 23)

print(failures == 0 ? "\nall correct" : "\n\(failures) wrong")
exit(failures == 0 ? 0 : 1)
