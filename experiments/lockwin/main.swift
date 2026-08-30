// Probe: can Command Line Tools alone build a shielding lock window?
// Covers every screen, blocks Cmd+Tab / force quit, dismisses on any key.
//   swiftc -O experiments/lockwin/main.swift -o build/lockwin && ./build/lockwin
import AppKit
import LocalAuthentication

final class LockView: NSView {
    override var acceptsFirstResponder: Bool { true }
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        label.font = .monospacedDigitSystemFont(ofSize: 64, weight: .thin)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        tick()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.tick() }
    }
    required init?(coder: NSCoder) { nil }

    func tick() {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        label.stringValue = f.string(from: Date()) + "\n\nv-claw holding lid open\npress any key"
        label.sizeToFit()
        label.frame.origin = NSPoint(x: (bounds.width - label.frame.width) / 2,
                                     y: (bounds.height - label.frame.height) / 2)
    }

    override func keyDown(with event: NSEvent) { Lock.shared.unlock() }
    override func mouseDown(with event: NSEvent) { Lock.shared.unlock() }
}

final class Lock {
    static let shared = Lock()
    var windows: [NSWindow] = []

    func cover() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                             backing: .buffered, defer: false, screen: screen)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            w.isOpaque = true
            w.backgroundColor = .black
            w.contentView = LockView(frame: NSRect(origin: .zero, size: screen.frame.size))
            w.makeKeyAndOrderFront(nil)
            return w
        }
        windows.first?.makeFirstResponder(windows.first?.contentView)
        print("covered \(windows.count) screen(s)")
    }

    func unlock() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        NSApp.presentationOptions = []
        print("unlocked")
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// The kiosk options the spec depends on. If this throws, the spec is wrong.
app.presentationOptions = [
    .disableProcessSwitching, .disableForceQuit, .disableSessionTermination,
    .disableHideApplication, .hideDock, .hideMenuBar,
]
print("presentationOptions accepted: \(app.presentationOptions)")

// LocalAuthentication availability, without actually prompting.
var authErr: NSError?
let ctx = LAContext()
let can = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authErr)
print("LAContext deviceOwnerAuthentication: \(can) \(authErr?.localizedDescription ?? "")")
print("biometry type: \(ctx.biometryType.rawValue)")

NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification,
    object: nil, queue: .main
) { _ in
    print("screens changed, re-covering")
    Lock.shared.cover()
}

app.activate(ignoringOtherApps: true)
Lock.shared.cover()
app.run()
