# 03 — Safety

## The failure mode is physical

Most app bugs waste time. This one can damage hardware.

A closed lid on a machine that cannot sleep keeps running with the vents against the
inside of a bag. The fan cannot move air. The machine gets hot and the battery drains
flat.

The failure is also **silent**. There is no sound, no screen, and no notification. The
lid is closed, so the user believes the machine is asleep.

Every safety rule below exists because of that one scenario.

## Release rules

v-claw releases everything when any of these is true.

| Trigger | Detected by | Latency |
|---|---|---|
| Mode set to `off` | `state.json` change | immediate |
| Adapter removed, in `auto` mode | power source notification | immediate, 10 s worst case |
| `expires_at` passes | timer in app and daemon | 1 s |
| The app stops sending a heartbeat | daemon watchdog | 5 min |
| The daemon exits | `launchd`, `SIGTERM` handler | immediate |

### The heartbeat watchdog

The app rewrites `state.json` `heartbeat` every 60 seconds.

If the daemon sees a heartbeat older than 5 minutes, it releases everything and logs
why. This covers the case that matters most: the app crashes, or is force quit, while
`disablesleep` is set. Without the watchdog, root would hold the machine awake forever
with no UI left to turn it off.

The daemon must also release on `SIGTERM`, so `launchctl bootout` leaves the machine
clean.

### Timed override

The menu offers "Awake for 1 hour", with 15 min, 1 h, 4 h, and "until I quit" options.
This sets `expires_at`.

A time limit is the best defence against forgetting. Consider making a timed value the
default for `always` mode, since `always` is the risky one.

## The icon is a safety device

The active state must be unmistakable at a glance, in a crowded menu bar, in both light
and dark mode.

This is why the active glyph is **filled** and the inactive glyphs are **outlines**.
Fill versus outline reads faster than any shape difference. See
[04-ui.md](04-ui.md).

Tier 0 must never display the same confidence as tier 1. If lid blocking is best effort,
the icon carries a notch and the status line says so.

## Honesty rules

These prevent the worst outcome, which is a user who trusts a guarantee v-claw is not
delivering.

1. Never report a state that was not read back from the system.
2. If a `pmset` write does not survive read-back, show the failure. Do not retry
   silently in a loop.
3. If tier 1 is not installed, say "best effort" for lid blocking, not "on".
4. If a config profile forces the screen lock, say v-claw cannot override it.

## Managed Mac diagnostics

A managed Mac can defeat v-claw in four ways. Each one looks like a bug and is not.

| Mechanism | Symptom | Detection |
|---|---|---|
| Profile forces "Require password immediately" | Screen locks anyway | `profiles show -type configuration`, look for `askForPasswordDelay` and `idleTime` |
| MDM pushes power settings on a schedule | Works, then stops minutes later | `pmset` read-back mismatch after a delay |
| MDM blocks unapproved LaunchDaemons | `make install-daemon` appears to work, daemon never runs | `launchctl print system/com.vclaw.daemon` |
| Gatekeeper policy | App refuses to launch | `spctl --status`, `codesign -dv` |

### The Diagnostics report

Available as `make diagnose`, as `v-claw diagnose`, and from the menu.

```
v-claw diagnostics
  version        0.1.0
  macOS          26.6.1 (25G76)
  model          Mac14,10

tier             1  (daemon installed and running)
mode             auto
power source     AC Power
state            ACTIVE

assertions held by v-claw
  PreventUserIdleSystemSleep    yes
  PreventUserIdleDisplaySleep   yes
  PreventSystemSleep            yes

pmset  (written -> read back)
  disablesleep      1 -> 1    ok
  displaysleep AC   0 -> 20   MISMATCH

configuration profiles
  com.company.mdm.power   present, sets displaysleep
  screen lock enforced    no

warnings
  ! displaysleep did not stick. A profile is overriding v-claw.
    The screen will still sleep and the lock will still fire.
```

The report must name the cause. "It did not work" is useless to the person reading it.

## Thermal guard — deferred

An automatic shutdown on high CPU temperature was considered and is **not in v1**.

Reading SMC temperature on Apple Silicon needs private APIs, and a wrong threshold that
releases the assertion mid-build is its own bug. The timed override and the heartbeat
watchdog cover the same risk with far less machinery.

Revisit if real use shows the other guards are not enough.

## Uninstall must be exact

`make uninstall-daemon` restores the `displaysleep` values recorded in
`/usr/local/var/v-claw/original.json` at install time, then removes `disablesleep`.

After a full uninstall, `pmset -g custom` must match the baseline table in
[01-macos-behaviour.md](01-macos-behaviour.md). This is a test, not a hope.
