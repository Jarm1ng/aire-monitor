# macOS App Prototype

This repository now contains a local SwiftUI macOS prototype for monitoring AIRE.

## Run

Recommended:

```bash
./scripts/run_macos_app.sh
```

This builds a local app bundle at:

```text
.runtime/AIREMonitorApp.app
```

and launches it with macOS `open`, so the app can become the active foreground application and text fields receive keyboard focus.

On this machine, the launch script pins `SDKROOT` to the local `MacOSX15.4.sdk` and tolerates a known SwiftPM build database cleanup error if the executable was produced successfully. The full build log is written to:

```text
.runtime/swift-build.log
```

The raw SwiftPM launch command is still useful for debugging, but it can leave keyboard focus in Terminal on some macOS setups:

```bash
swift run --disable-sandbox AIREMonitorApp
```

Build without launching:

```bash
swift build --disable-sandbox
```

Desktop widget companion:

```bash
./scripts/run_desktop_widget.sh
```

This builds and launches:

```text
.runtime/AIREDesktopWidget.app
```

The widget is a lightweight macOS companion window intended to sit on the desktop. It shows GPU fleet usage, free GPU count, GPU node health, and the logged-in user's current jobs. It refreshes every 10 seconds and writes the latest successful snapshot to:

```text
.runtime/last_snapshot.json
```

If a refresh fails because the SSH control session is no longer alive, the widget keeps showing the cached snapshot and displays a short warning. Log in or refresh from the main app to restore a live SSH session.

The main app sidebar also includes a `Widget` button that opens the desktop widget.

This repository is currently built with Command Line Tools only, not full Xcode. A true macOS WidgetKit extension requires an Xcode app target and extension target, so the current implementation is a local desktop companion rather than a system Notification Center widget.

## Visual Design

The app uses macOS system materials for the main sidebar, dashboard cards, menu bar panel, and desktop widget shell. This gives the interface a glass-like layered feel while keeping dense monitoring content, tables, logs, paths, and quota numbers on readable surfaces. Motion is intentionally local: hover lift on cards, smooth meter changes, restrained status transitions, and animated detail surfaces inside the dashboard and menu panel.

Menu bar monitor:

When the main app is running, it also installs a compact native AppKit menu bar item. The top label is intentionally simple and low overhead: if a job is running, it shows the current job name and elapsed runtime; if multiple jobs are running, it shows the running count; if no job is running, it falls back to GPU availability such as `GPU 8`. The visible status text is self-drawn so it remains white across menu bar appearances, while the background stays transparent until the menu is open. Refresh, live, cached, offline, running-job, and GPU states are communicated with short text rather than a continuously animated SwiftUI status view. The tooltip includes running/pending counts, storage status, live/cached/offline state, and GPU fleet context. Clicking it opens a small monitoring panel with:

- live/cached/offline state
- running jobs, pending jobs, and storage risk summary tiles
- current running/pending jobs, including job name, job id, partition, state, elapsed/time limit, node or pending reason, and Slurm TRES resource summary
- enhanced home/scratch storage rows with percent used, free space, quota, limit, and file-count pressure when quota data is available
- GPU allocation as a secondary fleet summary
- quick actions for Refresh, Open, and Widget

The menu bar monitor uses the same shared `AppModel` as the main dashboard, so it follows the same 10-second read-only refresh loop and cached/offline behavior.

The app expects to be launched from this repository so it can find:

```text
scripts/aire_ssh_login.expect
scripts/aire_monitor_snapshot.py
```

The default project root is:

```text
/path/to/aire-monitor
```

The repository also includes the default SSH shape in:

```text
config/aire_ssh_config.example
```

The current app uses form fields to generate equivalent `ssh` options at runtime, so classmates can use their own username without editing this file.

## Login Flow

The app uses the local system `ssh` and `expect` tools. It does not install anything on AIRE and does not write remote files.

Default connection values:

```text
AIRE connection mode: local SSH alias
SSH alias: aire
AIRE host: aire.leeds.ac.uk
Jump host: rash.leeds.ac.uk
Username: <your-username>
Duo option: 1
```

Recommended mode is `Use local SSH alias` with alias `aire` when your local `~/.ssh/config` already contains the working jump-host path.

Other users have two options:

- create their own local SSH alias and keep `Use local SSH alias` enabled
- turn off `Use local SSH alias` and use explicit username, AIRE host, and jump host fields

Explicit mode assumes the same username is used for both `rash.leeds.ac.uk` and `aire.leeds.ac.uk`.

The password is not saved. It is passed to the local login helper through stdin for the current login attempt. The helper responds to password prompts and Duo option prompts, then leaves a local OpenSSH ControlMaster socket under:

```text
.runtime/ssh-control/
```

In local SSH alias mode, the app uses the `ControlPath` and `ProxyJump` from the user's `~/.ssh/config`. For the current machine, that is the most reliable path because `ssh aire` is already known to work.

In explicit mode, the app uses a relative OpenSSH `ControlPath` (`.runtime/ssh-control/%C`) because macOS Unix domain sockets have a short path-length limit. Do not change this to a long absolute path.

Follow-up refreshes use that local control socket with `BatchMode=yes`, so they should not repeatedly ask for password and Duo while the control connection is alive. When the main app starts, it loads the latest local cache first, starts a 10-second auto-refresh loop, then does one non-interactive refresh probe. If an existing SSH ControlMaster/session is usable, the app switches to live mode. If not, it stays in cached/offline mode and keeps retrying every 10 seconds until Login, a restored SSH session, or a successful manual Refresh restores live data.

If login fails, the app now shows a short diagnosis plus raw SSH output. For example, a `Connection timed out during banner exchange` after the jump host usually means the generated explicit ProxyJump path could not open the AIRE SSH banner; switch back to local SSH alias mode first.

## Current Views

The current UI is visualization-first. Tables are available through `Show Details`, but the default workflow uses cards, meters, state bars, and compact status indicators.

- Jobs, with visual summary cards and job cards by state
- Partitions, with visual partition cards and node-state bars
- Nodes, with a GPU-first dashboard plus visual sections for every node class:
  - GPU allocation summary
  - free GPU count
  - mixed and unavailable GPU node counts
  - GPU node cards with slot-level occupancy
  - CPU node cards with CPU and memory meters
  - high-memory node cards
  - teaching node cards
  - CPU usage, free memory, power, and load indicators where Slurm exposes them
- Detail tables are hidden by default and can be opened with `Show Details`
- Last refresh status
- Collection errors

## Branding

The app logo is stored locally in:

```text
assets/AIRELogo.png
assets/AIREMonitor.icns
```

The launch scripts copy these assets into both generated app bundles. `AIRELogo.png` is used inside the main app sidebar and desktop widget header; `AIREMonitor.icns` is used as the bundle icon through `CFBundleIconFile`.

## Cache, Notifications, and Job Details

The main app now keeps a local read-only cache under:

```text
.runtime/latest_snapshot.json
.runtime/job_state.json
.runtime/snapshot_history.json
```

While the main app is open, it refreshes in the background every 10 seconds and updates the cache after each successful read-only snapshot. If a refresh fails, the app keeps the latest cached snapshot visible, marks the session as cached/offline, keeps retrying, and avoids overwriting the cache with failed data.

The history file stores compact trend points from each successful snapshot. The Trends tab visualizes GPU availability, GPU allocation, job queue pressure, unavailable GPU nodes, and home/scratch storage pressure over time. The chart history is local only and capped at the newest 1440 points.

The Storage tab reads quota-backed storage data from read-only commands:

- `/users/<user>` through `quota -s`
- `/mnt/scratch` through `lfs quota -h -u "$USER" /mnt/scratch`

It visualizes used percentage, remaining GB/TB, quota limit, and file-count pressure where the server exposes file limits.

Task notifications are local macOS notifications. The app asks for notification permission, compares the previous job state in `.runtime/job_state.json` against the newest `squeue` snapshot, and only notifies when a job appears to have ended. Starting jobs and ordinary pending-to-running transitions are intentionally quiet. End notifications are sent when:

- a visible job reaches a terminal Slurm state such as `COMPLETED`, `FAILED`, `CANCELLED`, `TIMEOUT`, `OUT_OF_MEMORY`, or `NODE_FAIL`
- a previously visible non-terminal job leaves `squeue`

Notification copy uses the native macOS banner style with the AIRE Monitor app identity, a concise end-state subtitle, and a short body containing the job name, job id, partition, previous state, and why the app considers it finished.

Job cards in the Jobs view are clickable. The detail sheet combines `squeue` with read-only `scontrol show job -o` fields, including submit/start/end time, batch host, node list, requested/allocated TRES, work directory, command, stdout, and stderr paths when Slurm exposes them.

## Current Limitations

- The app bundle is generated locally under `.runtime/`; it is not signed or notarized yet.
- It assumes one username for both `rash.leeds.ac.uk` and `aire.leeds.ac.uk`.
- It relies on `/usr/bin/ssh`, `/usr/bin/expect`, and `/usr/bin/python3`.
- It only supports read-only monitoring.
- It does not store credentials in Keychain yet.

The next step is to add configurable refresh intervals, Keychain profiles, and richer final job status using `sacct` where available.
