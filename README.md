<h1 align="center">v-claw</h1>

<p align="center">
  <strong>Keeps your laptop awake while it is plugged in — even with the lid shut.</strong>
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-supported-success">
  <img alt="linux" src="https://img.shields.io/badge/Linux-planned-lightgrey">
  <img alt="windows" src="https://img.shields.io/badge/Windows-planned-lightgrey">
  <img alt="licence" src="https://img.shields.io/badge/licence-MIT-blue">
  <img alt="status" src="https://img.shields.io/badge/status-alpha-orange">
</p>

<p align="center">
  <img src="docs/images/menu.png" alt="v-claw menu bar" width="330" valign="top">
  &nbsp;&nbsp;
  <img src="docs/images/settings.png" alt="v-claw settings window" width="235" valign="top">
</p>

---

## What it does

Close the lid and your Mac sleeps. Leave it idle and the screen locks. That is usually
what you want — but not when something long-running is on the machine.

v-claw keeps it awake while the power adapter is connected, and lets go the moment you
unplug. The claw in your menu bar is green whenever it is holding.

- **Stays awake** — no idle sleep, no display sleep, no sleep when the lid shuts
- **No screen lock** — the screensaver never starts, so the lock never fires
- **Lets go on its own** — when you unplug, when a timer runs out, or if it crashes
- **Warns you** — a sound plays if you close the lid while it is still running
- **Privacy screen** — cover the display while you step away, without sleeping

## Install

macOS 13 or later. You need [Go](https://go.dev/dl/) and Xcode Command Line Tools
(`xcode-select --install`). Xcode itself is not needed.

```sh
git clone https://github.com/kamrul1157024/v-claw
cd v-claw
make install
```

It asks for your password once, to install a small background service. Nothing in the
app ever asks again.

**No admin rights?** That step is skipped and v-claw still works — it just cannot
guarantee the lid-close part. Add it later with `sudo make install-daemon`.

Want to see what runs as root before agreeing? `make explain` prints it.

## Using it

Click the claw in the menu bar. **Settings…** opens the window with everything in it.

```sh
v-claw open      # open the window
v-claw status    # what is happening right now
v-claw on 2h     # stay awake for two hours
v-claw auto      # awake only while plugged in
v-claw off
```

> [!TIP]
> Cannot find the icon? If your menu bar is full, macOS hides new icons behind the
> notch without telling you. `v-claw open` always works.

### What the icon means

<img src="docs/images/states.png" alt="v-claw icon states" width="400">

| | |
|---|---|
| **Grey hand** | Doing nothing |
| **Amber ring** | Waiting for you to plug in |
| **Green dot** | Awake right now |
| **Amber dot** | Awake, but the lid part is best effort |
| **Red dot** | Something is overriding v-claw — run `v-claw diagnose` |

## Careful with this

> [!WARNING]
> A laptop that cannot sleep will keep running in your bag and get hot.

That is the one real risk, so v-claw is built around it. The icon always shows the
truth, a sound plays when you shut the lid, and it lets go by itself if anything goes
wrong. Prefer **Awake for ▸** over **Always awake** when you can.

## The privacy screen

You can cover your displays while you step away, without letting the machine sleep.

> [!CAUTION]
> This is a privacy screen, not a real lock. It hides your screen from people walking
> past. It will not stop anyone determined. For that, use the macOS lock and accept
> that the display sleeps.

Unlock with any keypress, or with a password you set for v-claw. **It never asks for
your macOS password** — typing that into a full-screen window is a habit worth avoiding.

Forgot the password? Enter a code from your authenticator app, or restart the Mac.
Restarting clears it, and macOS asks for your real password on the way back in.

## When it does not work

Some Macs are managed by an employer, and that management can quietly override v-claw.

```sh
v-claw diagnose
```

It tells you exactly what is interfering rather than just failing.

## Uninstall

```sh
make uninstall
```

Puts your power settings back the way they were.

## More

- [Documentation](docs/spec/) — how it works, and why it is built this way
- [AGENTS.md](AGENTS.md) — rules for anyone, human or AI, changing this code
- Linux and Windows are planned; the groundwork is already in place

## Licence

MIT.
