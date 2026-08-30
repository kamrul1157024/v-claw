// An on-screen banner, used when a notification cannot be delivered.
//
// v-claw's warnings exist for the moments nobody is watching: a timer expired, the
// machine is still awake on battery, the lid shut while it kept running. Every one of
// those goes out as a notification, and on this app they often cannot.
//
// macOS refuses UNUserNotificationCenter for a bundle it does not trust, and v-claw is
// built from source and ad-hoc signed by design — there is no Developer ID to fix it
// with. The request returns "not allowed", nothing appears, and the app looks like it
// is working. A warning that silently fails is worse than no warning, because it is
// relied upon.
//
// So this draws the message directly. It needs no permission, cannot be switched off
// by a setting nobody remembers changing, and looks the same on every machine.
import AppKit

final class Banner {
    static let shared = Banner()

    private var window: NSWindow?
    private var dismiss: Timer?

    /// Shows a message for a few seconds in the top-right corner.
    ///
    /// Deliberately not interactive: it must never steal focus or interrupt typing.
    /// The point is to be noticed, not to be dealt with.
    func show(title: String, body: String, seconds: TimeInterval = 6) {
        guard let screen = NSScreen.main else { return }

        dismiss?.invalidate()
        window?.orderOut(nil)

        let width: CGFloat = 360
        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: 88))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true

        let head = NSTextField(labelWithString: title)
        head.font = .systemFont(ofSize: 13, weight: .semibold)
        head.frame = NSRect(x: 16, y: 52, width: width - 32, height: 18)

        let text = NSTextField(wrappingLabelWithString: body)
        text.font = .systemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor
        text.preferredMaxLayoutWidth = width - 32
        text.frame = NSRect(x: 16, y: 10, width: width - 32, height: 38)

        content.addSubview(head)
        content.addSubview(text)

        let frame = NSRect(
            x: screen.visibleFrame.maxX - width - 16,
            y: screen.visibleFrame.maxY - 88 - 16,
            width: width, height: 88)

        let w = NSWindow(contentRect: frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.contentView = content
        w.orderFrontRegardless() // never activates, so it cannot steal focus

        window = w
        dismiss = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.window?.orderOut(nil)
            self?.window = nil
        }
    }
}
