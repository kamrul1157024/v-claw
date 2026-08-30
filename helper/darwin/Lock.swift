// The virtual lock screen.
//
// It is a privacy screen, NOT a security boundary. It is an ordinary window drawn by an
// ordinary user process, and anyone with physical access defeats it. It exists so you
// can step away without letting the machine sleep, which the real macOS lock cannot do
// because that lock is tied to display sleep.
import AppKit
import LocalAuthentication

final class LockView: NSView {
    private let clock = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private var timer: Timer?

    init(frame: NSRect, message: String, hintText: String) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        // Dim rather than allow display sleep. The awake assertions must keep holding,
        // so the display cannot be permitted to sleep; darkness is the trade.
        style(clock, size: 76, weight: .thin, alpha: 0.92)
        style(date, size: 17, weight: .regular, alpha: 0.55)
        style(status, size: 14, weight: .medium, alpha: 0.45)
        style(hint, size: 13, weight: .regular, alpha: 0.35)

        status.stringValue = message
        hint.stringValue = hintText
        [clock, date, status, hint].forEach(addSubview)

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

    private func layoutStack() {
        let fields = [clock, date, status, hint]
        fields.forEach { $0.sizeToFit() }
        let gaps: [CGFloat] = [18, 56, 10]
        let total = fields.reduce(0) { $0 + $1.frame.height } + gaps.reduce(0, +)

        var y = (bounds.height + total) / 2
        for (i, f) in fields.enumerated() {
            y -= f.frame.height
            f.frame.origin = NSPoint(x: (bounds.width - f.frame.width) / 2, y: y)
            if i < gaps.count { y -= gaps[i] }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { Lock.shared.attemptUnlock() }
    override func mouseDown(with event: NSEvent) { Lock.shared.attemptUnlock() }
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
    }

    @discardableResult
    private func cover() -> Bool {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()

        let hint = policy == "auth"
            ? "Touch ID or press any key to unlock"
            : "Press any key to unlock"

        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                             backing: .buffered, defer: false, screen: screen)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            w.isOpaque = true
            w.backgroundColor = .black
            w.ignoresMouseEvents = false
            w.contentView = LockView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                     message: message, hintText: hint)
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }

        guard windows.count == NSScreen.screens.count, !windows.isEmpty else { return false }
        windows.first?.makeFirstResponder(windows.first?.contentView)
        return true
    }

    // A display plugged in while locked must be covered at once. An uncovered second
    // screen defeats the entire feature.
    @objc private func screensChanged() { cover() }

    func attemptUnlock() {
        guard policy == "auth" else { return finish() }

        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"

        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            Event.send("error", ["message": "authentication unavailable: \(err?.localizedDescription ?? "unknown")"])
            return finish()
        }

        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "unlock v-claw") { [weak self] ok, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if ok { return self.finish() }

                // Fail open after repeated failures. A bug here must never lock
                // someone out of their own machine.
                self.authFailures += 1
                if self.authFailures >= 3 {
                    Event.send("error", ["message": "authentication failed 3 times, unlocking"])
                    self.finish()
                }
            }
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
    func updateMessage(_ text: String) {
        guard !windows.isEmpty, text != message else { return }
        message = text
        cover()
    }
}
