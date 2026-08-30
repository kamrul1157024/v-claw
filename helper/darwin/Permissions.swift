// The permissions window.
//
// v-claw asks for very little, and saying so plainly is worth a window of its own.
// On a managed Mac running EDR, an app that states which permissions it will never
// request is easier to trust and easier to get approved.
//
// Needed:      nothing.
// Optional:    Accessibility, and only for the global lock hotkey.
// Never asked: Notifications, Screen Recording, Input Monitoring, Full Disk Access,
//              Camera, Microphone.
//
// Notifications were tried and removed. macOS will not grant them to a bundle compiled
// from source and ad-hoc signed; it refuses silently and leaves the status reading
// notDetermined, so the app could neither deliver a warning nor explain why. Warnings
// are drawn on screen instead — see Banner.swift — which needs no permission and cannot
// be switched off by accident.
//
// Idle detection deliberately uses CGEventSourceSecondsSinceLastEventType, which needs
// no permission, rather than an event tap, which needs Accessibility and looks like a
// keylogger to a reviewer.
import AppKit

final class Permissions: NSObject {
    static let shared = Permissions()

    private var window: NSWindow?
    private var axRow: Row?

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
           •  Notifications           warnings are drawn on screen instead
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
            title, sub, axRow!.view, never, close,
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
        // Once the system has refused, stop offering to ask. A button that cannot
        // succeed is worse than no button: it reads as a broken app rather than a
        // platform restriction, and it invites the user to keep trying.
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

        /// Nothing to grant and nowhere to go. Explain instead of offering.
        func setUnavailable(_ why: String) {
            status.stringValue = why
            status.textColor = .secondaryLabelColor
            status.lineBreakMode = .byWordWrapping
            status.preferredMaxLayoutWidth = 370
            button.isHidden = true
        }
    }
}
