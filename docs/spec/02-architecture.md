# 02 — Architecture

## Three binaries, one state file

```
+-----------------+          +---------------------------+
|  v-claw.app     |  writes  |  /usr/local/var/v-claw/   |
|  (user)         | -------> |  state.json               |
|  tray UI        |          +---------------------------+
|  IOKit          |                      | watches
|  assertions     |                      v
+-----------------+          +---------------------------+
                             |  v-clawd  (root)          |
+-----------------+  writes  |  LaunchDaemon             |
|  v-claw  (CLI)  | -------> |  applies pmset            |
|  (user)         |          +---------------------------+
+-----------------+
```

There is no XPC and no custom IPC protocol. A file plus `fsnotify` does the whole job,
and it stays debuggable with `cat`.

| Binary | Runs as | Job |
|---|---|---|
| `v-claw.app` | you | Tray UI. Holds IOKit assertions. Writes `state.json`. |
| `v-clawd` | root | LaunchDaemon. Reads `state.json` and the power source. Applies `pmset`. |
| `v-claw` | you | CLI. Same state file. Scripting and diagnostics. |

The app never needs root. The daemon is the only privileged component, and it is the
only thing an IT reviewer has to approve.

## Two capability tiers

| Tier | Admin | Idle sleep | Display sleep | Lid close |
|---|---|---|---|---|
| **0** — app only | none | blocked | blocked | best effort, see [01](01-macos-behaviour.md) |
| **1** — with daemon | once, at install | blocked | blocked | guaranteed |

Tier 0 is live the moment `make install` finishes. Tier 1 is an upgrade, not a
requirement. Nobody is blocked at step one.

The menu bar icon shows which tier is live. Tier 0 must never claim a guarantee it
cannot keep.

## Modes

Three, mutually exclusive.

| Mode | Behaviour |
|---|---|
| `off` | v-claw changes nothing. Everything returns to system defaults. |
| `always` | The awake rules apply on any power source. |
| `auto` | The awake rules apply only while the adapter is connected. |

`auto` is the default. It matches the original request and it is the safest, because
unplugging releases everything.

## State file

Path: `/usr/local/var/v-claw/state.json`

```json
{
  "mode": "auto",
  "block_lid_sleep": true,
  "keep_display_on": true,
  "expires_at": null,
  "heartbeat": "2026-08-30T13:36:00+06:00",
  "lock": {
    "enabled": true,
    "policy": "none",
    "idle_minutes": 0,
    "hotkey": "ctrl+cmd+q",
    "engaged": false
  }
}
```

| Field | Type | Values |
|---|---|---|
| `mode` | string | `off`, `always`, `auto` |
| `block_lid_sleep` | bool | |
| `keep_display_on` | bool | |
| `expires_at` | RFC3339 or null | Drives the timed override |
| `heartbeat` | RFC3339 | The app rewrites this every 60 s. See [03](03-safety.md). |
| `lock` | object | The virtual lock. See [04](04-virtual-lock.md). |

**The daemon ignores the whole `lock` object.** The virtual lock needs no root, so
keeping it out of the daemon holds the privileged surface exactly where it was.

### Why this path

`make install-daemon` creates the directory. The owner is `$SUDO_USER` and the mode is
`0755`. The app then writes the file as that user.

The obvious alternative, `~/.config/v-claw/`, forces the root daemon to guess which
user's home directory to watch. That breaks with fast user switching and with more than
one account. One fixed path removes the question.

### Security rule

> A user who writes `state.json` causes root to run `pmset`. Treat the file as
> untrusted input.

The daemon therefore:

- accepts a **closed enum** of modes, and rejects anything else,
- accepts booleans only for the two flags,
- **never** passes a value from the file into a shell,
- calls `exec.Command("/usr/bin/pmset", ...)` with a fixed argument list built from the
  validated enum, not from file content,
- uses an absolute path for every binary it runs,
- logs and ignores a malformed file rather than acting on a partial parse.

The blast radius is then bounded to the exact `pmset` values v-claw is designed to set.

## What each tier does

### Tier 0 — the app, via cgo and `IOKit.framework`

Assertions are created with `IOPMAssertionCreateWithName`, all named `v-claw`.

| Assertion | Purpose |
|---|---|
| `PreventUserIdleSystemSleep` | Stops idle system sleep. |
| `PreventUserIdleDisplaySleep` | Stops display sleep, so the screensaver never starts, so the lock never fires. |
| `PreventSystemSleep` | May also stop lid-close sleep. See [01](01-macos-behaviour.md). |

The third one is why the app must hold assertions even when the daemon is installed.
The two mechanisms are complementary, not redundant.

### Tier 1 — the daemon, via `pmset`

| State | Commands |
|---|---|
| Active | `pmset -a disablesleep 1`, `pmset -c displaysleep 0` |
| Released | `pmset -a disablesleep 0`, restore the saved `displaysleep` |

`disablesleep` is global, so the daemon flips it on every transition. It cannot be set
once and left.

`make install-daemon` records the original `displaysleep` values for both power sources
to `/usr/local/var/v-claw/original.json`. `make uninstall-daemon` restores them.

Every write is read back and compared. A mismatch means something else, usually MDM,
is overriding v-claw. That surfaces in Diagnostics.

## Power source detection

Both the app and the daemon need to know whether the adapter is connected.

- **Read:** cgo, `IOPSCopyPowerSourcesInfo` and `IOPSCopyPowerSourcesList`.
- **Events:** `notify_register_dispatch` on `com.apple.system.powersources.source`.
- **Safety net:** a 10 second ticker.

The ticker is not optional. A missed notification would leave the machine in the wrong
state with no visible sign, and the wrong state here is a thermal risk.

`powerd` re-runs `EvaluateClamshellSleepState on power source change`, so v-claw is
reacting to the same event that macOS reacts to.

## Package layout

| Package | Contents |
|---|---|
| `internal/state` | Read, write, watch, and validate `state.json`. Shared by all three binaries. |
| `internal/power` | The platform interface. One implementation per OS. All cgo lives here. |
| `internal/paths` | Path resolution per platform. Nothing hardcodes a path. |
| `internal/lock` | Launches and supervises the lock helper process. Draws nothing itself. |
| `internal/pmsetctl` | **darwin only.** Fixed-argument `pmset` wrapper with read-back verify. |
| `internal/diag` | The diagnostics report. |
| `internal/icon` | Icon bytes, embedded with `go:embed`. |

One shared `state` package keeps the three binaries honest about the schema.

### The platform boundary

`internal/power` is an interface, not a package of macOS calls. Linux and Windows follow
this release, and the boundary is expensive to retrofit later.

```go
type Controller interface {
    OnAC() (bool, error)
    IdleSeconds() (float64, error)
    Hold(Options) error      // tier 0, no privilege
    Release() error
    Elevated() ElevatedController // tier 1
    Capabilities() Caps
}
```

Two rules follow, and both apply from the first commit:

- **Nothing above `internal/power` imports `C`.** Files split as `power_darwin.go`,
  `power_linux.go`, `power_windows.go`.
- **No macOS vocabulary above the interface.** The state file, the CLI, and the menu say
  `block_lid_sleep`, never `disablesleep`. `pmsetctl` is a private detail of the darwin
  implementation.

`Capabilities()` is how the UI tells the truth on each platform without knowing what is
underneath. On Linux it will report that lid blocking is available with no privilege,
because a logind inhibitor is free. See [08-cross-platform.md](08-cross-platform.md).
