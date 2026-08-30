# 08 — Cross-platform

macOS ships first. Linux and Windows follow. This document keeps v1 from painting them
into a corner.

## The good news

The two-tier model in [02-architecture.md](02-architecture.md) is not a macOS idea. It
holds on all three platforms, because all three separate "ask the OS politely to stay
awake", which any user can do, from "change the lid-close policy", which is privileged.

Go was already the right choice. It is now clearly the right choice, because it is the
only one of the candidates that compiles natively for all three with one codebase.

## Mechanism per platform

| Concern | macOS | Linux | Windows |
|---|---|---|---|
| Stay awake, no admin | `IOPMAssertionCreateWithName` | logind `Inhibit` D-Bus | `SetThreadExecutionState` |
| Block lid close | `pmset disablesleep`, root | logind `handle-lid-switch` inhibitor, **no root** | `powercfg` `LIDACTION`, admin |
| Power source | `IOPSGetProvidingPowerSourceType` | `/sys/class/power_supply/AC*/online` | `GetSystemPowerStatus` |
| Idle time | `CGEventSourceSecondsSinceLastEventType` | X11 `XScreenSaverQueryInfo`, Wayland idle protocol | `GetLastInputInfo` |
| Tray | `fyne.io/systray` | `fyne.io/systray`, StatusNotifierItem | `fyne.io/systray` |
| Lock window | Swift helper, AppKit | per-desktop, see below | Win32 helper |

### Linux is the easy one

`org.freedesktop.login1.Manager.Inhibit` takes a `what` string. It accepts
`handle-lid-switch`, alongside `sleep` and `idle`. The call returns a file descriptor,
and the inhibit holds for as long as the process keeps that fd open.

That means **Linux needs no root for lid blocking at all**. Tier 1 collapses into
tier 0. Holding an fd also gives the safety property from [03-safety.md](03-safety.md)
for free: if the app dies, the kernel closes the fd and the inhibit lifts. No watchdog
is needed.

`github.com/godbus/dbus/v5` is already in the dependency tree, pulled in by `systray`.

Non-systemd systems, and Wayland compositors without the idle-inhibit protocol, are out
of scope for the first Linux release. Report and degrade.

### Windows is mostly easy

`SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)`
needs no admin and covers idle sleep and display sleep. It is a direct analogue of the
macOS assertions, and it has the same "held by a live process" property.

Lid close is the privileged part, as on macOS. It is a power-scheme value, so tier 1
survives as a concept. Note that it is a persistent scheme edit rather than a runtime
flag, so the "save the original value and restore on uninstall" rule matters even more.

## What this forces into v1

Four rules. None of them cost much now. All of them are expensive to retrofit.

### 1. An interface, not a build tag maze

`internal/power` becomes an interface with one implementation per platform.

```go
type Controller interface {
    OnAC() (bool, error)
    IdleSeconds() (float64, error)

    // Tier 0. Holds until Release. No privilege.
    Hold(Options) error
    Release() error

    // Tier 1. Reports what this platform needs.
    Elevated() ElevatedController
    Capabilities() Caps
}

type Caps struct {
    LidBlockNeedsPrivilege bool // false on Linux
    LidBlockAvailable      bool
    ExplainUnavailable     string
}
```

Files split as `power_darwin.go`, `power_linux.go`, `power_windows.go`. All cgo stays
behind that boundary. Nothing above it imports `C`.

`Capabilities()` is what lets the UI tell the truth on each platform without the UI
knowing anything about `pmset` or logind. On Linux it reports that lid blocking is
available and free.

### 2. No macOS vocabulary above the interface

The state file, the CLI, and the menu must not mention `pmset`, `disablesleep`, or
assertions. They say `block_lid_sleep` and `keep_display_on`. They already do. Keep it
that way, and keep `pmsetctl` a private detail of the darwin implementation.

Rename tiers in user-facing text to **"basic"** and **"full"**, not "tier 0" and
"tier 1". On Linux both arrive at once, so a numbered ladder would mislead.

### 3. Paths must be resolved, never hardcoded

`/usr/local/var/v-claw/state.json` is a macOS answer. Put path resolution in
`internal/paths`, with one function per platform.

| Platform | State |
|---|---|
| macOS | `/usr/local/var/v-claw/` |
| Linux | `/run/v-claw/`, or `$XDG_RUNTIME_DIR/v-claw/` when there is no daemon |
| Windows | `%PROGRAMDATA%\v-claw\` |

### 4. The lock window is a helper process, on every platform

This is the decision that the cross-platform requirement settles.

A shielding window is deeply native on all three, and Go has no good binding for any of
them. So `internal/lock` does not draw anything. It launches a small platform helper and
talks to it over stdin and stdout with a two-line protocol.

```
-> lock {"policy":"auth","message":"..."}
<- unlocked
<- error covering display 2
```

| Platform | Helper |
|---|---|
| macOS | Swift, AppKit. Verified to build, see [01](01-macos-behaviour.md) |
| Windows | Win32 layered topmost window |
| Linux | per-desktop, hardest of the three |

The helper boundary means a broken lock on one platform cannot crash the tray app
anywhere, and a `kill -9` of the helper fails open, which is the behaviour
[04-virtual-lock.md](04-virtual-lock.md) already requires.

Linux is genuinely hard here, because there is no single answer across GNOME, KDE, X11,
and Wayland. Wayland does not allow a client to shield the screen at all. The likely
Linux answer is to call the desktop's own lock, and to accept that v-claw does not draw
that screen. Decide when Linux ships, not now.

## What stays macOS-only

Do not generalise these. They have no meaning elsewhere.

- `pmset`, `disablesleep`, and the read-back verify loop.
- IOKit assertion names.
- Configuration profiles and MDM detection. Linux and Windows have their own management
  systems and their own detection, and they are a separate problem.
- The `.app` bundle, `LSUIElement`, and ad-hoc codesign.

## Order

| Release | Platform | Notes |
|---|---|---|
| v1 | macOS | Everything in this spec |
| v2 | Linux | logind. Likely simpler than macOS. Lock screen delegated to the desktop |
| v3 | Windows | `SetThreadExecutionState` plus a power-scheme edit |

Do not build Linux or Windows stubs in v1. Build the **interface** in v1, and one
implementation behind it. An empty `power_linux.go` that returns `ErrUnsupported` is
enough to prove the boundary is real.

Add `GOOS=linux go build ./...` and `GOOS=windows go build ./...` to CI from the first
commit. They will fail on cgo until the stubs exist, which is the point: the failure is
the reminder.
