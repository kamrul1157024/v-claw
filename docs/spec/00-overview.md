# 00 — Overview

## The problem

A laptop sleeps when the lid closes. It also locks the screen after an idle delay.
This interrupts long-running work that must survive a closed lid, such as background
agents, builds, and remote sessions.

The manual fix is two `sudo pmset` commands. That fix has three faults:

1. You must remember to run it.
2. You must remember to undo it.
3. Nothing on screen tells you it is on.

Fault 3 is the dangerous one. A closed lid on a machine that cannot sleep traps heat.
In a bag, that is a real thermal risk.

## What v-claw does

v-claw is a menu bar app. It holds the machine awake, it shows that state in the menu
bar at all times, and it ties the state to the power adapter. It turns on when the
adapter is connected. It releases when the adapter is removed.

The name comes from the 3D-printed claw that props a laptop lid open. v-claw does the
same job in software.

## Goals

- Stop lid-close sleep while the machine runs on the power adapter.
- Stop the screen lock, without weakening the lock password.
- Cover the screen while you are away, without letting the machine sleep.
- Make the live state obvious at a glance.
- Release automatically, so a forgotten setting cannot cook the machine.
- Work for a person who never gets admin rights.

The third goal follows from the second. Keeping the display awake leaves the screen
readable by anyone who walks past. The virtual lock closes that hole, and it is
described in [04-virtual-lock.md](04-virtual-lock.md).

## Platforms

macOS is implemented. Linux and Windows follow.

Only macOS is supported today, but that must not paint the other two into a corner. The
two-tier design below is not a macOS idea. It holds on all three, because all three
separate "ask the OS to stay awake", which any user can do, from "change the lid-close
policy", which is privileged. On Linux the second one is free as well, through a logind
inhibitor.

[08-cross-platform.md](08-cross-platform.md) lists the four rules this puts on v1. The
main one is that all platform code sits behind one interface, and no macOS vocabulary
leaks above it.

## Non-goals

- Mobile and tablet platforms.
- A settings window. The menu and the lock screen are the whole interface.
- Replacing the real macOS lock. The virtual lock is a privacy screen, not a security
  boundary.
- Scheduling, calendar rules, and profiles. Not in v1.
- Distribution through the App Store.

## The admin constraint

Many people run Macs that an organisation manages. On those machines admin rights
arrive only by request, and only for a short window.

This shapes the whole design. Two rules follow:

> **Rule 1.** v-claw asks for admin once, at install, and never again.
>
> **Rule 2.** v-claw must still be useful to a person who never gets admin at all.

Rule 1 rules out a password prompt on each toggle. Rule 2 forces the two-tier design in
[02-architecture.md](02-architecture.md).

A third rule follows from the first two:

> **Rule 3.** The one privileged install step must be short enough for an IT reviewer
> to read and approve in a minute.

A vague request for admin gets denied. Three lines of `install` and `launchctl` get
approved.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Language | Go | One language for the app, the daemon, and the CLI. Static binaries. Toolchain already present. It is also the only candidate that compiles natively for all three target platforms from one codebase. |
| Lock window | A native helper process | Go has no good window binding on any platform. A helper keeps the native code isolated and lets it fail open. Verified: Swift + AppKit builds with Command Line Tools alone. |
| v1 scope | Both tiers | Lid-close blocking is the actual feature. Shipping without it misses the point. |
| Screen lock | Keep the display awake | Reversible, needs no password, and MDM rarely blocks it. Disabling the lock password weakens security and managed Macs often forbid it. |
| Repo | `~/v-claw` | Private at first, public later. |
| Distribution | `make install` from source | A locally built app carries no quarantine attribute, so Gatekeeper does not block it. No Developer ID and no notarization. |

### Why not Electron

v-claw's interface is a tray icon and a menu. On macOS a tray menu is an `NSMenu`, a
native object. Electron does not render it. Electron calls the same native API. So
Electron would ship Chromium and return no UI benefit.

It would also cost about 180 MB of disk and about 120 MB of idle RAM. An app whose
purpose is power management must not burn battery in the background.

The root daemon cannot be Electron either. It would be Node or shell. So Electron gives
two languages, not one.

Tauri remains the right answer if v-claw ever needs a real settings window.
