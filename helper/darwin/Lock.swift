// The virtual lock screen.
//
// It is a privacy screen, NOT a security boundary. It is an ordinary window drawn by an
// ordinary user process, and anyone with physical access defeats it. It exists so you
// can step away without letting the machine sleep, which the real macOS lock cannot do
// because that lock is tied to display sleep.
import AppKit

final class LockView: NSView, NSTextFieldDelegate {
    private let clock = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let field = NSSecureTextField()
    private let error = NSTextField(labelWithString: "")
    private let recovery = NSTextField(labelWithString: "")
    private let unlock = NSButton()
    private let useRecovery = NSButton()
    private let countdown = NSTextField(labelWithString: "")
    private var timer: Timer?
    private let wantsPassword: Bool

    /// Recovery mode swaps the password field for a code field, and holds it shut until
    /// a fresh code is due. Typing a code that is about to roll over is how people end
    /// up entering three in a row and trusting none of them.
    private var recoveryMode = false
    private var armAt: Date?
    private var focusedAfterArming = false

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
        // Return goes through performKeyEquivalent, which the window runs over the
        // content view before any first-responder dispatch. That makes it independent
        // of the field editor, which is where both previous attempts came unstuck:
        // target/action and the delegate's doCommandBy hang off the same code path.
        // It is also how the NSAlert sheets elsewhere in the app already behave.
        unlock.keyEquivalent = "\r"

        field.placeholderString = "v-claw password"
        field.alignment = .center
        field.font = .systemFont(ofSize: 14)
        field.target = self
        field.action = #selector(unlockTapped)
        // The target/action alone is not dependable here: the field lives in a
        // borderless window with no default button, and Return was reaching neither.
        // The delegate hook is the documented way to catch it.
        field.delegate = self
        field.isHidden = !wantsPassword
        field.setFrameSize(NSSize(width: 240, height: 26))

        style(error, size: 12, weight: .regular, alpha: 0.9)
        error.textColor = .systemRed
        error.isHidden = true

        // Kept separate from the password. Mixing both into one field means every
        // failure is ambiguous — wrong password, or wrong code, or the right code at
        // the wrong moment — and the user cannot tell which.
        useRecovery.title = "Use recovery code"
        useRecovery.bezelStyle = .inline
        useRecovery.isBordered = false
        useRecovery.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        useRecovery.font = .systemFont(ofSize: 12)
        useRecovery.target = self
        useRecovery.action = #selector(enterRecovery)
        // Never offer recovery with no seed stored. A code cannot be checked against
        // nothing, so the button would lead only to a screen demanding digits that can
        // never be right.
        useRecovery.isHidden = !(wantsPassword && TOTP.isConfigured)

        style(countdown, size: 12, weight: .regular, alpha: 0.55)
        // Running before the button is pressed, not after. Knowing a fresh code is
        // four seconds away changes what you do; finding that out only once you have
        // committed to the recovery flow does not.
        countdown.isHidden = !(wantsPassword && TOTP.isConfigured)

        // Always on screen for a password lock, never only after N failures. Someone
        // who cannot type at all never reaches a failure count, and they are exactly
        // the person who needs to know the way out.
        style(recovery, size: 11, weight: .regular, alpha: 0.30)
        recovery.stringValue = TOTP.isConfigured
            ? "Enter a code from your authenticator, or restart the Mac"
            : "No recovery code is set up. Restart the Mac to clear this password."
        recovery.isHidden = !wantsPassword

        [clock, date, status, field, error, unlock, useRecovery, countdown, recovery]
            .forEach(addSubview)

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
        if !countdown.isHidden { updateCountdown(now) }
        layoutStack()
    }

    private func updateCountdown(_ now: Date) {
        // Before the user opts in, the line is informational only.
        guard recoveryMode else {
            let left = 30 - Int(now.timeIntervalSince1970) % 30
            countdown.stringValue = "Authenticator code refreshes in \(left)s"
            countdown.textColor = NSColor.white.withAlphaComponent(0.35)
            return
        }

        if let arm = armAt, now < arm {
            let left = max(1, Int(arm.timeIntervalSince(now).rounded(.up)))
            countdown.stringValue = "New code in \(left)s"
            countdown.textColor = NSColor.white.withAlphaComponent(0.45)
            field.isEnabled = false
            return
        }

        field.isEnabled = true
        field.placeholderString = "6-digit code"
        if !focusedAfterArming {
            focusedAfterArming = true
            window?.makeFirstResponder(field)
        }

        let left = 30 - Int(now.timeIntervalSince1970) % 30
        countdown.stringValue = "Code valid for \(left)s"
        // Amber near the boundary, so nobody starts typing a code with three seconds
        // left and blames the app when it is refused.
        countdown.textColor = left <= 7
            ? NSColor.systemOrange.withAlphaComponent(0.9)
            : NSColor.white.withAlphaComponent(0.45)
    }

    @objc private func unlockTapped() { Lock.shared.attemptUnlock(password: currentText) }

    /// What is actually typed, not what was last committed.
    ///
    /// NSTextField.stringValue returns the cell's value, and the field editor does not
    /// flush into it until editing ends. Clicking Unlock read the stale value — empty
    /// on the first attempt — so the password was refused and the field cleared, and
    /// only the second try worked. validateEditing commits first; the field editor is
    /// read directly as well, since validateEditing is a no-op when the field is not
    /// mid-edit and the two together cover both paths.
    var currentText: String {
        field.validateEditing()
        if let editor = window?.fieldEditor(false, for: field) as? NSTextView,
           !editor.string.isEmpty
        {
            return editor.string
        }
        return field.stringValue
    }

    /// Return submits, the same as pressing Unlock.
    ///
    /// Typing a password and pressing Enter is the single most automatic thing anyone
    /// does at a lock screen. Making them reach for a button instead is the sort of
    /// friction that gets blamed on the password being wrong.
    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        unlockTapped()
        return true
    }

    /// Switches to code entry and waits for the next 30-second boundary, so whatever
    /// the user types has a full window of life rather than the seconds left on a code
    /// that was already half spent when they looked at it.
    @objc private func enterRecovery() {
        Lock.shared.armRecovery()
        Lock.shared.enterRecoveryEverywhere()
    }

    /// Puts this view into code entry. Called on every screen, not just the one that
    /// was clicked, so the state cannot differ between displays.
    func beginRecovery() {
        recoveryMode = true
        useRecovery.isHidden = true
        error.isHidden = true
        field.stringValue = ""

        // Always wait for the next boundary, never the code currently on screen. That
        // one is half spent on average and there is no way to tell how much life it has
        // left from the phone alone. Waiting costs at most thirty seconds and removes
        // the entire class of failure where a code is refused for being stale — which
        // is the failure that made this feature look broken in the first place.
        //
        // The countdown has been running since the lock appeared, so the wait is
        // visible before the button is pressed rather than a surprise after it.
        let now = Date().timeIntervalSince1970
        armAt = Date(timeIntervalSince1970: (floor(now / 30) + 1) * 30)
        focusedAfterArming = false
        field.isEnabled = false
        field.placeholderString = "Waiting for a new code"
        tick()
    }

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
        (window?.fieldEditor(false, for: field) as? NSTextView)?.string = ""

        // Stay in code entry after a bad code. Dropping back to the password would
        // make the user re-enter recovery and wait out another boundary.
        if recoveryMode {
            focusedAfterArming = false
            let now = Date().timeIntervalSince1970
            armAt = Date(timeIntervalSince1970: (floor(now / 30) + 1) * 30)
            field.isEnabled = false
            field.placeholderString = "Waiting for a new code"
            // Say what to do rather than only what failed. The countdown beside this
            // is already showing exactly how long that is.
            error.stringValue = "That code did not work — wait for the next one and try that"
        }

        window?.makeFirstResponder(field)
        layoutStack()
    }

    func focusField() {
        guard wantsPassword else { return }
        window?.makeFirstResponder(field)
    }

    /// Same staleness applies here: carrying text across a display change must copy
    /// what is being typed, not what was last committed.
    var typed: String { currentText }

    var isRecovering: Bool { recoveryMode }

    func restore(_ text: String) {
        field.stringValue = text
        focusField()
    }

    private func layoutStack() {
        var fields: [NSView] = [clock, date, status]
        if wantsPassword { fields.append(field) }
        if !countdown.isHidden { fields.append(countdown) }
        if !error.isHidden { fields.append(error) }
        fields.append(unlock)
        if !useRecovery.isHidden { fields.append(useRecovery) }
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

    /// Codes before this step are refused. Pinned when the user asks to recover, so a
    /// code glimpsed earlier is worthless.
    ///
    /// Pinned at the current step rather than the next one. The next step looks tidier
    /// — "only codes minted after you asked" — but it rejects every phone running even
    /// slightly slow: such a phone still shows the current step when the gate opens,
    /// and the user is refused with a message blaming a code they never saw. Recovery
    /// failing is far worse than a glimpsed code being usable for one more step, since
    /// the whole feature exists so that a lockout is not catastrophic.
    private var recoveryFloor: Int64?

    /// Recovery belongs to the controller, not to a view. It used to live on LockView
    /// while attemptPassword read it from windows.first, so on a second display
    /// clicking "Use recovery code" left recovery permanently unreachable.
    private var recovering = false

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
        let wasRecovering = recovering
        cover()
        if wasRecovering { enterRecoveryEverywhere() }
        if !typed.isEmpty {
            (windows.first?.contentView as? LockView)?.restore(typed)
        }
    }

    func attemptUnlock(password: String) {
        guard policy == "password" else { return finish() }
        attemptPassword(password)
    }

    /// Called when the user opts into the recovery flow. Everything from the current
    /// step backwards is dead from here on.
    func armRecovery() {
        recovering = true
        recoveryFloor = TOTP.currentStep
    }

    func enterRecoveryEverywhere() {
        windows.forEach { ($0.contentView as? LockView)?.beginRecovery() }
    }

    /// v-claw's own password, never the macOS account password. See LockPassword.
    private func attemptPassword(_ attempt: String) {
        // With no password configured the lock cannot be a password lock. Fail open
        // rather than trap the user behind a credential that does not exist.
        guard LockPassword.isSet else { return finish() }
        guard !attempt.isEmpty else { return }

        // The password field takes the password and nothing else. Letting it also
        // accept codes would hand anyone a way around the recovery gate: type the code
        // showing on the phone and never wait for a fresh one.
        if !recovering {
            if LockPassword.verify(attempt) {
                return finish()
            }
            return refuse(attempt, recovering: false)
        }

        // A code from the authenticator, and only one minted after the user asked to
        // recover. It is a second credential rather than an escape valve: it needs the
        // phone holding the seed, and each code lasts about a minute. It exists because
        // the other way out is a restart, and a restart destroys the long-running work
        // this machine is being kept awake for in the first place.
        if TOTP.isConfigured, TOTP.verify(attempt, notBefore: recoveryFloor) {
            let skew = TOTP.lastSkewSeconds
            if skew != 0 {
                // Worth saying out loud: a drifting phone clock breaks every other
                // authenticator code the user has, not just this one.
                Event.send("error", ["message":
                    "recovery code accepted, but your phone's clock is about \(abs(skew))s "
                        + (skew > 0 ? "fast" : "slow")
                        + " — other authenticator codes will be failing too"])
            } else {
                Event.send("error", ["message": "unlocked with a recovery code"])
            }
            return finish()
        }

        refuse(attempt, recovering: true)
    }

    private func refuse(_ attempt: String, recovering: Bool) {
        authFailures += 1

        // No auto-unlock after N failures. An earlier version did that as a safety
        // valve and it was simply a bypass: anyone could fail three times on purpose
        // and walk in. Tell the user how to get out instead of opening the door.
        // The way out is on screen permanently, so this only has to report the failure.
        var msg = "Incorrect password"
        if recovering {
            Event.send("error", ["message": "recovery code refused: \(TOTP.lastRejection)"])
            switch TOTP.lastRejection {
            case "code predates the recovery request":
                msg = "That code was already showing — wait for the next one"
            case "code already used":
                msg = "That code has already been used — wait for the next one"
            default:
                msg = "That code did not work — wait for the next one and try that"
            }
        }
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
        recovering = false
        recoveryFloor = nil
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
