# v-claw specification

A menu bar app that stops the laptop sleeping and locking while it runs on the power
adapter, and that can hold a virtual lock screen while you are away.

macOS is the only platform implemented today. Linux and Windows are planned, and
[08-cross-platform.md](08-cross-platform.md) covers what that already requires of the
current code.

Read [00-overview.md](00-overview.md) first. It carries the constraints that explain
every later decision.

| Document | Contents |
|---|---|
| [00-overview.md](00-overview.md) | The problem, the goals, the admin constraint, and the decisions made |
| [01-macos-behaviour.md](01-macos-behaviour.md) | Platform notes for macOS, measured on real hardware, plus the one open question |
| [02-architecture.md](02-architecture.md) | Three binaries, two tiers, and the state file |
| [03-safety.md](03-safety.md) | Thermal risk, release rules, and managed-Mac diagnostics |
| [04-virtual-lock.md](04-virtual-lock.md) | The privacy screen, and what it is not |
| [05-ui.md](05-ui.md) | The menu, the icon states, and the icon assets |
| [06-build-and-install.md](06-build-and-install.md) | Repo layout, Makefile, and the privilege split |
| [07-roadmap.md](07-roadmap.md) | Build order and verification |
| [08-cross-platform.md](08-cross-platform.md) | Linux and Windows, and what they force into v1 |

## The three ideas

**Ask for admin once.** Many people run managed Macs where admin arrives only by
request. v-claw takes admin at install and never again. It also works, in reduced form,
for a person who never gets admin at all. This produces the two-tier design.

**The failure mode is physical.** A closed lid on a machine that cannot sleep cooks in a
bag. So the state is always visible in the menu bar, and everything releases on its own.

**Say what is true.** The basic tier must not claim the full tier's guarantee. The
virtual lock is a privacy screen and must not be called a lock. A `pmset` value is only
reported after it is read back from the system.

## Status

Implemented on macOS. Linux and Windows to follow.

The platform boundary already exists in `internal/power` and `internal/paths`, and
cross-compilation in CI keeps it honest: nothing above `internal/power` may import `C`.

Three probes in `experiments/` are built and passing. They were written to retire the
riskiest assumptions before any real code is committed.

| Probe | Retires | Result |
|---|---|---|
| `experiments/probe` | Can Go reach IOKit for assertions, power source, and idle? | Yes, all three |
| `experiments/lockwin` | Can Swift build a shielding window without Xcode? | Yes, 90 KB |
| `experiments/tray` | Does `systray` support the menu design? | Yes, every construct |

Two unknowns remain, and both need a closed lid, so neither can be automated. They gate
everything else. The procedure is in [07-roadmap.md](07-roadmap.md).

1. Does a `PreventSystemSleep` assertion alone block lid-close sleep?
2. Is the undocumented `pmset disablesleep` flag still honoured on macOS 26?
