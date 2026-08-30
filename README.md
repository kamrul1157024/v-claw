<h1 align="center">v-claw</h1>

<p align="center">
  <strong>A menu bar app that holds your laptop open.</strong><br>
  Stops the machine sleeping when the lid closes, stops the screen locking,<br>
  and ties both to the power adapter.
</p>

<p align="center">
  <img alt="platforms" src="https://img.shields.io/badge/macOS-supported-success">
  <img alt="linux" src="https://img.shields.io/badge/Linux-planned-lightgrey">
  <img alt="windows" src="https://img.shields.io/badge/Windows-planned-lightgrey">
  <img alt="language" src="https://img.shields.io/badge/Go-1.24-00ADD8">
  <img alt="licence" src="https://img.shields.io/badge/licence-MIT-blue">
  <img alt="status" src="https://img.shields.io/badge/status-alpha-orange">
</p>

---

## Why it is called v-claw

<img src="docs/images/claw.png" alt="A 3D-printed claw propping a laptop lid open" width="260" align="right">

People 3D-print a little claw to prop a laptop lid open, so the machine keeps running
while the agent works.

v-claw does the same job in software. No plastic required.

Plug in, and it engages. Unplug, and it releases. The menu bar always shows which.

<br clear="right">

## What it does

| | |
|---|---|
| **Stays awake on the adapter** | Blocks idle sleep, display sleep, and lid-close sleep while plugged in |
| **Stops the screen lock** | Keeps the display awake, so the screensaver never starts and the lock never fires |
| **Virtual lock** | Covers the screen while you are away, without letting the machine sleep |
| **Releases on its own** | On unplug, on a timer, and when the app stops responding |
| **Works without admin** | Most of it needs no privileges at all |

## Install

> [!NOTE]
> **macOS is the only platform supported today.** Linux and Windows are on the way, and
> the platform boundary is already in the code. See [Platforms](#platforms).

```sh
git clone https://github.com/kamrul1157024/v-claw
cd v-claw
make install
```

`make install` does both. It prompts for your password **once**, for the helper. No
toggle in the app ever asks again.

If you cannot get admin rights, that step is skipped and you still get a working app:
idle sleep and display sleep are blocked, and lid-close blocking becomes best effort.
Add the helper later with `sudo make install-daemon`, or skip it deliberately with
`make install-app`.

`make install` builds from source, so the app carries no quarantine attribute and
Gatekeeper does not block it. No Developer ID and no notarization are needed.

**Requirements:** macOS 13+, Go 1.24+, and Xcode Command Line Tools. Xcode itself is
not required.

### Why only one password prompt

Many people run machines that an organisation manages, where admin rights arrive only
by request and only for a short window.

So v-claw asks for admin **once**, at install, and never again. Only one small service
is privileged, and everything else runs as you. The privileged install script is three
lines, and you can show an IT reviewer exactly what it does before asking:

```sh
make explain
```

| Target | Privilege | Installs |
|---|---|---|
| `make install` | one prompt | Everything. Skips the helper if admin is refused. |
| `make install-app` | none | App and CLI only |
| `make install-daemon` | sudo | The helper only |

## Usage

Two front ends, same state. The window is the primary one.

```sh
v-claw open      # raise the control panel
```

> [!TIP]
> If you cannot find the icon in your menu bar, it is probably not your fault. On a Mac
> with a notch, macOS silently hides status items behind it once the bar is full, with
> no warning. `v-claw open` always works.

### Menu bar

```
 Status: AC Power — awake (full)
 ────────────────────────────────
  ○ Off
  ○ Always awake
  ● Auto (on AC)
 ────────────────────────────────
  ☑ Block lid sleep
  ☑ Keep display on
 ────────────────────────────────
  Awake for              ▸
 ────────────────────────────────
  Lock screen now
  Virtual lock           ▸
 ────────────────────────────────
  Quit v-claw
```

### Control panel

Everything the menu has, plus the live status, the tier, and why lid blocking is
unavailable when it is. Reached from the menu, or with `v-claw open`.

### Permissions

v-claw asks for almost nothing, and the permissions window says so explicitly:

| Permission | | Why |
|---|---|---|
| Notifications | needed | Tell you when v-claw releases on its own |
| Accessibility | optional | Only for the global lock hotkey |
| Screen Recording | **never** | It does not read your screen |
| Input Monitoring | **never** | Idle time is measured without an event tap |
| Full Disk, Camera, Mic, Location | **never** | |

That last group is a design constraint, not a promise. An event tap would have been the
easy way to measure idle time; it was rejected because it needs Accessibility and looks
like a keylogger to anyone reviewing the app.

### Icon states

The hand never changes. The badge tells you what is happening.

<img src="docs/images/states.png" alt="v-claw icon states: off, armed, active, basic, overridden" width="400">

| | State | Badge | Meaning |
|---|---|---|---|
| 1 | **Off** | grey, hand greyed out | v-claw is changing nothing |
| 2 | **Armed** | amber, hollow | Auto mode, on battery, waiting for the adapter |
| 3 | **Active** | green | Sleep is blocked right now |
| 4 | **Basic** | amber, solid | Holding, but lid blocking is best effort — the helper is not installed |
| 5 | **Overridden** | red | Something is overriding v-claw. Run `v-claw diagnose` |

Three signals carry the state — hand colour, badge colour, and badge fill — so none is
load-bearing on its own, and the states stay readable at 18 px and without colour
vision.

### Command line

```sh
v-claw status        # what is active right now
v-claw on 2h         # always awake, for two hours
v-claw auto          # awake only on the adapter
v-claw off
v-claw diagnose      # full report, including managed-Mac overrides
```

The menu bar app picks up CLI changes within a few seconds, and vice versa.

## Safety

> [!WARNING]
> A closed lid on a machine that cannot sleep traps heat. In a bag, that is a real risk.

The failure mode here is silent and physical, so v-claw is built around it:

- The menu bar icon always shows the live state. Filled means active.
- Everything releases on its own: on unplug, when a timer expires, and when the app
  stops sending a heartbeat.
- The daemon releases within five minutes if the app crashes, so root can never be left
  holding the machine awake with no UI to turn it off.
- `make uninstall-daemon` restores the settings recorded before v-claw first ran.

Use `Awake for ▸` rather than `Always awake` when you can.

## The virtual lock is not a lock

> [!CAUTION]
> It is a **privacy screen**, not a security boundary.

It covers your displays so nothing private is readable, and it keeps the machine awake
while it does. That is the point: the real macOS lock is tied to display sleep, and
display sleep is what v-claw is preventing.

But it is an ordinary window drawn by an ordinary user process. Anyone with physical
access defeats it. **If you need a real security boundary, use the macOS lock and accept
the display sleep.**

Two unlock policies:

| Policy | Dismissed by | Use for |
|---|---|---|
| **Any key** | any key or click | A privacy screen. Coffee shop, shared desk. |
| **v-claw password** | a secret you set | Stops a colleague. Still not an attacker. |

**v-claw does not use your macOS password, deliberately.** Typing a login password into
a full-screen window drawn by some app is exactly what a screen-locker phishing attack
looks like, and that is not a habit worth building. A Touch ID option existed and was
removed: the system prompt has a Cancel button, so it needed a fail-open valve, and that
valve was itself a bypass — cancel three times and the lock opened.

The password is stored as a salted PBKDF2 hash in the login Keychain, never in plain
text and never in `state.json`.

**Forgot it? Restart the Mac.** The password is bound to the current boot, so a restart
clears it. That is the whole recovery story, and it works while you are staring at the
locked screen — no terminal and no second machine. The trade is that you set it again
after each restart, which on a machine kept awake for days is rare.

## On a managed Mac

MDM can defeat v-claw in ways that look like bugs. It will tell you which:

```sh
v-claw diagnose
```

The report names the cause — a profile forcing an immediate lock, a reverted `pmset`
write, a blocked LaunchDaemon — instead of failing silently.

## How it works

Three binaries share one state file. No XPC, no custom IPC.

```
v-claw.app   you    Menu bar UI. Holds IOKit assertions. Writes state.json.
v-clawd      root   LaunchDaemon. The only privileged part. Applies pmset.
v-claw       you    CLI. Same state file.
```

Two capability tiers:

| Tier | Admin | Idle sleep | Display sleep | Lid close |
|---|---|---|---|---|
| **Basic** | none | blocked | blocked | best effort |
| **Full** | once, at install | blocked | blocked | guaranteed |

Full specification in [docs/spec](docs/spec/).

## Platforms

v-claw is built to run everywhere. macOS is the only platform supported today; the
other two are planned, and the platform boundary already exists in the code and is
enforced by cross-compilation in CI.

| Platform | Status | Stay awake | Lid blocking |
|---|---|---|---|
| **macOS** | **supported** | IOKit assertions | `pmset disablesleep`, needs the helper |
| Linux | planned | logind `Inhibit` | logind `handle-lid-switch` — **needs no root at all** |
| Windows | planned | `SetThreadExecutionState` | power-scheme `LIDACTION`, needs admin |

The two-tier model is not a macOS idea. All three systems separate "ask the OS to stay
awake", which any user can do, from "change the lid-close policy", which is privileged.
On Linux even the second one is free, so both tiers arrive at once.

Details in [docs/spec/08-cross-platform.md](docs/spec/08-cross-platform.md).

## Uninstall

```sh
make uninstall
```

Removes everything and restores the power settings recorded before v-claw first ran.

## Licence

MIT.
