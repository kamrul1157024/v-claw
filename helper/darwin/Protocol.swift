// The wire protocol between the Go app and this helper.
//
// One JSON object per line, in both directions. A line protocol keeps the helper
// debuggable by hand: you can drive the whole UI by typing into stdin.
import Foundation

// MARK: - Go -> helper

struct Command: Decodable {
    let cmd: String
    let state: UIState?
    let policy: String?
    let message: String?
    let title: String?
    let body: String?
    let text: String?
}

/// Everything the UI needs to draw itself. The helper owns no state of its own; it
/// renders what it is given and reports what the user did. That keeps a single source
/// of truth in the Go process and makes the two impossible to disagree.
struct UIState: Decodable {
    let mode: String
    let blockLidSleep: Bool
    let keepDisplayOn: Bool
    let expiresInSeconds: Int?
    let onAC: Bool
    let holding: Bool
    let tier: String
    let statusLine: String
    let lidHint: String
    let lockEnabled: Bool
    let lockPolicy: String
    let lockIdleMinutes: Int
    let hotkeyEnabled: Bool
    let restartAuthWarning: String
}

// MARK: - helper -> Go

enum Event {
    static func send(_ name: String, _ fields: [String: Any] = [:]) {
        var obj: [String: Any] = ["ev": name]
        fields.forEach { obj[$0] = $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8)
        else { return }
        print(line)
        fflush(stdout)
    }
}
