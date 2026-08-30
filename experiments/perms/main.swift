// Checks what permissions a secret actually lands on disk with.
//
// The code asks for 0600. The files in /usr/local/var/v-claw are 0660, so something
// between the request and the result is not doing what it looks like.
import Foundation

let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())
let target = dir.appendingPathComponent("perm-probe")
try? FileManager.default.removeItem(at: target)

let data = Data(repeating: 0x41, count: 16)

func mode(_ url: URL) -> String {
    let a = try? FileManager.default.attributesOfItem(atPath: url.path)
    let n = (a?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    return n < 0 ? "??" : String(n, radix: 8)
}

// Exactly what Storage.write does today.
do {
    try data.write(to: target, options: [.atomic, .completeFileProtection])
    print("after write, before chmod: \(mode(target))")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    print("after setAttributes:       \(mode(target))   (want 600)")
} catch {
    print("failed: \(error)")
}

// And the alternative: create with the mode up front, so the secret is never on disk
// with anything looser, even briefly.
let target2 = dir.appendingPathComponent("perm-probe-2")
try? FileManager.default.removeItem(at: target2)
FileManager.default.createFile(atPath: target2.path, contents: data,
                               attributes: [.posixPermissions: 0o600])
print("created with attributes:   \(mode(target2))   (want 600)")

try? FileManager.default.removeItem(at: target)
try? FileManager.default.removeItem(at: target2)
