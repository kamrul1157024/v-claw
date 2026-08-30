# Rules for changing v-claw

For anyone working on this code, human or AI. Every rule below exists because breaking
it caused a real bug, several of them shipped to a real machine.

Read this before changing behaviour. The full reasoning is in [docs/spec](docs/spec/).

---

## The thing that can actually hurt someone

A laptop that cannot sleep keeps running with the lid shut. In a bag it gets hot and the
battery drains flat. There is no screen, no sound by default, and no other symptom.

Everything else here is a preference. This is the one that matters.

- The live state must always be visible, and must reflect what was **read back** from
  the system, never what the code intended.
- Every hold must release on its own: on unplug, on a timer, and when the app stops
  sending a heartbeat.
- Never claim a guarantee that is not in place. "Best effort" must say so.

## The virtual lock

**It is a privacy screen, not a security boundary.** Do not describe it as a lock in the
UI, and do not add anything that implies otherwise.

**No escape valves. None.** No auto-unlock after N failures, no unlock when something
looks broken, no timeout that opens it. A valve that fires when something goes wrong is
a valve an attacker can provoke — that is exactly how the Touch ID option became
defeatable, and why it was removed.

Safety measures go *before* the lock, not after. Refusing to create a broken lock is
fine. Opening an existing one never is.

Recovery is a restart, which macOS authenticates, or a TOTP code from the user's phone.
Both require something the user has. Neither can be triggered by breaking the app.

Related rules:

- Never ask for the macOS account password. Typing a login password into a full-screen
  window is the shape of a phishing attack.
- The lock password never leaves the Swift helper — not over the protocol, not into a
  log, not into `state.json`.
- Store a salted hash, never the password.

## The state file is untrusted input

`state.json` is writable by an unprivileged user and read by a root daemon. Treat every
field as hostile.

- Validate against a closed set of values. Reject, never repair.
- Never let a value from the file reach a shell. Build argument lists from typed
  constants.
- Absolute paths for every binary the daemon runs.

## Privileges

Ask for admin **once**, at install, never again. Many people run managed machines where
admin arrives only by request and only briefly.

- `make install-app` must never need sudo.
- The privileged install script must stay short enough to read in a minute. No network,
  no downloads.
- It must be atomic: roll back everything on failure, and verify the service is actually
  running before reporting success. An earlier version left a root daemon running while
  printing "helper not installed".

## Permissions we will never request

Screen Recording, Input Monitoring, Full Disk Access, Camera, Microphone, Location.

This is a design constraint, not marketing. Idle time uses
`CGEventSourceSecondsSinceLastEventType` specifically because an event tap would need
Accessibility and reads like a keylogger to anyone reviewing the app.

## Cross-platform

macOS is implemented; Linux and Windows are planned. The boundary already exists.

- Nothing above `internal/power` may import `C`.
- No macOS vocabulary above that boundary. Callers say `block_lid_sleep`, never
  `disablesleep`.
- Never hardcode a path. Use `internal/paths`.
- `GOOS=linux` and `GOOS=windows` builds run in CI and must keep passing.

## Testing

Unit tests here have a poor record. Both lock bugs that reached the user passed every
test they had:

- `LockPassword` passed everything while the window it lived in could not receive
  keystrokes.
- TOTP matched the RFC vectors while the field it was typed into was being deleted
  underneath it.

So:

- **Test the integration, not just the component.** If a feature has a UI, exercise it
  through the UI.
- Anything involving the lock screen must be driven by a harness that releases itself
  over stdin, so a bug cannot trap the person testing it.
- Prove the negative case. A test that passes on correct code but was never seen to fail
  on broken code has not been shown to work.

## Diagnosing

Measure before theorising. Several bugs here took three wrong explanations before
someone printed the actual value:

- `disablesleep` cannot be read from `pmset` at all — only from IORegistry. Verifying it
  against pmset output reported failure on every successful write.
- `pmset -g` reports only the power source currently in use, so checking a scoped write
  against it fails whenever the other source is active.
- A recovery code kept being rejected because the phone's clock was 30 seconds fast, not
  because of anything in the code.

`experiments/` holds small programs that answer these questions directly. Add to it.

## Style

- Comments explain **why**, never what. If removing it would not confuse anyone, delete
  it.
- Do not name the current task, PR, or bug in a comment. That belongs in the commit.
- Fix root causes. Do not work around a failure by disabling the check that found it.
