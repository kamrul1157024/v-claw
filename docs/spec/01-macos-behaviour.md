# 01 — Platform notes: macOS

Platform-specific findings for the one platform implemented today. Linux and Windows
get their own equivalents when they land; the mechanisms differ and are summarised in
[08-cross-platform.md](08-cross-platform.md).

Everything here was measured, not assumed. Re-measure it when macOS changes.

## Reference machine

| Field | Value |
|---|---|
| Model | `Mac14,10` — MacBook Pro 14", M2 Pro |
| macOS | 26.6.1, build 25G76 |
| Date measured | 2026-08-30 |

## Baseline power settings

`pmset -g custom`

| Setting | Battery | AC |
|---|---|---|
| `sleep` | 1 | **0** |
| `displaysleep` | 3 | **20** |
| `disksleep` | 10 | 10 |
| `standby` | 1 | 1 |
| `hibernatemode` | 3 | 3 |
| `powernap` | 1 | 1 |
| `lowpowermode` | 0 | 0 |
| `tcpkeepalive` | 1 | 1 |
| `womp` | 0 | 1 |

Record these before the first install. `make uninstall-daemon` must restore them.

Note that AC `sleep` is already `0`. Idle sleep on AC is already disabled. **Lid-close
sleep is a separate mechanism** and it is unaffected by that value. This is the single
most misunderstood point in this whole area.

## Screen lock

```
$ sysadminctl -screenLock status
screenLock delay is 900 seconds
```

The lock fires 900 seconds after the screensaver starts. If the screensaver never
starts, the lock never fires. That is the lever v-claw uses.

`defaults read com.apple.screensaver askForPassword` returns nothing. On macOS Ventura
and later that key is no longer authoritative. `sysadminctl` is. Do not write the
`defaults` key.

## The `disablesleep` flag

`pmset` accepts an undocumented `disablesleep` flag.

- It is absent from `man pmset`.
- It is absent from `pmset -g cap`.
- It is present in the binary:

```
$ strings /usr/bin/pmset | grep -i disablesleep
disablesleep
```

- It is **global**, not per power source. `pmset -c disablesleep 1` does not scope it to
  AC. A script must therefore flip the flag on every power source change, rather than
  set it once.
- It needs root.

## The clamshell rule

`powerd` owns the decision. Its log strings state the rule directly:

```
$ strings /System/Library/CoreServices/powerd.bundle/powerd | grep -i clamshell
EvaluateClamshell. Disable : %lld because {DesktopMode with AC: %u, assertions %d
EvaluateClamshellSleepState on power source change
EvaluateClamshellSleepState on DesktopMode update
ClamshellState. Closed : %u. ClamshellSleepState: isSleepDisabled : %d
PreventSystemSleep
```

Read that first line carefully. Clamshell sleep is disabled because of **DesktopMode
with AC**, or because of **assertions**. Two independent paths, and the second needs no
root.

`EvaluateClamshellSleepState on power source change` also confirms that plugging and
unplugging the adapter re-runs the decision. v-claw must react to the same event.

## Power assertions

```
$ pmset -g assertions
   PreventUserIdleDisplaySleep    0
   PreventUserIdleSystemSleep     1
   PreventSystemSleep             0
   UserIsActive                   1
```

Any user can create these. No root. `caffeinate` is a thin wrapper over them:

| `caffeinate` flag | Assertion |
|---|---|
| `-i` | `PreventUserIdleSystemSleep` |
| `-d` | `PreventUserIdleDisplaySleep` |
| `-s` | `PreventSystemSleep` — valid only on AC |
| `-u` | `UserIsActive` — also turns the display on |
| `-m` | prevents disk idle sleep |

v-claw creates these directly through `IOPMAssertionCreateWithName`, rather than forking
`caffeinate`. Three reasons: no child process to supervise, no 5-second default timeout
to work around, and a named assertion shows up in `pmset -g assertions` as `v-claw`,
which makes the live state auditable from any terminal.

## Measured: the cgo layer works

`experiments/probe` was built and run on the reference machine. Output:

```
== power source ==
  AC Power
== idle ==
  18.6s since last input
== assertions ==
  PreventUserIdleSystemSleep   ok (id 34019)
  PreventUserIdleDisplaySleep  ok (id 34020)
  PreventSystemSleep           ok (id 34021)
```

This settles four things:

| API | Result |
|---|---|
| `IOPSCopyPowerSourcesInfo` + `IOPSGetProvidingPowerSourceType` | Works. Returns `AC Power`. Simpler than iterating the source list. |
| `IOPMAssertionCreateWithName` | Works for all three assertion types. |
| `CGEventSourceSecondsSinceLastEventType` | Works. No Accessibility permission needed. |
| cgo against `IOKit` and `ApplicationServices` | Compiles with Command Line Tools. No Xcode. |

## Measured: the Swift lock window builds

`experiments/lockwin/main.swift` compiles to a 90 KB binary with `swiftc` alone.

```
swiftc -O experiments/lockwin/main.swift -o build/lockwin
```

It links `AppKit` and `LocalAuthentication`, and it uses `CGShieldingWindowLevel()`,
`NSApplication.presentationOptions`, and `LAContext.canEvaluatePolicy`. All resolve at
compile time with Command Line Tools. Xcode is not required.

Runtime behaviour is still unverified, because the window covers the screen. See the
manual test list in [04-virtual-lock.md](04-virtual-lock.md).

## Measured: the tray renders

`experiments/tray` runs and puts an icon in the menu bar. It exercises every construct
the menu in [05-ui.md](05-ui.md) needs, and `fyne.io/systray` accepted all of them:

| Construct | Used for |
|---|---|
| `SetTemplateIcon` | Automatic light and dark mode tinting |
| `AddMenuItem` then `Disable` | The non-clickable status line |
| `AddMenuItemCheckbox` | The mode radio group |
| `AddSubMenuItem`, `AddSubMenuItemCheckbox` | The timer and virtual lock submenus |
| `AddSeparator` | |

It also runs as a bare binary with no `.app` bundle, which keeps `go run` usable during
development.

One structural fact came out of reading the library: `systray` calls `[NSApp run]` and
installs its own `NSApplicationDelegate`. It owns the main run loop in the tray process.
That is the third reason the lock window is a separate process, see
[04-virtual-lock.md](04-virtual-lock.md).

## Answered: `disablesleep` works, and cannot be read from pmset

Observed on 2026-08-30, macOS 26.6.1, with the daemon holding on AC and the lid shut.

```
$ ioreg -n IOPMrootDomain -r | grep SleepDisabled
|   "SleepDisabled" = Yes
```

The flag takes effect. The machine did not sleep with the lid closed on AC, and
`pmset -g log` records no sleep event for the period.

But **`pmset -g` never reports `disablesleep`, set or unset.** It can be written through
pmset and only read from IORegistry, as `IOPMrootDomain`'s `SleepDisabled` property.

That cost real time. v-claw verified the write against pmset output, always read zero,
and logged `disablesleep did not stick: wrote 1, read back 0` every ten seconds while
the setting was working perfectly. The daemon also never recorded that it was holding,
because the failed verification made `hold` return an error. A read-back check is only
as good as the place it reads from, and this one was reading somewhere the value can
never appear.

Read it from IORegistry. `internal/pmsetctl.sleepDisabled` does.

## The open question

> Does a `PreventSystemSleep` assertion alone stop lid-close sleep on Apple Silicon?

The `powerd` rule says assertions are counted. Field reports across Apple Silicon
releases disagree on the result. This must be measured, not argued.

**Test.** Hold `PreventSystemSleep`, on AC, with no external display and no external
keyboard. Close the lid. Wait 5 minutes. Open it. Check for a sleep event:

```
pmset -g log | grep -i -E "Entering Sleep|Wake from"
```

**Why it matters.** If the assertion is enough, tier 0 delivers the full feature with no
admin, and the daemon becomes a fallback for machines where it is not enough. If the
assertion is not enough, the daemon is mandatory for the headline feature.

Either result keeps the architecture in [02-architecture.md](02-architecture.md)
unchanged. Only the honesty of the tier-0 label changes. Record the result in the README.

## What defeats v-claw

A managed Mac can override all of the above. These are not bugs, and v-claw must report
them rather than fail silently.

| Mechanism | Effect |
|---|---|
| Config profile forcing "Require password immediately" | The lock fires anyway. v-claw cannot win. |
| MDM pushing power settings on a schedule | A `pmset` write is silently reverted minutes later. |
| MDM blocking unapproved LaunchDaemons | Tier 1 cannot install. |
| Gatekeeper policy on managed Macs | An unsigned app is refused. |

Detection is covered in [03-safety.md](03-safety.md).
