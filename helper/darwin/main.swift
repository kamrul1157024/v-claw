// v-claw-ui draws everything v-claw shows: the main window, the permissions window,
// the virtual lock screen, and notifications.
//
// It is a separate process from the Go app on purpose. All of this is deeply native
// AppKit, and Go has no good binding for any of it; in-process it would mean hundreds
// of lines of Objective-C inside cgo string literals. Out of process, a bug here cannot
// take down the tray, and a crash while locked simply returns the desktop.
//
// It also owns notifications, because posting them needs the app bundle's identity.
// The Go binary alone would post as whatever tool it shelled out to.
//
// The helper holds no state. It renders what the Go side sends and reports what the
// user did, so the two can never disagree about the truth.
//
// Protocol: one JSON object per line, both directions. See Protocol.swift.
import AppKit
import UserNotifications

final class Delegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        if Permissions.notificationsAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
        // Permissions used to be applied only at write time, so a secret written by an
        // older build keeps its looser mode until something happens to rewrite it.
        Storage.tightenAll()

        readCommands()
        Event.send("ready")
    }

    /// Clicking the Dock icon of a running app with no open window does nothing by
    /// default, which makes the icon look broken. Ask the Go side to open the window
    /// instead: it owns the state, so it can send a complete one rather than the
    /// helper guessing from something stale.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows visible: Bool) -> Bool {
        if !visible { Event.send("openWindow") }
        return true
    }

    // Show notifications even when v-claw is frontmost; the release warning matters
    // more than the convention of suppressing them.
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        done([.banner, .sound])
    }

    /// Reads stdin on a background thread and dispatches to the main thread. AppKit
    /// must not be touched off the main thread, and stdin must not block the run loop.
    private func readCommands() {
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8),
                      let cmd = try? JSONDecoder().decode(Command.self, from: data)
                else {
                    Event.send("error", ["message": "malformed command"])
                    continue
                }
                DispatchQueue.main.async { handle(cmd) }
            }
            // Go closed stdin, which means the app is gone. Do not linger: an orphaned
            // lock window with nothing driving it would trap the user.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

func handle(_ c: Command) {
    switch c.cmd {
    case "show":
        guard let s = c.state else { return }
        Panel.shared.show(s)

    case "state":
        guard let s = c.state else { return }
        Panel.shared.update(s)
        Lock.shared.updateMessage(s.statusLine)

    case "hide":
        Panel.shared.close()

    case "dock":
        setDockVisible(c.on ?? false)

    case "permissions":
        Permissions.shared.show(c.state?.hotkeyEnabled ?? false)

    case "lock":
        Lock.shared.engage(policy: c.policy ?? "none", message: c.message ?? "")

    case "unlock":
        Lock.shared.forceUnlock()

    case "notify":
        postNotification(title: c.title ?? "v-claw", body: c.body ?? "")

    case "diagnostics":
        showDiagnostics(c.text ?? "")

    case "quit":
        NSApp.terminate(nil)

    default:
        Event.send("error", ["message": "unknown command \(c.cmd)"])
    }
}

/// Shows or hides the Dock icon.
///
/// The menu bar is not a reliable place to live. Once it fills up macOS hides new
/// items behind the notch without saying so, and an app whose only presence has
/// silently vanished may as well not be running. The Dock never overflows.
///
/// .regular also brings a menu bar of our own and an app switcher entry, which is the
/// honest trade for being findable.
func setDockVisible(_ on: Bool) {
    let want: NSApplication.ActivationPolicy = on ? .regular : .accessory
    guard NSApp.activationPolicy() != want else { return }
    NSApp.setActivationPolicy(want)

    // Switching to .regular while already running leaves the app unfocused and the
    // Dock icon inert until something activates it.
    if on { NSApp.activate(ignoringOtherApps: true) }
}

func postNotification(title: String, body: String) {
    // Always draw the banner. macOS refuses notifications to an ad-hoc signed bundle,
    // and the refusal is silent — the whole point of these messages is that nobody is
    // watching the app when they fire, so a delivery path that can quietly fail is no
    // path at all.
    Banner.shared.show(title: title, body: body)

    guard Permissions.notificationsAvailable else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body

    let req = UNNotificationRequest(
        identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(req) { err in
        if let err { Event.send("error", ["message": "notify: \(err.localizedDescription)"]) }
    }
}

func showDiagnostics(_ text: String) {
    let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    w.title = "v-claw diagnostics"
    w.isReleasedWhenClosed = false

    let view = NSTextView()
    view.string = text
    view.isEditable = false
    view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    view.textContainerInset = NSSize(width: 12, height: 12)

    let scroll = NSScrollView()
    scroll.documentView = view
    scroll.hasVerticalScroller = true
    w.contentView = scroll
    w.center()
    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}

let app = NSApplication.shared
// .accessory keeps v-claw out of the Dock and the app switcher. The Go process owns
// the menu bar item; this helper only ever shows windows.
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
Permissions.requestQuietly()
app.run()
