# macOS App Internals

This document describes how the SwiftUI macOS app, the menu bar monitor, and the desktop widget actually work: the build system, the connection architecture, the status protocol, the local cache, and the UI.

## Build and Run

Recommended:

```bash
./scripts/run_macos_app.sh
```

This builds a local app bundle at:

```text
.runtime/AIREMonitorApp.app
```

and launches it with macOS `open`, so the app can become the active foreground application and text fields receive keyboard focus.

Build system notes:

- `SDKROOT` selection: the launch scripts prefer the pinned Command Line Tools SDK (`/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk`) when it exists, and otherwise fall back to `xcrun --show-sdk-path --sdk macosx`, so the scripts work on machines with a different SDK version. An already-exported `SDKROOT` is respected.
- Build directory: SwiftPM builds into the per-user Darwin temp directory (`getconf DARWIN_USER_TEMP_DIR`, mode 700, never shared or world-writable) rather than the project volume. Some backup/sync tools watching the project directory break llbuild's SQLite database mid-build; the per-user temp volume is immune. Override the location with `AIRE_SWIFTPM_BUILD_DIR`.
- Build-error tolerance: some toolchain/macOS combinations fail the final `build.db` write-back ("disk I/O error") after a fully successful compile. The scripts accept the build only when the log contains `Build complete!` **and** the produced binary is fresh.
- The full build log is written to `.runtime/swift-build.log` (widget: `.runtime/swift-widget-build.log`).

The raw SwiftPM commands are still useful for debugging:

```bash
swift run --disable-sandbox AIREMonitorApp   # can leave keyboard focus in Terminal
swift build --disable-sandbox                # build without launching
```

Desktop widget companion:

```bash
./scripts/run_desktop_widget.sh
```

This builds and launches `.runtime/AIREDesktopWidget.app`. Both scripts share the same SwiftPM scratch directory, so they reuse each other's build products.

This repository is currently built with Command Line Tools only, not full Xcode. A true macOS WidgetKit extension requires an Xcode app target and extension target, so the current implementation is a local desktop companion rather than a system Notification Center widget.

## Project-Root Resolution

The app needs the repository checkout to find `scripts/aire_ssh_login.expect` and `scripts/aire_monitor_snapshot.py`. Both the main app and the widget resolve the project root in this order:

1. `AIRE_PROJECT_ROOT` environment variable (if it contains `scripts/aire_monitor_snapshot.py`)
2. the current working directory (same check)
3. the grandparent directory of the app bundle — this makes the generated bundles under `.runtime/` self-locating, because `.runtime/AIREMonitorApp.app/../..` is the repository root

The main app also exposes a `Project root` text field in the sidebar, so the path can be corrected at runtime without relaunching. If the resolved root does not contain the snapshot script, the app shows an explicit error instead of failing silently.

## Connection Architecture

The app uses the local system `ssh` and `expect` tools. It does not install anything on AIRE and never writes remote files on its own (the interactive Terminal, below, runs whatever the user types). Login is performed by helper scripts that the app drives as child processes; the password is written to each helper as the **first line of stdin** and never appears in any argv or app-set child environment.

### Routes

The sidebar offers exactly two connection routes. **Both are explicit and username-based**: the app generates the ssh options itself from the form fields (username, AIRE host, optional jump host) and manages its own ControlMaster sockets under `~/.ssh/ctl/` (short hashed names). The app does not use a `~/.ssh/config` alias.

- **Direct (VPN)** (`directVPN`): connects straight to `aire.leeds.ac.uk` over the University VPN (Ivanti) — one Duo approval.
- **Via rash jump host** (`rashJump`): adds a jump leg through `rash.leeds.ac.uk`, so it works off-VPN — two Duo approvals (once for rash, once for AIRE).

The rash route assumes the same username is valid on both `rash.leeds.ac.uk` and `aire.leeds.ac.uk`.

### Login sequence

1. **Expect helper** — `MonitorService.login` runs `scripts/aire_ssh_login.expect` with the password on stdin and `AIRE_SKIP_TARGET=1` set, so the helper never authenticates AIRE directly. On the **rash route** it authenticates only the **jump-host ControlMaster** and then exits; the jump master lives at `~/.ssh/ctl/jump-<hash>.sock`. On the **direct route** there is no jump leg, so the helper has nothing to pre-authenticate.
2. **AIRE master starter** — the app then runs `scripts/aire_start_target_master.zsh`, again passing the password as the first stdin line (the script reads it with `IFS= read -rs`; the legacy `AIRE_PASSWORD` environment variable is accepted as a fallback and immediately scrubbed). The starter:
   - tears down any previous master for the same socket (`ssh -O exit`, socket removal, pid-file kill, and a verified process-pattern kill that only matches an `ssh` process whose *first* `ControlPath` option is exactly the managed socket),
   - launches a detached `ssh -f` ControlMaster to AIRE (`ControlPersist=24h`, `NumberOfPasswordPrompts=1`) — connecting straight to `aire.leeds.ac.uk` on the direct route, or reusing the existing jump socket through a `ProxyCommand` on the rash route,
   - answers the password and Duo prompts through `SSH_ASKPASS` (`scripts/aire_ssh_askpass.sh`) — the secret is exported only around this single ssh invocation and dropped immediately afterwards,
   - polls the socket (`ssh -O check`, then a full read-only verification) for up to 90 seconds while the user approves the Duo push,
   - records the master's pid in `.runtime/aire_master_ssh.pid`.
3. **Keepalive** — after verification the starter launches `scripts/aire_target_keepalive.zsh` through the detach helper `scripts/aire_start_background_ssh.zsh`. The keepalive exercises the master every 5 seconds with a no-op command. It exits **cleanly** as soon as the master is gone or unresponsive (3 consecutive failures): nothing supervises it, so a dead master can never turn into a reconnect loop that hammers the cluster. (Older releases used launchd for this and crash-looped; the starter removes any leftover launchd job.)

Follow-up refreshes use the control socket with `BatchMode=yes`, so they never prompt for password or Duo while the master is alive.

### Per-stage runtime files

```text
~/.ssh/ctl/jump-<hash>.sock                           jump-host ControlMaster socket (rash route only)
~/.ssh/ctl/aire-<hash>.sock                           AIRE ControlMaster socket (both routes)
.runtime/aire_master_ssh.log                          AIRE master ssh output
.runtime/aire_master_ssh.pid                          AIRE master pid (for verified teardown)
.runtime/aire_master_starter.log                      detached starter output (expect path)
.runtime/aire_master_keepalive.log                    keepalive heartbeat log
.runtime/aire_master_keepalive.pid                    keepalive pid
.runtime/aire_master_keepalive_starter.log            keepalive starter output
.runtime/login_debug.log                              per-login stdout/stderr transcript
.runtime/aire_askpass.log                             opt-in redacted askpass log (AIRE_DEBUG=1 only)
```

Control sockets live in `~/.ssh/ctl/` (mode 700) with short SHA256-hashed names: macOS Unix domain socket paths are capped at 104 bytes and ssh appends a random suffix during setup, so socket paths must stay short and independent of how deeply the project is nested. Do not move them to long project-relative paths.

### The AIRE-STATUS protocol

The helper scripts report login milestones on stdout as machine-readable lines:

```text
AIRE-STATUS: starting AIRE authentication
AIRE-STATUS: password sent, waiting for Duo approval on your phone (AIRE)
AIRE-STATUS: waiting for Duo approval on your phone (AIRE)
AIRE-STATUS: connected to AIRE
```

`MonitorService` streams child stdout line-by-line as it arrives, filters for the `AIRE-STATUS: ` prefix, and forwards the message to `AppModel.loginProgress` (a `@Published` property). The sidebar shows the current milestone in a login-progress banner, so the user can see the difference between "type your password was wrong" and "go approve the Duo push".

### Exit codes and failure diagnosis

- **13** — the remote host presented a **second password prompt**, which means the first password was rejected. The expect helper and the starter both use this code, and `MonitorService.explainSSHFailure` maps it to a clear "password was rejected — re-enter it" message with a lockout warning. `NumberOfPasswordPrompts=1` should normally prevent a resend entirely; exit 13 is the guard for keyboard-interactive re-prompts.
- **124** — timed out waiting for a prompt (usually a missed Duo push).
- Other failures are matched against common ssh error text (banner-exchange timeout through the jump host, `Permission denied`, unresolvable hostname, ...) and shown with a short diagnosis plus the raw ssh output.

### Refresh loop and backoff

When the main app starts, it loads the latest local cache first, starts a 10-second auto-refresh loop, then does one non-interactive refresh probe. If an existing ControlMaster is usable, the app switches to live mode; otherwise it stays cached/offline and keeps retrying.

While refreshes keep failing, the interval backs off exponentially (10s, 20s, 40s, capped at 60s) and the current cadence is displayed in the status line. A single failed refresh only marks the data as cached/stale; the session is dropped to logged-out only after **3 consecutive failures**. A successful refresh resets both the counter and the interval.

A login invalidates any in-flight refresh so it cannot run over the same ControlMaster socket while the session is being rebuilt.

### Passwords and Keychain

Passwords are never written to project files. With `Remember in Keychain` enabled, the password is saved to the user's macOS Keychain after a successful login (device-only, only while unlocked) under a per-connection account, and subsequent logins can use the saved password without retyping. The sidebar offers a `Forget` button that deletes the saved item. Changing any connection field triggers a debounced (300 ms) re-check of whether a saved password exists for the new combination. See [SECURITY.md](SECURITY.md) for the exact Keychain attributes and account naming.

After a successful login the app writes a **password-free** connection profile to `.runtime/connection_profile.json`; the desktop widget reads it so its fallback collection follows the same route (direct or rash jump) as the main app.

## Terminal

The Terminal tab embeds real SSH sessions (SwiftTerm's `LocalProcessTerminalView`) inside the app. Sessions are plain `/usr/bin/ssh -tt` child processes that **multiplex over the app's existing ControlMaster session**, so opening a terminal never re-authenticates and never prompts for password or Duo. Both routes bind directly to the app-managed socket under `~/.ssh/ctl/`:

```text
ssh -tt -S <control-socket> -o User=<user> -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no <host>
```

Before starting a session the app pre-flights the master with `ssh -S <socket> -O check`; if the master is gone it prints "SSH master is not running — reconnect from the app first" inside the terminal instead of launching ssh (a `ConnectTimeout=5` on the argument list bounds any residual fallback connection). **The app never types passwords into a terminal**; there is no code path that feeds credentials to a terminal session — if the master is gone, the user logs in again through the normal sidebar flow.

Session management (`TerminalManager` / `TerminalSession`):

- Multiple sessions in tabs; sessions and their ssh processes survive switching to other dashboard tabs.
- Quick-command chips (`squeue --me`, `sinfo`, `quota -s`, `sinfo -N -p gpu`, `htop`) type into the active live shell when one exists, otherwise run in a fresh dedicated session; `htop` always gets its own session so it never types into another full-screen program.
- The Jobs detail sheet has two terminal-backed actions: **Tail output** opens a session running `tail -n 200 -F` on the job's stdout path (shell-quoted; `-F` waits for the file, and the button is disabled while the job is still pending), and **Cancel job** runs `scancel <jobid>` over the same ControlMaster via `MonitorService.runRemoteCommand` — only after an explicit confirmation alert, with the result shown inline.
- The Nodes tab offers **Open shell on login node**, which focuses an existing live shell or opens one.
- An exited session can be restarted (same ssh invocation, same view). **Closing a session terminates its ssh child process**, so closed tabs never leave orphaned `ssh` processes behind.

## Files

The Files tab (`RemoteFileService` / `FileBrowserModel` / `FilesDashboard`) is a Finder-like browser over the same authenticated session: breadcrumb navigation, upload (file picker or drag-and-drop), download, rename, new folder, text preview, and delete. Every operation is user-initiated and runs through `MonitorService.runRemoteCommand` / `runTransfer`, which pre-flight the ControlMaster with `ssh -O check` so a dead session fails instantly with a readable error instead of hanging.

- **Listing protocol — `ls` is never parsed.** Directory listings run a small python script on the login node (`python3 -c <script> <path> <flag>`) that emits exactly one JSON object, which the app decodes. Parsing `ls` output can never be made safe: filenames may contain newlines, tabs, quotes, or invalid UTF-8 that corrupt any text-format listing. In the JSON protocol the target path travels as a python `argv` element (never interpolated into the script body), undecodable names are sanitized to U+FFFD so the payload always parses, `~` and symlinked parents are resolved server-side, and listings are capped at 4000 entries with an explicit truncation flag shown in the UI.
- **Transfers.** Uploads and downloads are local `scp` invocations (OpenSSH 9+, SFTP mode) bound to the existing ControlMaster — the app-managed socket under `~/.ssh/ctl/` — so transfers never re-prompt for password or Duo. scp-over-SFTP does not shell-expand remote paths, so the remote spec is passed as a single argv element with no extra quoting layer. Download names are uniquified locally (`name (2).ext`), and transfer timeouts scale with file size.
- **Trash-first deletion.** The default delete is a plain `mv` into a fresh `~/.aire-trash/<timestamp>/` directory on the server, so it is recoverable with a `mv` back. The trash is **not auto-expired** — users empty it themselves from a terminal when they choose. `Delete Permanently` (`rm -rf`) exists as a separate action behind a two-step confirmation dialog.
- **Injection defenses.** Remote file names are untrusted data end-to-end: every value interpolated into a remote shell command goes through a single-quote `shellQuote` (`'` becomes `'\''`), every path argument is preceded by a `--` separator so leading-dash names can never become flags, and trash/permanent delete independently refuse `/`, `~`, the home directory itself, and anything that is not an absolute path — defense in depth beneath the UI confirmations.
- **Integrations.** The Jobs detail sheet has a **Browse workdir** action that opens the Files tab at the job's working directory; a folder's context menu offers **Open Shell Here**, which opens a terminal tab with a shell landed in that directory; and the text-preview sheet offers **Open in Terminal (vim)** on the previewed file.

## Desktop Widget Data Flow

The widget's primary data path is **file watching, not SSH**: it watches `.runtime/latest_snapshot.json`, the cache file the main app rewrites after every successful refresh.

- It watches the `.runtime` **directory** with a dispatch source (the main app replaces the snapshot atomically via write+rename, which a file-bound watcher would miss) and additionally polls every 2 seconds as a safety net.
- A snapshot older than **30 seconds** is considered stale. While the file is fresh the widget shows `live` and never opens its own SSH connection, so it cannot double-collect while the main app is running.
- Only when the file is missing or stale does the widget fall back to running `scripts/aire_monitor_snapshot.py` itself (at most every 10 seconds), using the route from `.runtime/connection_profile.json`. If the main app writes a newer snapshot while a fallback collection is in flight, the newer data wins.
- If both paths fail, the widget keeps showing the cached snapshot with a `cached`/`offline` badge and a short warning.

The widget shows GPU fleet usage, free GPU count, GPU node health, and the logged-in user's current jobs. The main app sidebar includes a `Widget` button that opens it, and the widget has an `Open` action that launches (building if necessary) the main app.

## Visual Design

The app uses macOS system materials for the main sidebar, dashboard cards, menu bar panel, and desktop widget shell. This gives the interface a glass-like layered feel while keeping dense monitoring content, tables, logs, paths, and quota numbers on readable surfaces. Motion is intentionally local: hover lift on cards, smooth meter changes, restrained status transitions, and animated detail surfaces inside the dashboard and menu panel.

Menu bar monitor:

When the main app is running, it also installs a compact native AppKit menu bar item. The top label is intentionally simple and low overhead: if a job is running, it shows the current job name and elapsed runtime; if multiple jobs are running, it shows the running count; if no job is running, it falls back to GPU availability such as `GPU 8`. The visible status text is self-drawn so it remains white across menu bar appearances, while the background stays transparent until the menu is open. The tooltip includes running/pending counts, storage status, live/cached/offline state, and GPU fleet context. Clicking it opens a small monitoring panel with:

- live/cached/offline state
- running jobs, pending jobs, and storage risk summary tiles
- current running/pending jobs, including job name, job id, partition, state, elapsed/time limit, node or pending reason, and Slurm TRES resource summary
- enhanced home/scratch storage rows with percent used, free space, quota, limit, and file-count pressure when quota data is available
- GPU allocation as a secondary fleet summary
- quick actions for Refresh, Open, and Widget

The menu bar monitor uses the same shared `AppModel` as the main dashboard, so it follows the same refresh loop and cached/offline behavior.

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

Shared Slurm presentation logic (state classification, GPU counting from GRES/TRES strings, byte formatting, node-list expansion) lives in `Sources/AIREMonitorApp/SlurmFormatting.swift` and is used by the dashboards, the menu bar monitor, and the snapshot cache alike.

## Branding

The app logo is stored locally in:

```text
assets/AIRELogo.png
assets/AIREMonitor.icns
```

The launch scripts copy these assets into both generated app bundles. `AIRELogo.png` is used inside the main app sidebar and desktop widget header; `AIREMonitor.icns` is used as the bundle icon through `CFBundleIconFile`.

## Cache, Notifications, and Job Details

The main app keeps a local read-only cache under:

```text
.runtime/latest_snapshot.json      newest successful snapshot (also the widget's data feed)
.runtime/job_state.json            previous job states, for end-of-job notifications
.runtime/snapshot_history.json     compact trend points (capped at the newest 1440)
.runtime/connection_profile.json   password-free connection route for the widget
```

While the main app is open, it refreshes in the background and updates the cache after each successful read-only snapshot. If a refresh fails, the app keeps the latest cached snapshot visible, marks the session as cached/offline, keeps retrying with backoff, and avoids overwriting the cache with failed data.

The history file stores compact trend points from each successful snapshot. The Trends tab visualizes GPU availability, GPU allocation, job queue pressure, unavailable GPU nodes, and home/scratch storage pressure over time. The chart history is local only.

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
- The rash jump-host route assumes one username for both `rash.leeds.ac.uk` and `aire.leeds.ac.uk`.
- It relies on `/usr/bin/ssh`, `/usr/bin/expect`, and `/usr/bin/python3`.
- Automated monitoring is read-only; the only write-capable actions are the user-driven Terminal, the Files tab, and the confirmation-gated `Cancel job`.
- It stores passwords in macOS Keychain only when `Remember in Keychain` is enabled.

The next step is to add configurable refresh intervals and richer final job status using `sacct` where available.
