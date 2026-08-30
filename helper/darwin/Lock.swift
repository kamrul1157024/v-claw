// The virtual lock screen.
//
// It is a privacy screen, NOT a security boundary. It is an ordinary window drawn by an
// ordinary user process, and anyone with physical access defeats it. It exists so you
// can step away without letting the machine sleep, which the real macOS lock cannot do
// because that lock is tied to display sleep.
import AppKit

final class LockView: NSView {
    private let clock = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let field = NSSecureTextField()
    private let error = NSTextField(labelWithString: "")
    private let recovery = NSTextField(labelWithString: "")
    private let unlock = NSButton()
    private var timer: Timer?
    private let wantsPassword: Bool

    init(frame: NSRect, message: String, unlockTitle: String, wantsPassword: Bool) {
        self.wantsPassword = wantsPassword
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        // Dim rather than allow display sleep. The awake assertions must keep holding,
        // so the display cannot be permitted to sleep; darkness is the trade.
        style(clock, size: 76, weight: .thin, alpha: 0.92)
        style(date, size: 17, weight: .regular, alpha: 0.55)
        style(status, size: 14, weight: .medium, alpha: 0.45)

        status.stringValue = message

        // An explicit control rather than a line of instructions. Telling the user
        // which credential to present is noise: the system prompt says that already,
        // and on a shared screen it needlessly advertises how the machine unlocks.
        unlock.title = unlockTitle
        unlock.bezelStyle = .rounded
        unlock.controlSize = .large
        unlock.font = .systemFont(ofSize: 13, weight: .medium)
        unlock.target = self
        unlock.action = #selector(unlockTapped)

        field.placeholderString = TOTP.isConfigured
            ? "Password or 6-digit code"
            : "v-claw password"
        field.alignment = .center
        field.font = .systemFont(ofSize: 14)
        field.target = self
        field.action = #selector(unlockTapped)
        field.isHidden = !wantsPassword
        field.setFrameSize(NSSize(width: 240, height: 26))

        style(error, size: 12, weight: .regular, alpha: 0.9)
        error.textColor = .systemRed
        error.isHidden = true

        // Always on screen for a password lock, never only after N failures. Someone
        // who cannot type at all never reaches a failure count, and they are exactly
        // the person who needs to know the way out.
        style(recovery, size: 11, weight: .regular, alpha: 0.30)
        recovery.stringValue = TOTP.isConfigured
            ? "Enter a code from your authenticator, or restart the Mac"
            : "Restart the Mac to clear this password"
        recovery.isHidden = !wantsPassword

        [clock, date, status, field, error, unlock, recovery].forEach(addSubview)

        tick()
        // Honour Reduce Motion: this only updates text, never animates.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    required init?(coder: NSCoder) { nil }
    deinit { timer?.invalidate() }

    private func style(_ f: NSTextField, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
        f.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        f.textColor = NSColor.white.withAlphaComponent(alpha)
        f.alignment = .center
        f.isBezeled = false
        f.drawsBackground = false
    }

    private func tick() {
        let now = Date()
        let t = DateFormatter(); t.dateFormat = "HH:mm"
        let d = DateFormatter(); d.dateFormat = "EEEE d MMMM"
        clock.stringValue = t.string(from: now)
        date.stringValue = d.string(from: now)
        layoutStack()
    }

    @objc private func unlockTapped() { Lock.shared.attemptUnlock(password: field.stringValue) }

    /// Changes the status line without disturbing anything the user has typed.
    func setMessage(_ text: String) {
        status.stringValue = text
        layoutStack()
    }

    /// Called when the password was wrong. Clears the field rather than leaving a bad
    /// value in place, and keeps focus so retrying needs no extra click.
    func reject(_ text: String) {
        error.stringValue = text
        error.isHidden = false
        field.stringValue = ""
        window?.makeFirstResponder(field)
        layoutStack()
    }

    func focusField() {
        guard wantsPassword else { return }
        window?.makeFirstResponder(field)
    }

    var typed: String { field.stringValue }

    func restore(_ text: String) {
        field.stringValue = text
        focusField()
    }

    private func layoutStack() {
        var fields: [NSView] = [clock, date, status]
        if wantsPassword { fields.append(field) }
        if !error.isHidden { fields.append(error) }
        fields.append(unlock)
        if wantsPassword { fields.append(recovery) }

        for f in fields where f !== field {
            (f as? NSControl)?.sizeToFit()
        }
        let gaps = [CGFloat](repeating: 14, count: max(0, fields.count - 1))
        let total = fields.reduce(0) { $0 + $1.frame.height } + gaps.reduce(0, +)

        var y = (bounds.height + total) / 2
        for (i, f) in fields.enumerated() {
            y -= f.frame.height
            f.frame.origin = NSPoint(x: (bounds.width - f.frame.width) / 2, y: y)
            if i < gaps.count { y -= gaps[i] }
        }
    }

    override var acceptsFirstResponder: Bool { !wantsPassword }

    override func keyDown(with event: NSEvent) {
        // With a password set, keystrokes belong to the field, never to dismissal.
        guard !wantsPassword else { return }
        Lock.shared.attemptUnlock(password: "")
    }

    override func mouseDown(with event: NSEvent) {
        guard !wantsPassword else {
            window?.makeFirstResponder(field)
            return
        }
        Lock.shared.attemptUnlock(password: "")
    }
}

/// A borderless NSWindow returns false from canBecomeKey, so it never becomes the key
/// window and its text field never receives a single keystroke. That made the password
/// lock impossible to unlock from the keyboard: the screen was covered, the field was
/// visible, and typing did nothing.
///
/// This is the trap the whole design is supposed to make impossible, so the override is
/// not optional and the guard in cover() checks it actually took effect.
final class LockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class Lock: NSObject {
    static let shared = Lock()

    private var windows: [NSWindow] = []
    private var policy = "none"
    private var message = ""
    private var authFailures = 0

    func engage(policy: String, message: String) {
        guard windows.isEmpty else { return }
        self.policy = policy
        self.message = message

        NSApp.presentationOptions = [
            .disableProcessSwitching, .disableForceQuit, .disableSessionTermination,
            .disableHideApplication, .hideDock, .hideMenuBar,
        ]

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        guard cover() else {
            // A partial cover is worse than none: it looks locked while leaving a
            // screen readable. Refuse rather than mislead.
            Event.send("error", ["message": "could not cover every display"])
            finish()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        reportInputState()
    }

    /// Reports, once, whether the lock actually took keyboard focus.
    ///
    /// Log only. It changes nothing, because there is no escape valve by design: a
    /// valve that fires when "something went wrong" is a valve an attacker can provoke.
    /// But with no valve, evidence matters — if a lock ever swallows keystrokes again,
    /// this leaves a record instead of a mystery.
    private func reportInputState() {
        guard policy == "password", LockPassword.isSet else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let w = self?.windows.first else { return }
            Event.send("lockInput", ["keyWindow": w.isKeyWindow, "canBecomeKey": w.canBecomeKey])
        }
    }

    @discardableResult
    private func cover() -> Bool {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()

        // The button never names a credential. Saying "Touch ID" on a screen you have
        // walked away from advertises how the machine unlocks, and the system prompt
        // says it anyway.
        let unlockTitle = "Unlock"
        let wantsPassword = policy == "password" && LockPassword.isSet

        for screen in NSScreen.screens {
            let w = LockWindow(contentRect: screen.frame, styleMask: .borderless,
                               backing: .buffered, defer: false, screen: screen)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            w.isOpaque = true
            w.backgroundColor = .black
            w.ignoresMouseEvents = false
            w.contentView = LockView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                     message: message, unlockTitle: unlockTitle,
                                     wantsPassword: wantsPassword)
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }

        guard windows.count == NSScreen.screens.count, !windows.isEmpty else { return false }

        let first = windows.first
        first?.makeKeyAndOrderFront(nil)
        first?.makeFirstResponder(first?.contentView)
        (first?.contentView as? LockView)?.focusField()

        // Refuse to lock behind a password the user cannot type. This is the only
        // safety measure here, and it deliberately runs *before* the lock exists
        // rather than after: declining to create a broken lock is not a bypass, while
        // anything that opens an active one is. There is no escape valve once locked —
        // a valve that fires on "something went wrong" is a valve an attacker can
        // provoke. Recovery is a restart, which macOS authenticates.
        //
        // Test canBecomeKey, not isKeyWindow: activation is asynchronous, so the window
        // is legitimately not yet key at this point and checking that would reject
        // every password lock.
        if wantsPassword, let w = first, !w.canBecomeKey {
            Event.send("error", ["message": "the lock window cannot take keyboard input; refusing to lock"])
            return false
        }
        return true
    }

    // A display plugged in while locked must be covered at once. An uncovered second
    // screen defeats the entire feature. Carry any typed text across the rebuild:
    // losing it here would be the same bug updateMessage used to cause.
    @objc private func screensChanged() {
        let typed = (windows.first?.contentView as? LockView)?.typed ?? ""
        cover()
        if !typed.isEmpty {
            (windows.first?.contentView as? LockView)?.restore(typed)
        }
    }

    func attemptUnlock(password: String) {
        guard policy == "password" else { return finish() }
        attemptPassword(password)
    }

    /// v-claw's own password, never the macOS account password. See LockPassword.
    private func attemptPassword(_ attempt: String) {
        // With no password configured the lock cannot be a password lock. Fail open
        // rather than trap the user behind a credential that does not exist.
        guard LockPassword.isSet else { return finish() }
        guard !attempt.isEmpty else { return }

        if LockPassword.verify(attempt) {
            return finish()
        }

        // A code from the authenticator also gets you in. It is a second credential
        // rather than an escape valve: it needs the phone holding the seed, and each
        // code lasts about a minute. It exists because the other way out is a restart,
        // and a restart destroys the long-running work this machine is being kept
        // awake for in the first place.
        if TOTP.isConfigured, TOTP.verify(attempt) {
            Event.send("error", ["message": "unlocked with a recovery code"])
            return finish()
        }

        authFailures += 1

        // No auto-unlock after N failures. An earlier version did that as a safety
        // valve and it was simply a bypass: anyone could fail three times on purpose
        // and walk in. Tell the user how to get out instead of opening the door.
        // The way out is on screen permanently, so this only has to report the failure.
        let msg = TOTP.isConfigured ? "Incorrect password or code" : "Incorrect password"
        windows.forEach { ($0.contentView as? LockView)?.reject(msg) }

        // A wrong password must cost something, or the lock is brute-forced by holding
        // a key down. PBKDF2 already makes each attempt slow; this makes repeated ones
        // slower. It stays short because a genuine typo must not be punished, and
        // because this was never a security boundary.
        let delay = min(Double(authFailures) * 0.5, 3.0)
        windows.forEach { $0.contentView?.isHidden = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            (self?.windows.first?.contentView as? LockView)?.focusField()
        }
    }

    private func finish() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSApp.presentationOptions = []
        authFailures = 0
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        Event.send("unlocked")
    }

    /// Lets the Go side drop the lock, for an expiring timer or a shutdown. The lock
    /// must always have a way out that does not depend on the user.
    func forceUnlock() {
        guard !windows.isEmpty else { return }
        finish()
    }

    /// Keeps the status line current while the screen stays locked.
    ///
    /// Updates the label in place. It used to call cover(), which tears down every
    /// window and rebuilds the views — wiping whatever the user was halfway through
    /// typing. The app pushes state every five seconds, so any status change during
    /// entry silently cleared the field and submitted a fragment. That is why the
    /// first code so often failed and the second worked.
    func updateMessage(_ text: String) {
        guard !windows.isEmpty, text != message else { return }
        message = text
        windows.forEach { ($0.contentView as? LockView)?.setMessage(text) }
    }
}
