// The permissions window.
//
// v-claw asks for very little, and saying so plainly is worth a window of its own.
// On a managed Mac running EDR, an app that states which permissions it will never
// request is easier to trust and easier to get approved.
//
// Needed:      Notifications, so a release can be announced.
// Optional:    Accessibility, and only for the global lock hotkey.
// Never asked: Screen Recording, Input Monitoring, Full Disk Access, Camera, Mic.
//
// Idle detection deliberately uses CGEventSourceSecondsSinceLastEventType, which needs
// no permission, rather than an event tap, which needs Accessibility and looks like a
// keylogger to a reviewer.
import AppKit
import UserNotifications

final class Permissions: NSObject {
    static let shared = Permissions()

    private var window: NSWindow?
    private var notifyRow: Row?
    private var axRow: Row?

    /// UNUserNotificationCenter throws, not returns nil, when the process has no app
    /// bundle. That happens whenever the helper runs straight out of build/ during
    /// development, so every entry point has to check first.
    static var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Requests notification authorisation without showing any UI. Called once at
    /// launch: the system prompt is the only thing the user sees, and only the first
    /// time.
    static func requestQuietly() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Asks for notification permission, or sends the user to System Settings.
    ///
    /// requestAuthorization only ever prompts once. After the first answer it returns
    /// the stored decision immediately and shows nothing, so a button wired straight to
    /// it does nothing at all for anyone who has already said no — which is exactly
    /// when they are clicking it. Once denied, the only route is Settings.
    static func grantNotifications(_ done: @escaping () -> Void) {
        guard notificationsAvailable else { return done() }

        UNUserNotificationCenter.current().getNotificationSettings { s in
            switch s.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound]) { _, _ in
                        DispatchQueue.main.async { done() }
                    }
            default:
                DispatchQueue.main.async {
                    openNotificationSettings()
                    done()
                }
            }
        }
    }

    /// Opens the Notifications pane, scrolled to this app where macOS allows it.
    static func openNotificationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    static func notificationsGranted(_ done: @escaping (Bool) -> Void) {
        guard notificationsAvailable else { return done(false) }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { done(s.authorizationStatus == .authorized) }
        }
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func show(_ hotkeyEnabled: Bool) {
        if window == nil { build(hotkeyEnabled) }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build(_ hotkeyEnabled: Bool) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 470),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Permissions"
        w.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "v-claw needs almost nothing")
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let sub = NSTextField(wrappingLabelWithString:
            "No personal information is collected, and nothing leaves this machine.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.preferredMaxLayoutWidth = 380

        notifyRow = Row(
            title: "Notifications",
            detail: "Tell you when v-claw releases on its own, so a forgotten setting cannot quietly keep the machine awake.",
            action: "Grant Permission",
            onGrant: { done in
                Permissions.grantNotifications(done)
            })

        axRow = Row(
            title: "Accessibility  (optional)",
            detail: hotkeyEnabled
                ? "Only for the global lock hotkey. Everything else works without it."
                : "Not needed. Only required if you turn on the global lock hotkey.",
            action: "Open Settings",
            onGrant: { done in
                // Prompting is the documented way to get the app listed in Settings.
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
                NSWorkspace.shared.open(URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                done()
            })

        let never = NSTextField(wrappingLabelWithString: """
        v-claw will never ask for:
           •  Screen Recording        it does not read your screen
           •  Input Monitoring        idle time is read without an event tap
           •  Full Disk Access, Camera, Microphone, Contacts, Location
        """)
        never.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        never.textColor = .secondaryLabelColor
        never.preferredMaxLayoutWidth = 380

        let close = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"

        let root = NSStackView(views: [
            title, sub, notifyRow!.view, axRow!.view, never, close,
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
        ])
        w.contentView = content
        window = w
    }

    func refresh() {
        Permissions.notificationsGranted { [weak self] ok in
            self?.notifyRow?.setGranted(ok)
        }
        guard Permissions.notificationsAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] s in
            let determined = s.authorizationStatus != .notDetermined
            DispatchQueue.main.async {
                self?.notifyRow?.setActionTitle(determined ? "Open Settings" : "Grant Permission")
            }
        }
        axRow?.setGranted(Permissions.accessibilityGranted)
    }

    @objc private func closeWindow() { window?.orderOut(nil) }

    // MARK: one permission row

    final class Row {
        let view = NSStackView()
        private let status = NSTextField(labelWithString: "")
        private let button: NSButton
        private let onGrant: (@escaping () -> Void) -> Void

        init(title: String, detail: String, action: String,
             onGrant: @escaping (@escaping () -> Void) -> Void)
        {
            self.onGrant = onGrant
            button = NSButton(title: action, target: nil, action: nil)
            button.bezelStyle = .rounded

            let t = NSTextField(labelWithString: title)
            t.font = .systemFont(ofSize: 13, weight: .semibold)

            let d = NSTextField(wrappingLabelWithString: detail)
            d.font = .systemFont(ofSize: 11)
            d.textColor = .secondaryLabelColor
            d.preferredMaxLayoutWidth = 370

            status.font = .systemFont(ofSize: 11)

            view.orientation = .vertical
            view.alignment = .leading
            view.spacing = 5
            view.setViews([t, d, status, button], in: .top)

            button.target = self
            button.action = #selector(tapped)
        }

        @objc private func tapped() {
            button.isEnabled = false
            onGrant { [weak self] in
                self?.button.isEnabled = true
                Permissions.shared.refresh()
            }
        }

        func setGranted(_ ok: Bool) {
            status.stringValue = ok ? "✓ Granted" : "Not granted"
            status.textColor = ok ? .systemGreen : .systemOrange
            button.isHidden = ok
        }

        /// "Grant Permission" is a lie once macOS has stopped asking. Say where the
        /// click actually goes.
        func setActionTitle(_ t: String) { button.title = t }
    }
}
