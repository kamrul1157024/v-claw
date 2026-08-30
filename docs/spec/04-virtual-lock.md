# 04 — Virtual lock

## Why it exists

The rest of this spec keeps the display awake so the screensaver never starts, so the
macOS lock never fires. That solves sleep. It creates a new problem.

> An awake, unlocked screen is readable by anyone who walks past, and usable by anyone
> who sits down.

The virtual lock closes that hole. v-claw covers every display with its own full-screen
window. The machine stays awake, the agents keep running, and the screen shows nothing
private.

It also does something the real lock cannot. Because v-claw owns the window, it can show
live status while locked: the clock, the power source, the awake state, and how long the
machine has been held open.

## What it is not

Read this before writing any of it.

> **The virtual lock is a privacy screen. It is not a security boundary.**

The real macOS lock is enforced by the kernel and by the Secure Enclave. It ties into
FileVault and it protects memory. The virtual lock is an ordinary window drawn by an
ordinary user process. A determined person with physical access defeats it. They can
reboot, boot to recovery, attach over SSH, or pull the disk.

v-claw must state this in the UI, once, when the user first turns the feature on. A user
who believes this is a real lock is worse off than a user with no lock at all, because
they will walk away with more confidence than the situation deserves.

If you need a real security boundary, use the real lock and accept the display sleep.

## It runs as a helper process

`internal/lock` draws nothing. It launches a small native helper and talks to it over
stdin and stdout.

```
-> lock {"policy":"auth","message":"..."}
<- unlocked
<- error covering display 2
```

| Platform | Helper |
|---|---|
| macOS | Swift, AppKit. **Verified to build** with Command Line Tools, see [01](01-macos-behaviour.md) |
| Windows | Win32 layered topmost window |
| Linux | Likely delegate to the desktop's own lock. Wayland forbids a client shielding the screen |

Three reasons, in order of weight:

1. A shielding window is deeply native on all three platforms, and Go has no good
   binding for any of them. In-process this becomes hundreds of lines of Objective-C
   inside cgo string literals, where the compiler cannot help.
2. The helper fails open by construction. Kill it and the desktop returns, which is
   exactly what the failure table below already requires.
3. `systray` owns `NSApp` and its delegate in the tray process. A second component
   fighting for the same run loop is a bug source.

The cost is a second language in the build. That is smaller than the cost of
Objective-C inside Go.

## Unlock policy

Two options. The choice is the whole security story, so make it explicit at setup rather
than burying it in a preference.

| Policy | Dismissed by | Use for |
|---|---|---|
| `none` | any key or click | A privacy screen. Coffee shop table, shared office desk. Stops reading and casual use. |
| `auth` | Touch ID, or the account password | A weak lock. Stops a colleague, not an attacker. |

`none` is the honest default. It matches the original request, which was to avoid typing
a password. It is also the only mode where v-claw makes no security claim at all.

### How `auth` validates

Through `LocalAuthentication.framework`, with `LAPolicyDeviceOwnerAuthentication`. This
gives Touch ID with a password fallback, and the OS performs the check.

**v-claw never sees, stores, or compares a password.** Do not read the password field
yourself. Do not call `dscl`. Do not invent a PIN. `LAContext.evaluatePolicy` is the only
acceptable implementation. Anything else is a credential-handling bug waiting to happen.

This lives in the Swift helper. `experiments/lockwin` already links the framework and
calls `canEvaluatePolicy` successfully, so the binding is proven.

## Engaging the lock

| Trigger | Behaviour |
|---|---|
| Menu, "Lock screen now" | Immediate |
| Global hotkey | Immediate. Default `Ctrl+Cmd+Q`, configurable |
| Idle timeout | After N minutes with no input. Default 5. Off by default |
| Lid closed, then reopened | Engage on reopen, if the lock was armed |

Idle is measured with `CGEventSourceSecondsSinceLastEventType`, using
`kCGAnyInputEventType`. Poll it every 5 seconds. Do not install an event tap. An event
tap needs Accessibility permission, which is a hard sell on a managed Mac, and it is a
keylogger-shaped API that IT reviewers rightly distrust.

## The window

One borderless window per display, created on `NSScreen.screens`.

| Property | Value |
|---|---|
| Level | `CGShieldingWindowLevel()`, which sits above the menu bar and the Dock |
| Frame | The full frame of its screen |
| Collection behaviour | `canJoinAllSpaces`, `stationary`, `fullScreenAuxiliary` |
| Background | Opaque |

Handle `NSApplication.didChangeScreenParametersNotification`. A display that is plugged
in while locked must be covered immediately. An uncovered second display defeats the
whole feature, and this is the most likely bug in the component.

### Escape hatches, and closing them

A shielding window alone does not stop the user leaving it. Set
`NSApplication.presentationOptions` to a kiosk combination:

| Option | Blocks |
|---|---|
| `disableProcessSwitching` | `Cmd+Tab` |
| `disableForceQuit` | `Cmd+Opt+Esc` |
| `disableSessionTermination` | Log out and shut down from the menu |
| `disableHideApplication` | `Cmd+H` |
| `hideDock`, `hideMenuBar` | The obvious exits |

Mission Control and Spaces still need testing. Treat any gap as a documented limitation,
not as a thing to fix with private APIs.

### What it shows

```
                        13:42
                    Saturday 30 August

                    +-----------+
                    |   claw    |     awake, held open
                    +-----------+

                  AC Power  ·  tier 1  ·  4h 12m

               Touch ID or press any key to unlock
```

Keep it sparse. No notification contents and no window titles. The point is that nothing
private is on screen.

Dim the display rather than let it sleep. The awake assertions must keep holding, so the
display cannot be allowed to sleep. Draw the window dark instead. This costs some power
and that is the accepted trade for keeping the lock virtual.

## Interaction with the rest of v-claw

The virtual lock is independent of the awake modes. Locking does not change the mode, and
`off` mode can still lock. Two separate concerns.

One coupling matters:

> If mode is `off` and the display is allowed to sleep, the real macOS lock may fire on
> top of the virtual lock.

That is not a failure. The user then unlocks twice. The status line should say the real
lock is also armed, so this is not a surprise.

## State fields

Added to `state.json`, described in [02-architecture.md](02-architecture.md).

```json
{
  "lock": {
    "enabled": true,
    "policy": "none",
    "idle_minutes": 0,
    "hotkey": "ctrl+cmd+q",
    "engaged": false
  }
}
```

`policy` is `none` or `auth`. `idle_minutes` of `0` disables the idle trigger.

`engaged` is written by the app and read by nothing privileged. **The daemon ignores the
whole `lock` object.** The virtual lock needs no root, so keeping it out of the daemon
keeps the privileged surface as small as it was.

## Failure behaviour

The lock must fail open, not closed. A bug in v-claw must never leave someone unable to
reach their own machine.

| Failure | Behaviour |
|---|---|
| `LAContext` returns an error, or Touch ID is unavailable | Fall back to the OS password sheet, then to `none` after 3 failures. Show why. |
| The window fails to cover a display | Do not engage at all. Report it. A partial cover is worse than none. |
| The helper crashes while locked | The windows die with it. The machine is unlocked. Accepted. |
| The helper hangs | The tray app kills it after a 5 s timeout on the unlock command. |
| The helper binary is missing | Disable the menu items and say so. Never fail silently. |

The third row is the direct consequence of "this is not a security boundary". Do not add
a watchdog that re-locks, because a watchdog that re-locks is a watchdog that can lock
someone out.

## Verification

- Lock, then confirm every display is covered, including one plugged in after locking.
- Lock, then try `Cmd+Tab`, `Cmd+Opt+Esc`, `Cmd+H`, Mission Control, and the hot corners.
- With `policy: none`, confirm any key dismisses it.
- With `policy: auth`, confirm Touch ID works and the password fallback works.
- Confirm `pmset -g assertions` still shows v-claw while locked.
- Confirm the display dims but never sleeps.
- Cover a failing `LAContext` by denying Touch ID three times.
- `kill -9` the app while locked. Confirm the desktop returns.
