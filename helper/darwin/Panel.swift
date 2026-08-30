// The main window.
//
// v-claw started as a menu bar app, but a menu bar is not always available: on a
// notched Mac with a dozen status items, macOS silently drops new ones into the hidden
// region behind the notch and gives no indication. A window means the app is always
// reachable.
import AppKit

final class Panel: NSObject, NSWindowDelegate {
    static let shared = Panel()

    private var window: NSWindow?
    private var state: UIState?

    private let statusDot = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let tierLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")

    private var modeButtons: [String: NSButton] = [:]
    private let blockLid = NSButton(checkboxWithTitle: "Block lid sleep", target: nil, action: nil)
    private let keepDisplay = NSButton(checkboxWithTitle: "Keep display on", target: nil, action: nil)
    private let timer = NSPopUpButton()

    private let lockEnabled = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let setPassword = NSButton(title: "Set password…", target: nil, action: nil)
    private let passwordWarn = NSTextField(wrappingLabelWithString: "")
    private var policyButtons: [String: NSButton] = [:]
    private let idle = NSPopUpButton()

    private let timerChoices: [(String, Int)] = [
        ("No timer", 0), ("15 minutes", 900), ("1 hour", 3600), ("4 hours", 14400),
    ]
    private let idleChoices: [(String, Int)] = [
        ("Never", 0), ("After 5 minutes", 5), ("After 15 minutes", 15),
    ]

    func show(_ s: UIState) {
        state = s
        if window == nil { build() }
        render(s)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(_ s: UIState) {
        state = s
        guard window != nil else { return }
        render(s)
    }

    func close() {
        window?.orderOut(nil)
    }

    // MARK: build

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 720),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = "v-claw"
        w.delegate = self
        w.isReleasedWhenClosed = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(statusBlock())
        root.addArrangedSubview(divider())
        root.addArrangedSubview(modeBlock())
        root.addArrangedSubview(divider())
        root.addArrangedSubview(lockBlock())
        root.addArrangedSubview(divider())
        root.addArrangedSubview(footer())

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

    private func statusBlock() -> NSView {
        statusDot.image = NSImage(size: NSSize(width: 12, height: 12))
        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        tierLabel.font = .systemFont(ofSize: 12)
        tierLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .systemOrange
        hintLabel.preferredMaxLayoutWidth = 330

        let line = NSStackView(views: [statusDot, statusLabel])
        line.spacing = 8
        return column([line, tierLabel, hintLabel], spacing: 4)
    }

    private func modeBlock() -> NSView {
        var rows: [NSView] = [heading("Keep awake")]

        for (key, title, sub) in [
            ("off", "Off", "Change nothing"),
            ("always", "Always awake", "On battery too"),
            ("auto", "Auto", "Only while on the power adapter"),
        ] {
            let b = NSButton(radioButtonWithTitle: title, target: self, action: #selector(modePicked(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(key)
            modeButtons[key] = b
            let s = NSTextField(labelWithString: sub)
            s.font = .systemFont(ofSize: 11)
            s.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [b, s])
            stack.spacing = 6
            rows.append(stack)
        }

        blockLid.target = self
        blockLid.action = #selector(flagToggled(_:))
        blockLid.identifier = NSUserInterfaceItemIdentifier("block_lid_sleep")
        keepDisplay.target = self
        keepDisplay.action = #selector(flagToggled(_:))
        keepDisplay.identifier = NSUserInterfaceItemIdentifier("keep_display_on")
        rows.append(blockLid)
        rows.append(keepDisplay)

        timer.removeAllItems()
        timer.addItems(withTitles: timerChoices.map(\.0))
        timer.target = self
        timer.action = #selector(timerPicked)
        rows.append(labelled("Release after", timer))

        return column(rows, spacing: 8)
    }

    private func lockBlock() -> NSView {
        var rows: [NSView] = [heading("Virtual lock")]

        let warn = NSTextField(wrappingLabelWithString:
            "A privacy screen, not a security boundary. It hides your screen while keeping the machine awake.")
        warn.font = .systemFont(ofSize: 11)
        warn.textColor = .secondaryLabelColor
        warn.preferredMaxLayoutWidth = 330
        rows.append(warn)

        lockEnabled.target = self
        lockEnabled.action = #selector(lockToggled)
        rows.append(lockEnabled)

        for (key, title) in [
            ("none", "Any key unlocks"),
            ("password", "v-claw password"),
        ] {
            let b = NSButton(radioButtonWithTitle: title, target: self, action: #selector(policyPicked(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(key)
            policyButtons[key] = b
            rows.append(b)
        }

        setPassword.bezelStyle = .rounded
        setPassword.target = self
        setPassword.action = #selector(editPassword)
        rows.append(setPassword)

        passwordWarn.font = .systemFont(ofSize: 11)
        passwordWarn.textColor = .systemOrange
        passwordWarn.preferredMaxLayoutWidth = 330
        passwordWarn.isHidden = true
        rows.append(passwordWarn)

        let clears = NSTextField(wrappingLabelWithString:
            "Cleared when you restart the Mac, so a forgotten password never locks you out.")
        clears.font = .systemFont(ofSize: 10)
        clears.textColor = .tertiaryLabelColor
        clears.preferredMaxLayoutWidth = 330
        rows.append(clears)


        idle.removeAllItems()
        idle.addItems(withTitles: idleChoices.map(\.0))
        idle.target = self
        idle.action = #selector(idlePicked)
        rows.append(labelled("Lock when idle", idle))

        let now = NSButton(title: "Lock screen now", target: self, action: #selector(lockNow))
        now.bezelStyle = .rounded
        rows.append(now)

        return column(rows, spacing: 8)
    }

    private func footer() -> NSView {
        let perms = NSButton(title: "Permissions…", target: self, action: #selector(openPermissions))
        let diag = NSButton(title: "Diagnostics…", target: self, action: #selector(openDiagnostics))
        let quit = NSButton(title: "Quit v-claw", target: self, action: #selector(quit))
        [perms, diag, quit].forEach { $0.bezelStyle = .rounded }
        let row = NSStackView(views: [perms, diag, quit])
        row.spacing = 8
        return row
    }

    // MARK: render

    private func render(_ s: UIState) {
        statusLabel.stringValue = s.statusLine
        tierLabel.stringValue = s.holding
            ? "Holding the machine awake · \(s.tier)"
            : (s.mode == "off" ? "Not active" : "Armed, waiting for the power adapter")

        hintLabel.stringValue = s.lidHint
        hintLabel.isHidden = s.lidHint.isEmpty

        statusDot.image = dot(s.holding ? .systemGreen : (s.mode == "off" ? .systemGray : .systemOrange))

        modeButtons.forEach { $0.value.state = ($0.key == s.mode) ? .on : .off }
        blockLid.state = s.blockLidSleep ? .on : .off
        keepDisplay.state = s.keepDisplayOn ? .on : .off

        let secs = s.expiresInSeconds ?? 0
        timer.selectItem(at: timerChoices.firstIndex { $0.1 == secs } ?? 0)

        lockEnabled.state = s.lockEnabled ? .on : .off
        policyButtons.forEach { $0.value.state = ($0.key == s.lockPolicy) ? .on : .off }
        policyButtons.values.forEach { $0.isEnabled = s.lockEnabled }
        setPassword.isHidden = s.lockPolicy != "password"
        setPassword.isEnabled = s.lockEnabled
        setPassword.title = LockPassword.isSet ? "Change password…" : "Set password…"

        // Saying nothing here would let someone believe the lock is protected when a
        // restart has already cleared the password.
        let missing = s.lockPolicy == "password" && !LockPassword.isSet
        passwordWarn.isHidden = !missing
        passwordWarn.stringValue = missing
            ? "No password set — the lock will open on any key."
            : ""
        idle.isEnabled = s.lockEnabled
        idle.selectItem(at: idleChoices.firstIndex { $0.1 == s.lockIdleMinutes } ?? 0)
    }

    // MARK: actions

    @objc private func modePicked(_ b: NSButton) {
        Event.send("setMode", ["mode": b.identifier?.rawValue ?? "auto"])
    }

    @objc private func flagToggled(_ b: NSButton) {
        Event.send("setFlag", ["flag": b.identifier?.rawValue ?? "", "value": b.state == .on])
    }

    @objc private func timerPicked() {
        Event.send("setTimer", ["seconds": timerChoices[timer.indexOfSelectedItem].1])
    }

    @objc private func lockToggled() {
        Event.send("setLock", ["enabled": lockEnabled.state == .on])
    }

    @objc private func policyPicked(_ b: NSButton) {
        Event.send("setLock", ["policy": b.identifier?.rawValue ?? "none"])
    }

    @objc private func idlePicked() {
        Event.send("setLock", ["idleMinutes": idleChoices[idle.indexOfSelectedItem].1])
    }

    @objc private func lockNow() { Event.send("lockNow") }

    /// v-claw's own password, stored as a salted PBKDF2 hash in the Keychain. It never
    /// travels over the protocol, so the Go side never handles it at all.
    @objc private func editPassword() {
        guard let window else { return }

        let pw = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pw.placeholderString = "New password"
        let confirm = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        confirm.placeholderString = "Confirm"

        let stack = NSStackView(views: [pw, confirm])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 56)

        let alert = NSAlert()
        alert.messageText = "v-claw lock password"
        alert.informativeText = """
        Used only for the virtual lock. This is not your macOS password.

        Forgetting it locks nothing away: quitting v-claw removes the lock, because it         is a window, not a security boundary.
        """
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if LockPassword.isSet { alert.addButton(withTitle: "Remove") }

        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                guard !pw.stringValue.isEmpty else {
                    return self.warn("The password cannot be empty.")
                }
                guard pw.stringValue == confirm.stringValue else {
                    return self.warn("Those did not match.")
                }
                if LockPassword.set(pw.stringValue) {
                    self.setPassword.title = "Change password…"
                } else {
                    self.warn("Could not save to the Keychain.")
                }
            case .alertThirdButtonReturn:
                LockPassword.clear()
                self.setPassword.title = "Set password…"
                Event.send("setLock", ["policy": "none"])
            default:
                break
            }
        }
    }

    private func warn(_ text: String) {
        guard let window else { return }
        let a = NSAlert()
        a.messageText = text
        a.alertStyle = .warning
        a.beginSheetModal(for: window, completionHandler: nil)
    }
    @objc private func openPermissions() { Permissions.shared.show(state?.hotkeyEnabled ?? false) }
    @objc private func openDiagnostics() { Event.send("diagnose") }
    @objc private func quit() { Event.send("quit") }

    func windowWillClose(_ notification: Notification) {
        Event.send("windowClosed")
    }

    // MARK: helpers

    private func heading(_ t: String) -> NSTextField {
        let f = NSTextField(labelWithString: t)
        f.font = .systemFont(ofSize: 12, weight: .semibold)
        f.textColor = .secondaryLabelColor
        return f
    }

    private func labelled(_ t: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 12)
        let s = NSStackView(views: [l, control])
        s.spacing = 8
        return s
    }

    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    private func divider() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 340).isActive = true
        return v
    }

    private func dot(_ colour: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let img = NSImage(size: size)
        img.lockFocus()
        colour.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        img.unlockFocus()
        return img
    }
}
