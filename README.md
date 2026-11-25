# Herdr Status Overlay

A native macOS floating panel for the Herdr core, showing live local and remote terminals in one aggregated view. It is read-only: it never starts, restarts, or stops Herdr core. Requires macOS 13+, Swift Command Line Tools, and Herdr core plus Herdr GUI (`hc` and `herdr-app`). No third-party dependencies.

## Build and run

```sh
swift build -c release
bin/open-overlay
```

`bin/open-overlay` starts the helper in the background and returns immediately. The helper connects only to the existing same-user Unix socket discovered from `$XDG_STATE_HOME/herdr-core/$HC_SESSION/core.lock` (defaults: `~/.local/state/herdr-core/default/core.lock`). Set `HERDR_OVERLAY_SOCKET_PATH` to override socket discovery. It handshakes with JSON-RPC generation 1, checks `server.status` once per connection, then subscribes to `events.subscribe` for terminal state. A separate pinned same-user socket queries `machine.list` at startup and every 15 seconds so disconnected remote mirrors are hidden; remote availability may therefore lag a disconnect by up to about 15 seconds. `terminal.list` is not used by the active overlay. No `hc` command is used for polling or lifecycle. The helper exits when that exact core process exits, including a crash; quitting the overlay does not affect core or agents.

Heartbeats keep an unchanged snapshot fresh. After 45 seconds without a valid event or heartbeat, the source is invalidated and reconnects with backoff. Reconnect, `missed`, and wake take a new completion baseline, so recovered `done` states do not cause false celebrations. A failed machine monitor hides remotes, not local agents; remote sync readiness survives a local socket reconnect.

Overlay state is stored in `$HERDR_OVERLAY_STATE_DIR` when set; otherwise `$XDG_STATE_HOME/herdr-status-overlay`, or `~/Library/Application Support/HerdrStatusOverlay`. On first launch, an existing previous plugin `panel.json` is copied once into the standalone directory if no destination exists; the original is left untouched. This also applies to an explicit state directory; a failed copy stops startup instead of using the original as writable state. Logs are `overlay.log` in that directory. Duplicate helpers are prevented by a private instance lock.

Optional login autostart is opt-in and passive:

```sh
bin/install-autostart      # creates this repo's LaunchAgent; requires a release build
bin/uninstall-autostart
```

The supervisor watches for an already-running core, retries failed startup attempts but starts only one successful overlay per observed core PID, and waits for a different PID after the overlay is manually quit. It never starts core, opens a terminal, or focuses an app. Installation was not run during development.

## Panel behavior

Each live, reported agent/child with a status has a row; unreported shells, reported terminals without status, and historical finished terminals are omitted. Local and remote terminals are included in the same aggregated snapshot and retain their stable address. Unknown future status strings map safely to unknown; `error` and `blocked` use the existing STOP appearance. Completion follows the core's official `herdr.seen` label: when both unsigned `turn` and `herdr.seen` are valid, `turn > seen` is done and `turn <= seen` is idle. Missing or malformed labels are never treated as read; raw `done` remains pending until a valid receipt or working status arrives. Working and blocked override read receipts, while turn-only updates never celebrate. Labels are read-only and status celebrations occur only on a continuous fresh transition to raw `done`.

When Auto-hide is collapsed, a small translucent badge beside the dog shows counts for working, blocked, and done agents, plus a separate clock icon and count for running Pi background jobs. It disappears when fresh sources have no active statuses or background jobs; unavailable data still has an indicator.

In Auto-hide mode, the whole panel (including the dog) disappears after 30 seconds with the pointer away and nothing requiring attention: no unread results, working or blocked agents, or running Pi background jobs. It comes back as soon as there is activity or status data becomes unavailable. Manual mode is unchanged.

The existing floating panel, dog animations, pair activities, placement, auto-hide, scale, and visibility settings remain. Clicking a row runs the bounded `herdr-app do agent.focus --terminal <address>` command and activates the actual Herdr GUI bundle (`dev.herdr.app`), not a terminal emulator. Focus failures beep.

## Optional: Pi background jobs

In a Herdr terminal, start Pi with the adapter enabled:

```sh
pi -e /absolute/path/to/herdr-status-overlay/integrations/pi-background-overlay.mjs
```

The adapter listens to the installed `pi-background-tasks` and `pi-subagents` extensions. It publishes only aggregate counts on its own terminal, using `hc label` on changes; the overlay reads them from the existing Herdr event stream. The expanded Pi row shows counts such as `2 in background · 1 finished`. Running background jobs keep the solo work animation active even if Pi is idle, without changing the session status, agent counts, or pair activity. Clicking the row still opens the Pi session. Claude and other agents are unchanged.

Enable the adapter on each machine where Pi runs. The terminal must be managed by Herdr and `hc` must be on Pi's `PATH`. The adapter does not forward commands, logs, or results.
Finished counts cover runs observed since the adapter started in the current session, including failures and cancellations; they are not a count of successful results.
If the subagent extension truncates its snapshot, the running count is shown as a lower bound (for example, `20+ in background`).

## Development checks

```sh
swift run OverlaySelfCheck
node --test scripts/check-pi-background-overlay.mjs
swift scripts/check-overlay-launch.swift
swift scripts/check-overlay-autostart.swift
sh scripts/check-overlay-layout.sh
```

The headless checks use a fake Unix JSON-RPC server and fake child processes; they do not query or control a real Herdr core or show the GUI. The layout script exercises AppKit with a hidden window.

- `Sources/OverlayCore`: safe local socket discovery, read-only RPC adapter, parser, snapshots, completion rules, process runner.
- `Sources/OverlayApp`: AppKit panel and helper/supervisor entry point.
- `Sources/OverlaySelfCheck`: headless checks.
- `bin/`: manual launcher and optional LaunchAgent installer/uninstaller.
