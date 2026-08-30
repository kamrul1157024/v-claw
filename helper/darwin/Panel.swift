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
    private let batteryWarn = NSTextField(wrappingLabelWithString: "")
    private let permsWarn = NSButton()

    private var modeButtons: [String: NSButton] = [:]
    private let blockLid = NSButton(checkboxWithTitle: "Block lid sleep", target: nil, action: nil)
    private let keepDisplay = NSButton(checkboxWithTitle: "Keep display on", target: nil, action: nil)
    // The warning sits on the "block lid sleep" row rather than being a setting of its
    // own. It only means anything while that option is on, and two separate checkboxes
    // invited the reading that one could be enabled without the other mattering.
    private let speaker = NSButton()
    private let warnWhy = NSTextField(wrappingLabelWithString: "")
    private let warnEvery = NSPopUpButton()

    private let everyChoices: [(String, Int)] = [
        ("Once, when it closes", 0), ("Every 15 seconds", 15),
        ("Every 30 seconds", 30), ("Every minute", 60), ("Every 5 minutes", 300),
    ]
    private let timer = NSPopUpButton()
    private let showInDock = NSButton(
        checkboxWithTitle: "Show in the Dock", target: nil, action: nil)

    private let lockEnabled = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let setPassword = NSButton(title: "Set password…", target: nil, action: nil)
    private let passwordWarn = NSTextField(wrappingLabelWithString: "")
    private let noRecovery = NSTextField(wrappingLabelWithString: "")
    private let setRecovery = NSButton(title: "Recovery code…", target: nil, action: nil)
    private let restartWarn = NSTextField(wrappingLabelWithString: "")
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
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 900),
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
        root.addArrangedSubview(dockBlock())
        root.addArrangedSubview(divider())
        root.addArrangedSubview(permsBlock())
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

        batteryWarn.font = .systemFont(ofSize: 11, weight: .medium)
        batteryWarn.textColor = .systemOrange
        batteryWarn.preferredMaxLayoutWidth = 330
        batteryWarn.isHidden = true

        let line = NSStackView(views: [statusDot, statusLabel])
        line.spacing = 8
        return column([line, tierLabel, batteryWarn, hintLabel], spacing: 4)
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
        speaker.isBordered = false
        speaker.imagePosition = .imageOnly
        speaker.target = self
        speaker.action = #selector(soundMenu)

        let lidRow = NSStackView(views: [blockLid, speaker])
        lidRow.spacing = 6
        rows.append(lidRow)
        rows.append(keepDisplay)

        warnEvery.removeAllItems()
        warnEvery.addItems(withTitles: everyChoices.map(\.0))
        warnEvery.target = self
        warnEvery.action = #selector(everyPicked)
        rows.append(labelled("Repeat the warning", warnEvery))

        warnWhy.font = .systemFont(ofSize: 10)
        warnWhy.preferredMaxLayoutWidth = 330
        rows.append(warnWhy)

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

        setRecovery.bezelStyle = .rounded
        setRecovery.target = self
        setRecovery.action = #selector(editRecovery)
        rows.append(setRecovery)

        noRecovery.font = .systemFont(ofSize: 11, weight: .medium)
        noRecovery.textColor = .systemOrange
        noRecovery.preferredMaxLayoutWidth = 330
        noRecovery.stringValue = "\u{26A0}\u{FE0E} No recovery code stored. If you forget "
            + "this password the only way back in is restarting, which ends whatever is "
            + "running. If your authenticator still lists v-claw, that entry is stale — "
            + "set one up again."
        noRecovery.isHidden = true
        rows.append(noRecovery)

        passwordWarn.font = .systemFont(ofSize: 11)
        passwordWarn.textColor = .systemOrange
        passwordWarn.preferredMaxLayoutWidth = 330
        passwordWarn.isHidden = true
        rows.append(passwordWarn)

        restartWarn.font = .systemFont(ofSize: 11)
        restartWarn.textColor = .systemRed
        restartWarn.preferredMaxLayoutWidth = 330
        restartWarn.isHidden = true
        rows.append(restartWarn)

        let clears = NSTextField(wrappingLabelWithString:
            "Cleared when you restart the Mac, so a forgotten password never locks you "
                + "out. Restarting asks for your macOS password, which is what keeps "
                + "that from being a way around the lock.")
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

    private func dockBlock() -> NSView {
        showInDock.target = self
        showInDock.action = #selector(flagToggled(_:))
        showInDock.identifier = NSUserInterfaceItemIdentifier("show_in_dock")

        let why = NSTextField(wrappingLabelWithString:
            "The menu bar can quietly run out of room — macOS hides extra icons behind "
                + "the notch without saying so. The Dock never does.")
        why.font = .systemFont(ofSize: 10)
        why.textColor = .tertiaryLabelColor
        why.preferredMaxLayoutWidth = 330

        return column([heading("Where to find v-claw"), showInDock, why], spacing: 6)
    }

    /// Warns when notifications are off.
    ///
    /// Every warning v-claw raises when nobody is looking — the timer expiring, still
    /// holding on battery — goes out as a notification. With permission denied they go
    /// nowhere, silently, and the app looks like it is working. Clicking opens the
    /// permissions window rather than making the user hunt for it.
    private func permsBlock() -> NSView {
        permsWarn.title = ""
        permsWarn.isBordered = false
        permsWarn.alignment = .left
        permsWarn.contentTintColor = .systemOrange
        permsWarn.font = .systemFont(ofSize: 11, weight: .medium)
        permsWarn.target = self
        permsWarn.action = #selector(openPermissions)
        permsWarn.isHidden = true
        return permsWarn
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

        // Awake on battery drains towards flat with nothing to stop it, and unlike the
        // AC case there is no missing adapter to notice.
        batteryWarn.isHidden = !s.onBatteryAwake
        batteryWarn.stringValue = "\u{26A0}\u{FE0E} Running on battery and staying awake. "
            + "It will not sleep, and the battery will keep draining."

        statusDot.image = dot(
            s.onBatteryAwake ? .systemOrange
                : s.holding ? .systemGreen
                : s.mode == "off" ? .systemGray
                : .systemOrange)

        modeButtons.forEach { $0.value.state = ($0.key == s.mode) ? .on : .off }
        blockLid.state = s.blockLidSleep ? .on : .off
        keepDisplay.state = s.keepDisplayOn ? .on : .off
        showInDock.state = s.showInDock ? .on : .off

        Permissions.notificationsGranted { [weak self] ok in
            guard let self else { return }
            self.permsWarn.isHidden = ok
            self.permsWarn.title = "\u{26A0}\u{FE0E} Notifications are off — v-claw cannot "
                + "warn you when it releases. Click to fix."
        }

        // The icon carries the state, so no second checkbox is needed to say it.
        let symbol = s.warnOnLidClose ? "speaker.wave.2.fill" : "speaker.slash.fill"
        speaker.image = NSImage(systemSymbolName: symbol, accessibilityDescription:
            s.warnOnLidClose ? "Lid warning on" : "Lid warning off")
        speaker.contentTintColor = s.warnOnLidClose ? .secondaryLabelColor : .systemOrange
        speaker.toolTip = s.warnOnLidClose
            ? "Sound plays when the lid closes — click to hear it or change it"
            : "No sound when the lid closes — click to turn it back on"
        speaker.isEnabled = s.blockLidSleep

        warnEvery.isEnabled = s.warnOnLidClose && s.blockLidSleep
        warnEvery.selectItem(at: everyChoices.firstIndex { $0.1 == s.lidWarnEvery } ?? 1)

        warnWhy.stringValue = s.warnOnLidClose
            ? "A sound plays when you close the lid, because a closed lid normally means "
                + "the machine is asleep and here it is not."
            : "⚠︎ No sound when you close the lid. Nothing will tell you the machine is "
                + "still running."
        warnWhy.textColor = s.warnOnLidClose ? .tertiaryLabelColor : .systemOrange

        let secs = s.expiresInSeconds ?? 0
        timer.selectItem(at: timerChoices.firstIndex { $0.1 == secs } ?? 0)

        lockEnabled.state = s.lockEnabled ? .on : .off
        policyButtons.forEach { $0.value.state = ($0.key == s.lockPolicy) ? .on : .off }
        policyButtons.values.forEach { $0.isEnabled = s.lockEnabled }
        setPassword.isHidden = s.lockPolicy != "password"
        setPassword.isEnabled = s.lockEnabled
        setPassword.title = LockPassword.isSet ? "Change password…" : "Set password…"
        setRecovery.isHidden = s.lockPolicy != "password"
        setRecovery.isEnabled = s.lockEnabled
        setRecovery.title = TOTP.isConfigured ? "Recovery code ✓" : "Set up recovery code…"

        // A password with no recovery code means the only way back in is a restart,
        // which kills every long-running task on the machine — the exact thing v-claw
        // exists to protect. Worth saying loudly, at the moment it becomes true.
        let exposed = s.lockPolicy == "password" && LockPassword.isSet && !TOTP.isConfigured
        noRecovery.isHidden = !exposed

        // Saying nothing here would let someone believe the lock is protected when a
        // restart has already cleared the password.
        let missing = s.lockPolicy == "password" && !LockPassword.isSet
        passwordWarn.isHidden = !missing
        passwordWarn.stringValue = missing
            ? "No password set — the lock will open on any key."
            : ""

        restartWarn.stringValue = s.restartAuthWarning
        restartWarn.isHidden = s.restartAuthWarning.isEmpty
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

    @objc private func everyPicked() {
        Event.send("setWarnEvery", ["seconds": everyChoices[warnEvery.indexOfSelectedItem].1])
    }

    /// Everything about the lid warning behind one control: hear it, change it, or
    /// switch it off.
    @objc private func soundMenu() {
        guard let s = state else { return }
        let menu = NSMenu()

        if s.warnOnLidClose {
            let test = NSMenuItem(title: "Play it now", action: #selector(playTest), keyEquivalent: "")
            test.target = self
            menu.addItem(test)
            menu.addItem(.separator())

            for name in ["Funk", "Basso", "Sosumi", "Submarine", "Hero", "Glass"] {
                let item = NSMenuItem(title: name, action: #selector(pickSound(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                item.state = name == s.lidWarnSound ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())

            let off = NSMenuItem(title: "Turn the warning off…", action: #selector(confirmOff), keyEquivalent: "")
            off.target = self
            menu.addItem(off)
        } else {
            let on = NSMenuItem(title: "Turn the warning back on", action: #selector(turnOn), keyEquivalent: "")
            on.target = self
            menu.addItem(on)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: speaker.bounds.height + 2), in: speaker)
    }

    @objc private func playTest() { Event.send("previewSound") }

    @objc private func pickSound(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String else { return }
        Event.send("setSound", ["sound": name])
        // Play it straight away. Picking a warning sound without hearing it is guesswork.
        Event.send("previewSound", ["sound": name])
    }

    @objc private func turnOn() {
        Event.send("setFlag", ["flag": "warn_on_lid_close", "value": true])
    }

    /// Switching the warning off removes the only signal that survives a closed lid,
    /// so it asks rather than simply obeying.
    @objc private func confirmOff() {
        guard let window else { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Turn off the lid-close warning?"
        a.informativeText = """
        Closing the lid normally means the machine goes to sleep. With v-claw holding it \
        awake that is not true, and this sound is the only thing that can tell you once \
        the screen is dark.

        Without it, a machine left in a bag keeps running and gets hot.
        """
        a.addButton(withTitle: "Keep the warning")
        a.addButton(withTitle: "Turn it off")
        a.beginSheetModal(for: window) { r in
            if r == .alertSecondButtonReturn {
                Event.send("setFlag", ["flag": "warn_on_lid_close", "value": false])
            }
        }
    }

    /// v-claw's own password, stored as a salted PBKDF2 hash in the Keychain. It never
    /// travels over the protocol, so the Go side never handles it at all.
    @objc private func editPassword() {
        guard let window else { return }

        // A plain container with explicit frames, not an NSStackView. A stack view
        // clears autoresizing on whatever it arranges, and a secure text field has no
        // intrinsic width, so inside one the fields collapse to slivers.
        let width: CGFloat = 260
        let pw = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: width, height: 24))
        pw.placeholderString = "New password"
        let confirm = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        confirm.placeholderString = "Confirm"

        let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 54))
        box.addSubview(pw)
        box.addSubview(confirm)
        pw.nextKeyView = confirm
        confirm.nextKeyView = pw

        let alert = NSAlert()
        alert.messageText = "v-claw lock password"
        alert.informativeText = """
        Used only for the virtual lock. This is not your macOS password.

        It is cleared when you restart the Mac, so a forgotten password never locks you \
        out. You will need to set it again after each restart.
        """
        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if LockPassword.isSet { alert.addButton(withTitle: "Remove") }
        alert.window.initialFirstResponder = pw

        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                guard !pw.stringValue.isEmpty else {
                    return self.warn("The password cannot be empty.")
                }
                guard pw.stringValue == confirm.stringValue else {
                    return self.warn("Those did not match.")
                }
                guard LockPassword.set(pw.stringValue) else {
                    return self.warn("Could not save the password.")
                }
                self.setPassword.title = "Change password…"
                if !TOTP.isConfigured { self.offerRecovery() }
            case .alertThirdButtonReturn:
                LockPassword.clear()
                self.setPassword.title = "Set password…"
                Event.send("setLock", ["policy": "none"])
            default:
                break
            }
        }
    }

    /// Enrols an authenticator app, so a forgotten password does not cost a restart.
    ///
    /// Restarting is the other way back in, and it throws away every long-running task
    /// on a machine that is being kept awake precisely to run them. A code from a phone
    /// costs nothing.
    @objc private func editRecovery() {
        guard let window else { return }

        if TOTP.isConfigured {
            let a = NSAlert()
            a.messageText = "Recovery code is set up"
            a.informativeText = "Your authenticator can unlock the virtual lock. "
                + "Removing it leaves a restart as the only way back in."
            a.addButton(withTitle: "Keep")
            a.addButton(withTitle: "Remove")
            a.beginSheetModal(for: window) { r in
                if r == .alertSecondButtonReturn {
                    TOTP.forget()
                    self.setRecovery.title = "Set up recovery code…"
                }
            }
            return
        }

        guard let secret = TOTP.generate() else {
            return warn("Could not create a recovery secret.")
        }
        showEnrolment(secret: secret, error: nil)
    }

    /// Shows the QR and demands a working code before anything is written to disk.
    ///
    /// On a wrong code this reopens with the *same* secret, so the user never has to
    /// rescan. Nothing is stored until a code verifies, which means a scan that
    /// silently failed is caught here rather than at a lock screen.
    private func showEnrolment(secret: String, error: String?) {
        guard let window else { return }

        let uri = TOTP.uri(secret: secret, account: NSFullUserName())

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 320))
        if let cg = TOTP.qr(for: uri) {
            let iv = NSImageView(frame: NSRect(x: 50, y: 118, width: 200, height: 200))
            iv.image = NSImage(cgImage: cg, size: NSSize(width: 200, height: 200))
            box.addSubview(iv)
        }

        // Shown as well as the QR: a phone cannot scan the screen it is unlocking, and
        // some people prefer to paste it into a password manager.
        let code = NSTextField(labelWithString: secret)
        code.frame = NSRect(x: 0, y: 92, width: 300, height: 18)
        code.alignment = .center
        code.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        code.isSelectable = true
        box.addSubview(code)

        let prompt = NSTextField(labelWithString: "Enter the current code to confirm")
        prompt.frame = NSRect(x: 0, y: 66, width: 300, height: 18)
        prompt.alignment = .center
        prompt.font = .systemFont(ofSize: 11)
        prompt.textColor = .secondaryLabelColor
        box.addSubview(prompt)

        let entry = NSTextField(frame: NSRect(x: 90, y: 34, width: 120, height: 26))
        entry.alignment = .center
        entry.font = .monospacedDigitSystemFont(ofSize: 16, weight: .regular)
        entry.placeholderString = "000000"
        box.addSubview(entry)

        if let error {
            let e = NSTextField(labelWithString: error)
            e.frame = NSRect(x: 0, y: 10, width: 300, height: 18)
            e.alignment = .center
            e.font = .systemFont(ofSize: 11)
            e.textColor = .systemRed
            box.addSubview(e)
        }

        let alert = NSAlert()
        alert.messageText = "Recovery code"
        alert.informativeText = "Scan with any authenticator app, then type the code it "
            + "shows. Nothing is saved until a code works, so a failed scan cannot leave "
            + "you locked out later. Nothing leaves this Mac."
        alert.accessoryView = box
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = entry

        alert.beginSheetModal(for: window) { r in
            guard r == .alertFirstButtonReturn else { return }

            let typed = entry.stringValue
            guard TOTP.matches(typed, secret: secret) else {
                let why = typed.filter(\.isNumber).count == 6
                    ? "That code did not match. Check your phone's clock and try the next one."
                    : "Enter the six digits your authenticator shows."
                // Reopen with the same secret so the QR does not have to be rescanned.
                DispatchQueue.main.async { self.showEnrolment(secret: secret, error: why) }
                return
            }

            guard TOTP.commit(secret, confirmedWith: typed) else {
                return self.warn("Could not save the recovery secret.")
            }
            self.setRecovery.title = "Recovery code ✓"
        }
    }

    /// Asked straight after a password is set, while the consequence is still in mind.
    ///
    /// Without a recovery code the only way past a forgotten password is a restart, and
    /// a restart throws away every long-running task — which is the whole reason the
    /// machine is being kept awake. Better to raise it here than to leave someone to
    /// discover it while locked out.
    private func offerRecovery() {
        guard let window else { return }
        let a = NSAlert()
        a.messageText = "Set up a recovery code?"
        a.informativeText = """
        If you forget this password, the only way back in is restarting the Mac — and \
        that ends everything running on it.

        A code from your phone gets you back in without losing anything. It takes about \
        thirty seconds to set up.
        """
        a.addButton(withTitle: "Set one up")
        a.addButton(withTitle: "Not now")
        a.beginSheetModal(for: window) { r in
            if r == .alertFirstButtonReturn {
                DispatchQueue.main.async { self.editRecovery() }
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
