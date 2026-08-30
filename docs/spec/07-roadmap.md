# 07 — Build order and verification

## Build order

Ordered so that something works early, and so that the riskiest unknown is settled
before anything is built on top of it.

| # | Step | Result | Status |
|---|---|---|---|
| 0 | Probe cgo: assertions, power source, idle | All work. See [01](01-macos-behaviour.md) | **done** |
| 0 | Probe Swift: shielding window, `LAContext` | Builds with CLI tools, 90 KB | **done** |
| 0 | Probe `systray` API against the menu design | Everything needed exists | **done** |
| 1 | **Measure the clamshell rule.** Two lid tests | The fact the tier split rests on | next |
| 2 | Repo, `go.mod`, Makefile, empty tray icon | `make` builds and runs | |
| 3 | `internal/power` interface + `power_darwin.go` | Promote the probe. Add Linux and Windows stubs | |
| 4 | `internal/paths`, `internal/state` | Shared schema. No hardcoded paths | |
| 5 | Tray menu and the mode state machine | **Basic tier complete** | |
| 6 | `internal/pmsetctl` with read-back verify | | |
| 7 | `v-clawd`, the LaunchDaemon, `install-daemon.sh` | **Full tier complete** | |
| 8 | Icon SVGs, `make icons`, state variants | The icon tells the truth | |
| 9 | Timed override, heartbeat watchdog, LaunchAgent | Safety rules in force | |
| 10 | Swift helper, promoted from the probe | Virtual lock, `policy: none` | |
| 11 | `internal/lock` supervision, then `policy: auth` | Virtual lock complete | |
| 12 | `internal/diag`, `make diagnose` | Managed Macs become debuggable | |
| 13 | CLI | | |
| 14 | README, licence, make the repo public | | |

Step 1 gates the honesty of the basic-tier label. Step 9 gates safe daily use. Do not
run `always` mode with a closed lid before step 9 is done.

Steps 3 and 4 must land the platform boundary from
[08-cross-platform.md](08-cross-platform.md). Retrofitting it later is expensive, and
adding it now costs almost nothing.

## Step 1 in detail

Two unknowns, two tests. Both need the lid closed, so neither can be automated.

Setup for both: disconnect every external display and external keyboard, and connect the
power adapter.

### Test A — is the assertion enough?

`experiments/probe` already exists and does exactly this.

```sh
go run ./experiments/probe -hold      # holds PreventSystemSleep
pmset -g assertions | grep v-claw     # confirm, in another terminal
# close the lid, wait 5 minutes, open it
pmset -g log | grep -i -E "Entering Sleep|Wake from|Clamshell"
```

| Result | Meaning |
|---|---|
| No sleep event | The assertion alone blocks clamshell sleep. The basic tier delivers the headline feature with no admin, and the daemon becomes a fallback. |
| A sleep event | The assertion is not enough. The daemon is required, as the spec assumes. |

### Test B — is `disablesleep` still honoured?

The flag is undocumented and absent from `pmset -g cap`. Its presence in the binary
proves it parses, not that `powerd` still acts on it. If it is dead, the full tier has no
implementation on macOS.

```sh
sudo pmset -a disablesleep 1
pmset -g | grep -i disablesleep       # confirm it reads back as 1
# close the lid, wait 5 minutes, open it
pmset -g log | grep -i -E "Entering Sleep|Wake from"
sudo pmset -a disablesleep 0          # ALWAYS restore
```

| Result | Meaning |
|---|---|
| No sleep event | The flag works. The spec stands as written. |
| A sleep event | The flag is dead on macOS 26. Lid blocking then depends entirely on Test A, and if Test A also failed, the feature is not achievable and the spec needs rework. |

**Restore the flag afterwards.** Leaving `disablesleep 1` set is exactly the unsafe state
this whole project exists to prevent.

Record both results and the macOS build number in the README. Re-run after every major
macOS upgrade.

## Manual checks that could not be automated

`experiments/lockwin` builds, but its runtime behaviour is unverified because it covers
the screen. Run it and confirm:

```sh
swiftc -O experiments/lockwin/main.swift -o build/lockwin && ./build/lockwin
```

- Every screen is covered, including one plugged in while it is up.
- `Cmd+Tab`, `Cmd+Opt+Esc`, and `Cmd+H` do nothing.
- Mission Control and the hot corners do nothing, or the gap is recorded as a known
  limitation.
- Any key dismisses it.
- `LAContext deviceOwnerAuthentication` prints `true`.

## Verification

Run all of these before calling v1 done.

### Awake behaviour

- `pmset -g assertions | grep v-claw` lists the assertions while active, and lists
  nothing after `Off`.
- `pmset -g | grep -E "disablesleep|displaysleep"` matches the current mode.
- In `auto`, unplug the adapter. The icon changes and the assertions drop within 10 s.
- In `always`, close the lid on AC. The machine stays awake. Confirm afterwards with
  `pmset -g log`.

### Safety

- Set a 1 minute override. Confirm it reverts on its own.
- `kill -9` the app. Confirm the daemon releases `disablesleep` within 5 minutes.
- `launchctl bootout system/com.vclaw.daemon`. Confirm the machine is left clean.
- Corrupt `state.json` by hand. Confirm the daemon logs it and does not act on it.
- Write an unknown `mode` value. Confirm the daemon rejects it.

### Virtual lock

Full list in [04-virtual-lock.md](04-virtual-lock.md). The two that catch the most bugs:

- Plug in a second display **while locked**. Confirm it is covered immediately.
- `kill -9` the app while locked. Confirm the desktop returns and nobody is locked out.

### Install and uninstall

- `make install` with no `sudo` on an account with no admin rights. Confirm tier 0 runs.
- `make install-daemon`, then reboot. Confirm the daemon comes back.
- `make uninstall && sudo make uninstall-daemon`. Then `pmset -g custom` must match the
  baseline table in [01-macos-behaviour.md](01-macos-behaviour.md) exactly.

### Managed Mac

- Run `make diagnose` on a machine with MDM profiles. Confirm the report names the
  overriding profile rather than reporting a generic failure.

## Deferred past v1

| Item | Why not now |
|---|---|
| Linux | v2. logind makes it simpler than macOS. See [08-cross-platform.md](08-cross-platform.md). |
| Windows | v3. |
| Thermal guard from SMC temperature | Needs private APIs. The timed override and the watchdog cover the same risk. See [03-safety.md](03-safety.md). |
| Notarized prebuilt releases | Needs a paid Developer ID. Build from source works today. |
| Settings window | The menu is enough. |
| Schedules and calendar rules | No demand yet. |
| Homebrew tap | After the repo is public and the install path has settled. |

Build the **interface** for Linux and Windows in v1. Do not build the implementations.
An empty `power_linux.go` that returns `ErrUnsupported` is enough to prove the boundary
is real, and `GOOS=linux go build ./...` in CI is what keeps it honest.
