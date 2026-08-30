# 06 — Build and install

## Repo layout

```
v-claw/
  Makefile
  go.mod
  cmd/
    v-claw-app/       tray UI
    v-clawd/          privileged daemon
    v-claw/           CLI
  helper/
    darwin/main.swift virtual lock window, AppKit + LocalAuthentication
  internal/
    state/            state.json read, write, watch, validate
    power/            platform interface
      power_darwin.go   cgo: IOKit assertions, power source, idle
      power_linux.go    stub in v1
      power_windows.go  stub in v1
    paths/            per-platform path resolution
    lock/             launches and supervises the helper process
    pmsetctl/         darwin only: pmset wrapper, read-back verify
    diag/             diagnostics report
    icon/             go:embed icon bytes
  resources/
    Info.plist
    com.vclaw.daemon.plist
    com.vclaw.agent.plist
    icons/            source SVG, generated PNG and icns
  scripts/
    build-app.sh      binaries -> v-claw.app, ad-hoc codesign
    install-daemon.sh the three lines an IT reviewer reads
    gen-icons.sh      SVG -> PNG set -> icns
  docs/spec/
  README.md
```

Module path: `github.com/kamrul1157024/v-claw`.

## The privilege split is the product

Everything about the build serves one rule from [00-overview.md](00-overview.md): ask for
admin once, and never again.

```
make                  Build 3 binaries and v-claw.app
make install          NO SUDO. Tier 0 is live.
make install-daemon   SUDO. Tier 1 is live. Run once, ever.
make uninstall        NO SUDO. Reverses make install.
make uninstall-daemon SUDO. Removes the daemon, restores saved pmset values.
make diagnose         Prints the diagnostics report.
make icons            Regenerates icons from SVG.
make test
```

A person with no admin runs the first two lines and gets a working app. A person with
admin runs one more. Nobody is blocked at step one.

The README leads with exactly that, and labels each command with the privilege it needs.

## `make install` — no sudo

| Artifact | Destination |
|---|---|
| `v-claw.app` | `/Applications` |
| `v-claw` CLI | `~/.local/bin` |
| `com.vclaw.agent.plist` | `~/Library/LaunchAgents` |

A user-level LaunchAgent handles launch at login. It needs no admin. Prefer it over
`SMAppService`, which wants a signed bundle.

If `/Applications` is not writable, fall back to `~/Applications` and say so.

## `make install-daemon` — sudo, once

Its readability **is** the security review. Keep it boring. No network, no downloads, no
`curl`, no version checks.

```sh
install -m 755 build/v-clawd            /usr/local/libexec/v-clawd
install -m 644 resources/com.vclaw.daemon.plist /Library/LaunchDaemons/
launchctl bootstrap system /Library/LaunchDaemons/com.vclaw.daemon.plist
```

It also, before those lines:

1. Prints the full text of the plist and the three commands, then asks to continue.
2. Records the current `displaysleep` for both power sources into
   `/usr/local/var/v-claw/original.json`, so uninstall can be exact.
3. Creates `/usr/local/var/v-claw/`, owner `$SUDO_USER`, mode `0755`.

### The IT request text

The app and `make install-daemon --explain` both print a paragraph that can be pasted
into a ticket. It must answer what an approver asks, in the order they ask it.

```
v-claw installs one background service that runs as root.

What it does:   Runs /usr/bin/pmset to stop the laptop sleeping when the lid
                closes while it is on the power adapter.
Why root:       The pmset disablesleep flag requires root. Nothing else does.
Network:        None. The service makes no network connections.
Data:           None collected, none sent.
Files:          /usr/local/libexec/v-clawd
                /Library/LaunchDaemons/com.vclaw.daemon.plist
                /usr/local/var/v-claw/
Source:         <repo url>, MIT licensed. The install script is 3 lines.
Removal:        sudo make uninstall-daemon, which restores the original settings.
```

## Signing and Gatekeeper

A locally built app carries no `com.apple.quarantine` attribute, so Gatekeeper does not
block it. This is the reason `make install` works with no Developer ID and no `$99`
account.

Ad-hoc sign anyway, with `codesign -s - --force`. It keeps the bundle identity stable
across rebuilds, which matters for TCC prompts and for the LaunchAgent.

Two consequences to document rather than fix:

- Anyone who downloads a **prebuilt** binary gets the quarantine flag and gets blocked.
  So do not publish prebuilt binaries in v1. Build from source is the supported path.
- A managed Mac with a strict Gatekeeper policy may refuse the app regardless. Detected
  and reported by Diagnostics, see [03-safety.md](03-safety.md).

Revisit notarization when the repo goes public.

## The app bundle

`scripts/build-app.sh` assembles it by hand. No Xcode.

```
v-claw.app/Contents/
  Info.plist
  MacOS/
    v-claw-app
    v-claw-lock      the Swift helper
  Resources/
    AppIcon.icns
```

The helper ships inside the bundle. `internal/lock` resolves it relative to the running
executable, never by `PATH`.

`Info.plist` must set:

| Key | Value | Reason |
|---|---|---|
| `LSUIElement` | `true` | Menu bar only. No Dock icon, no app switcher entry. |
| `CFBundleIdentifier` | `com.vclaw.app` | |
| `LSMinimumSystemVersion` | `13.0` | |
| `NSHumanReadableCopyright` | | |

The daemon label is `com.vclaw.daemon`. The agent label is `com.vclaw.agent`.

## Toolchain

Verified present and working on the reference machine:

| Tool | Version | Verified by |
|---|---|---|
| Go | 1.26.1 darwin/arm64 | `experiments/probe` builds and runs |
| Clang, for cgo | Command Line Tools | same |
| `swiftc` | Apple Swift 6.3.3 | `experiments/lockwin` builds, 90 KB |

Xcode.app is **not** required. Command Line Tools are enough for cgo against
`IOKit.framework` and `ApplicationServices.framework`, and for `swiftc` against `AppKit`
and `LocalAuthentication`.

## Cross-compilation checks

From the first commit, CI runs:

```
GOOS=linux   go build ./...
GOOS=windows go build ./...
```

These fail until `power_linux.go` and `power_windows.go` exist as stubs returning
`ErrUnsupported`. That failure is the point. It is the reminder that the platform
boundary in [08-cross-platform.md](08-cross-platform.md) is real and not aspirational.

Nothing above `internal/power` may import `C`. These two commands are what enforce it.

`make icons` additionally wants `rsvg-convert`. Fall back to `qlmanage` when it is
missing, and skip the target entirely if both are absent, since the icons are committed.

## Dependencies

Keep the list short. Every dependency is something an IT reviewer has to read.

| Module | For |
|---|---|
| `fyne.io/systray` | The tray icon and menu |
| `github.com/fsnotify/fsnotify` | Watching `state.json` |
| `github.com/godbus/dbus/v5` | Linux only, later. Already present as a `systray` dependency |

Everything else is the standard library plus cgo. No web framework, no logging
framework, no configuration library.

`systray` was checked against the menu this spec needs. All of it exists:
`SetTemplateIcon`, `AddSubMenuItemCheckbox`, `Check`, `Uncheck`, `Disable` for the
status line, and `AddSeparator`. It calls `[NSApp run]` and owns the main run loop,
which is the third reason the lock window is a separate process.

## Testing

- `internal/state` validation is pure Go. Table-driven tests, including malformed and
  hostile input, since the daemon treats the file as untrusted.
- `internal/pmsetctl` takes a runner interface, so the argument list can be asserted
  without touching the system.
- The cgo packages are covered by the manual checks in each spec document. Do not build
  a fake IOKit.
