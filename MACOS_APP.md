# macOS App Internals

This document describes how the SwiftUI macOS app, the menu bar monitor, and the desktop widget actually work: the build system, the multi-cluster architecture, the login flow and status protocol, the runtime layout, the snapshot collector contract, and the UI.

Leeds HPC Monitor monitors several Slurm clusters at once. Today these are AIRE and Calder. Every cluster-specific fact lives in one `ClusterProfile`, every cluster gets its own fully independent `ClusterSession`, and one `AppModel` coordinates what the clusters share: the university account, the route, the Keychain item, and the serialized sign-in chain.

## Build and Run

Recommended:

```bash
./scripts/run_macos_app.sh
```

This builds a local app bundle at:

```text
.runtime/AIREMonitorApp.app        display name "Leeds HPC Monitor", bundle id local.aire.monitor
```

and launches it with macOS `open`, so the app becomes the active foreground application and its text fields receive keyboard focus.

Build system notes:

- `SDKROOT` selection: the launch scripts prefer the pinned Command Line Tools SDK (`/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk`) when it exists, and otherwise fall back to `xcrun --show-sdk-path --sdk macosx`. An `SDKROOT` that is already exported is respected.
- Build directory: SwiftPM builds into the per-user Darwin temp directory (`$(getconf DARWIN_USER_TEMP_DIR)aire-monitor-build`, mode 700, never shared or world-writable) rather than the project volume. Some backup and sync tools that watch the project directory break llbuild's SQLite database mid-build, and the per-user temp volume is immune. The directory name predates the rename and was kept so existing incremental build state is reused. Both launch scripts accept `HPC_SWIFTPM_BUILD_DIR` (or the older `AIRE_SWIFTPM_BUILD_DIR`) as an override, and both build with `--jobs 1`.
- Build-error tolerance: some toolchain and macOS combinations fail the final `build.db` write-back ("disk I/O error") after a fully successful compile. The scripts accept the build only when the log contains `Build complete!` **and** the produced binary is fresh.
- The full build log is written to `.runtime/swift-build.log`, or `.runtime/swift-widget-build.log` for the widget.

The raw SwiftPM commands are still useful for debugging. Pass a scratch path outside the project, because building into the default `.build/` on the project volume can hit the `build.db` "disk I/O error" described above:

```bash
swift build --disable-sandbox --scratch-path "$(getconf DARWIN_USER_TEMP_DIR)aire-monitor-build" --product AIREMonitorApp
swift build --disable-sandbox --scratch-path "$(getconf DARWIN_USER_TEMP_DIR)aire-monitor-build" --product AIREDesktopWidget
```

Running the bare binary (`swift run`) works, but local notifications are disabled outside an app bundle, because `UNUserNotificationCenter` requires a bundle identifier.

Desktop widget companion:

```bash
./scripts/run_desktop_widget.sh
```

This builds and launches `.runtime/AIREDesktopWidget.app` (display name "Leeds HPC Widget", bundle id `local.aire.desktop-widget`, `LSUIElement`, so it has no Dock icon). Both scripts share the same SwiftPM scratch directory, so they reuse each other's build products.

Unit tests:

```bash
Tests/AIREMonitorAppTests/run_tests.sh [--filter <name>]
```

The tests use swift-testing, because XCTest does not exist on a Mac with only the Command Line Tools. The wrapper builds in its own scratch directory (`hpc-monitor-tests-build` under the per-user temp dir; override with `HPC_TEST_BUILD_DIR`). On a Command Line Tools-only machine it adds `-F` and an rpath for the CLT's `Testing.framework`. Without them, SwiftPM's generated test runner compiles its swift-testing entry point out and reports a "pass" with zero tests. `Package.swift` also disables cross-import overlays for the test target only, and links the test bundle for macOS 14. The app and widget still target macOS 13. With Xcode selected, the wrapper is equivalent to `swift test`.

This repository is built with the Command Line Tools only, not full Xcode. A true macOS WidgetKit extension requires an Xcode app target and an extension target, so the widget is a local desktop companion app rather than a system Notification Center widget.

## Project-Root Resolution

The app needs the repository checkout to find the `scripts/hpc_*` helpers and to keep its runtime state under `.runtime/`. The main app resolves the project root in this order, using `scripts/hpc_snapshot.py` as the marker:

1. the `HPC_PROJECT_ROOT` environment variable, then the pre-rename `AIRE_PROJECT_ROOT`
2. the current working directory
3. the grandparent directory of the app bundle. This makes the generated bundles under `.runtime/` self-locating, because `.runtime/AIREMonitorApp.app/../..` is the repository root.

The sidebar's Advanced section has a `Project root` field, so the path can be corrected at runtime without relaunching. Sessions read it on every refresh and sign-in. The field is not persisted. If the resolved root does not contain the collector, the app shows an explicit error instead of failing silently. The widget resolves the checkout the same way (environment variables, working directory, bundle grandparent) so it can read `.runtime/clusters/` and `.runtime/preferences.json`.

## Architecture

```text
AppModel (coordinator, one per app)
│  username · route · jump host · Duo option · Keychain item · login chain · preferences.json
│
├── ClusterSession "aire"     MonitorService ─ scripts/hpc_* ─ ~/.ssh/ctl/aire-<hash>.sock
│     refresh loop · cache · history · job notifications · GPU alert
│     TerminalManager · FileBrowserModel · ClusterDashboardState
│
├── ClusterSession "calder"   MonitorService ─ scripts/hpc_* ─ ~/.ssh/ctl/calder-<hash>.sock
│     (same, fully independent)
│
└── rash route only: ~/.ssh/ctl/jump-<hash>.sock, shared by every cluster's tunnel

Views: ContentView (sidebar + Overview or one ClusterDashboardView)
       StatusBarMonitorController + MenuBarMonitorView (menu bar)
Separate process: AIREDesktopWidget (reads .runtime/clusters/*/ and the enabled flags in .runtime/preferences.json)
```

### Cluster profiles and the catalog

`ClusterProfile.swift` holds everything the app knows about a cluster. `ClusterID` is a string-backed identifier, not an enum, so generic code never switches on a particular cluster. Each `ClusterProfile` carries:

| Field | AIRE | Calder |
|---|---|---|
| `id` (runtime dir name, socket prefix) | `aire` | `calder` |
| `displayName` / `monogram` / `accent` | AIRE / A / green | Calder / C / violet |
| `defaultHostname` | `aire.leeds.ac.uk` | `calder.leeds.ac.uk` |
| `partitions` (`PartitionHint`: name, role, summary, sort rank) | `gpu`, `nodes`, `himem`, `teachingnodes` | `calder-gpu-hopper`, `calder-cpu-turin` |
| `gpuPartition` (terminal "GPU nodes" chip) | `gpu` | `calder-gpu-hopper` |
| `storage` (`StorageVolumeSpec`, see the collector contract) | Home `$HOME` (nfs); Scratch `/scratch-aire/users/$USER`, `/mnt/scratch/$USER`, … (lustre); Flash `/flash-aire/users/$USER`, … (lustre, optional) | Home `$HOME` (nfs); Scratch `/scratch-calder/users/$USER`, … (lustre); Flash `/flash-calder/users/$USER`, … (lustre, optional) |
| `quotaCommand` (terminal "Quota" chip) | `quota -s` + `lfs quota -u` | `quota -s` + `lfs quota -p <project id>` for scratch and flash |
| `documentationURL` | arcdocs AIRE pages | arcdocs Calder pages |

`ClusterCatalog.all` lists the profiles in display order. The sidebar, overview, menu bar and widget all use this order. A partition that no profile hint knows is still styled from its data: gres with a GPU gives it the GPU role, anything else the CPU role. `StorageKind` (home / scratch / flash / other) is derived from a volume's label, not its path, and drives icons, colors, trend series and sort order. Only `home` is `isSharedAcrossClusters`: `/users` is one NFS export, so the overview and menu bar show its quota once and never sum it. `gpuModelDisplayName` turns a gres type into a label (`l40s` becomes `L40S`, `nvidia_h200` becomes `H200`).

**Adding a cluster** takes one profile:

1. In `ClusterProfile.swift`, add a `ClusterProfile`, plus a `static let` on `ClusterID` if you want a named constant. Pick a short, stable, lowercase `id` (a letter, then letters, digits, `-` or `_`, at most 32 characters; the widget ignores any other directory name), because it becomes the `.runtime/clusters/<id>/` directory and the socket prefix. Add a `ClusterAccent` case if no unused color is left: the catalog tests require distinct names, hosts, accents and monograms, a `gpuPartition` that is one of the profile's GPU partition hints, and Home as the first storage volume.
2. Append the profile to `ClusterCatalog.all`.
3. Optional: the widget shares no code with the app, so its `ClusterStyle` mirrors the known clusters' name casing, accent and display order. A cluster missing there still appears, named from its snapshot, with a gray accent, after the known clusters.

Nothing else is cluster-specific. `AppModel` creates one `ClusterSession` per catalog entry, and the new cluster starts enabled. Preferences, control sockets, the runtime directory, collector arguments, notifications, terminals, files and the widget fallback all key off the id. Two assumptions are built in: the rash route assumes the same username is valid on the jump host and on every cluster, and the overview, menu bar and file manager assume every catalogued cluster mounts the shared `/users` home (the Home volume is treated as one quota, and the file manager names every catalogued cluster as sharing it). The collector's built-in name and host table (`KNOWN_CLUSTER_NAMES`, `KNOWN_CLUSTER_HOSTNAMES`) only matters for manual command-line use, because the app always passes both.

### ClusterSession: one cluster's lifecycle

`ClusterSession` (`@MainActor`, one per cluster) owns everything about one cluster: `isEnabled`, its login `hostname` (blank falls back to the profile default), sign-in and refresh flags, `snapshot`, `history`, pause state, the current refresh interval, plus `dashboard` (`ClusterDashboardState`: selected tab, job sheet, filters and detail toggles, so switching clusters in the sidebar restores exactly where the user was), `terminals` (`TerminalManager`) and `files` (`FileBrowserModel`). Sessions share nothing mutable. A failing, paused or disabled Calder never affects AIRE.

`connectionState` collapses the flags for badges, sidebar rows, the overview and the menu bar. The first matching state wins, in this order: `disabled`, `connecting`, `queued`, `paused`, `live`, `cached`, `notConnected`.

`settings` (`ConnectionSettings`) combines the shared sign-in configuration with the profile: cluster id and name, username, host, route, jump host (blank means `rash.leeds.ac.uk`), Duo option (blank means `1`), project root and storage spec. It also derives the runtime directory and both control-socket paths (see [Runtime layout](#runtime-layout)).

**Startup.** `start()` loads the cluster's cached snapshot and history. If the cluster is enabled, it then starts the background timer and runs one non-interactive probe refresh. If a ControlMaster from an earlier run is still alive (`ControlPersist=24h`), the cluster goes live without a sign-in. Otherwise it stays cached or not connected.

**Refresh loop and backoff.** The timer fires every 10 seconds. Each refresh runs the collector through `MonitorService.collectSnapshot`. A snapshot whose `errors` array is non-empty counts as a failed refresh. `warnings` (enrichment problems) are shown in the session panel but never mark the cluster offline.

- On success, the session writes `latest_snapshot.json`, appends a trend point to the history (deduplicated by collection time and capped at the newest 1440 points), rewrites `collector.json` when the collector argv changed, processes job notifications and the GPU alert, resets the failure counter and the interval, and restarts the timer.
- On failure, the interval backs off exponentially (10 s, 20 s, 40 s, capped at 60 s). The last good snapshot stays on screen, and failed data never overwrites the cache. A single failure only marks the data as stale. The session drops to "not live" after **3 consecutive failures**.

**Missing-master detection.** If the failure message says the ControlMaster is gone, the session marks itself not live immediately instead of reporting "offline, retrying", which would suggest a network blip that heals on its own. The status line then asks for a sign-in ("sign in to Calder to refresh"). Two messages count as gone: the collector's local `ssh -O check` probe ("control master is not running") and `MonitorService.requireLiveMaster` ("SSH session expired"). The backoff timer keeps running, so a master that comes back is picked up. A probe that merely timed out is deliberately not treated as missing, because a wedged master may recover.

**Refresh generations.** Every refresh carries a generation number. A sign-in, a pause or disabling the cluster bumps the generation and cancels the in-flight refresh, so a late completion cannot repaint state or restart the timer. A sign-in also waits for the cancelled refresh to exit before it rebuilds the ControlMaster. `refreshAfterMutation()` (used after `scancel`) is never silently dropped: if a refresh or sign-in is running, a pending flag starts one follow-up refresh when the current one completes.

**Pause.** Pausing is per cluster. It stops the timer and invalidates any in-flight refresh. A manual Refresh still runs once while paused. Resume refreshes immediately and restarts the timer, and signing in always clears the pause. The pause is not written anywhere the widget can see, so a running widget treats a paused cluster's file as stale after 30 seconds and collects it itself (see [Desktop Widget Data Flow](#desktop-widget-data-flow)). A **disabled** cluster never refreshes, takes no part in "Connect all", and keeps its cache on disk. The overview hides its cached data, and the widget hides the cluster.

**Route changes.** When the route flips, every session drops its live state and probes the new route's socket (`connectionSettingsDidChange`). Each route has its own socket, so a master that is already alive under the new route reconnects instantly. Otherwise the user signs in. Editing the username or a cluster's host is not re-probed this way: it changes the socket name, so the next refresh finds no master and the session drops to not live until it is signed in again (or the field is changed back).

**Sign-in side effects.** A successful sign-in records `collector.json` and asks the file browser to drop any folder listing that belonged to a different account or login host (`files.reconcileConnectionIdentity()`); a route change does the same. Then it starts one refresh.

**Job notifications.** Each cluster keeps its own job-state baseline (`job_state.json`), because Slurm job IDs are only unique within one controller. After each successful refresh, `JobNotificationService` diffs the baseline against the new `squeue` jobs and notifies when:

- a job goes from pending to running ("job started")
- a job reaches a terminal state (`COMPLETED`, `FAILED`, `CANCELLED`, `TIMEOUT`, `OUT_OF_MEMORY`, `NODE_FAIL`, `PREEMPTED`, …)
- a previously visible non-terminal job leaves `squeue`

Several endings in one refresh become a single summary notification. Titles carry the cluster name ("Calder · job ended"), and notifications are threaded per cluster. The baseline advances only when the diff was actually processed, which requires an app bundle and notification permission. A baseline older than 5 minutes is re-seeded without diffing, so a long gap (app not running, or permission denied) never replays long-finished jobs as a burst of notifications.

**GPU-free alert.** `notifyWhenGPUFrees` is one global, opt-in preference, stored in UserDefaults and off by default. When it is on, each cluster watches its own idle-GPU count, counting only available GPU nodes, and notifies on a 0 → >0 transition, naming the GPU model and partitions. Each cluster has its own 10-minute cooldown. A transition suppressed by the cooldown keeps the baseline at zero, so it fires once the cooldown expires. The baseline lives in memory only.

**Cancel job.** `cancelJob` runs `scancel '<jobid>'` over this cluster's ControlMaster (`MonitorService.runRemoteCommand`), then calls `refreshAfterMutation()`. Cancel lives on the session because job IDs are only meaningful within one cluster.

### AppModel: the coordinator

`AppModel` (`@MainActor`) owns the shared sign-in state: `username`, a transient `password` field (never persisted, cleared after a successful sign-in), `connectionRoute`, `jumpHostname`, `duoOption`, `rememberPassword`, `projectRoot` and the sidebar `selection` (`.overview` or `.cluster(id)`). It also owns app-level errors, the notification-permission summary and the GPU-alert preference. It forwards every session's `objectWillChange`, so views that observe only the coordinator, like the menu bar and the overview, repaint when any cluster changes.

**Login chain.** `connect(id)` signs in to one cluster, and forces a re-login if it is already live. `connectAll()` signs in to every enabled cluster that is not live, or re-authenticates all of them when all are live ("Reconnect all"). Before anything is queued, `enqueueLogins` validates the username, the jump host (rash route only), and the password: the typed one, or the saved one when the field is empty and Remember is on. It then marks every candidate as queued and appends one `Task` to `loginChain` that awaits the previous link. This serializes logins across calls, so Duo pushes arrive one at a time and two clusters never race to build the shared rash jump master. Inside the chain, each outcome is handled like this:

- `succeeded`: save the password if needed, and clear the field.
- `passwordRejected` (helper exit 13, from rash or from a cluster): cancel every other queued login with "Skipped — the password was rejected while signing in to …" and stop. Sending the same wrong password to the next cluster would only push the account towards a lockout.
- `failed` or `skipped`: continue with the next cluster.

**Keychain.** There is one item for the university account: service `AIREMonitor.AIREPassword`, account `leeds:<username>`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Accounts written by single-cluster releases are read as a fallback: `explicit:<user>@<host>:direct` and `explicit:<user>@<host>:via:<jump>` for each cluster's current host, and the original `<user>@leeds`. After a successful sign-in with Remember enabled, the password is saved under `leeds:<user>`. This happens when it was typed, or when nothing is stored under the shared account yet. The legacy entries are then deleted, which completes the migration. `Forget` deletes both the shared and the legacy entries. Whether a saved password exists is checked off the main thread, debounced by 300 ms on username and jump-host edits, and re-checked on route changes.

**Preferences.** The password-free `.runtime/preferences.json` stores username, route, jump host, Duo option, sidebar selection, and each cluster's `enabled` flag and `hostname`. It is written with a 500 ms debounce after any of these change. The password, the Remember toggle (always on at launch) and the project root are not persisted.

**Route monitoring.** A route change re-probes every session and re-checks the saved password. The route picker, the cluster toggles and hosts, and the jump host field are locked while any sign-in is queued or running, so a route flip cannot repoint an in-flight ControlMaster. The username and Duo option fields are not locked. Each queued sign-in reads them when its turn comes, while the password (and the Keychain account it is saved under) was fixed when the sign-in was queued.

**Desktop widget.** `openDesktopWidget()` opens `.runtime/AIREDesktopWidget.app`, or runs `scripts/run_desktop_widget.sh` to build it first.

## Connection Architecture

The app uses the local system `ssh` and `expect`. It installs nothing on the clusters and never writes remote files on its own. The interactive Terminal and the Files tab run what the user types or clicks. Login is performed by helper scripts that the app drives as child processes. The password is written to each helper as the **first line of stdin**, and never appears in any argv or in any child environment the app sets.

### Routes

The sidebar offers exactly two routes, which apply to every cluster. **Both are explicit and username-based.** The app generates the ssh options from its own fields and manages its own ControlMaster sockets under `~/.ssh/ctl/`. It never uses a `~/.ssh/config` alias. The old alias mode was removed; the collector keeps a `--host <alias>` mode purely for manual command-line testing.

- **Direct (VPN)** (`directVPN`) connects straight to each cluster's login host over the University VPN or campus network. Each cluster needs one Duo approval.
- **Via rash jump host** (`rashJump`) tunnels through `rash.leeds.ac.uk`, so it works off-VPN. It needs one Duo approval for rash, which every cluster shares and which is reused while healthy, plus one per cluster.

The rash route assumes the same username is valid on rash and on every cluster.

### Login sequence

`MonitorService.login(settings:password:onStatus:)` signs in to one cluster:

1. **Jump leg (rash route only).** `scripts/hpc_ssh_login.expect` runs with the password on stdin and `HPC_SKIP_TARGET=1`, so it only makes sure the shared jump master is up (see the [shared jump master policy](#shared-jump-master-policy)) and then exits. The app attributes failures of this leg to "the jump host (rash.leeds.ac.uk)", not to the cluster. Exit 13 here means rash rejected the password. On the direct route this step is skipped.
2. **Target leg (both routes).** `scripts/hpc_start_target_master.zsh` runs, again with the password as the first stdin line. The script reads it with `IFS= read -rs`. The legacy `HPC_PASSWORD` variable is accepted as a fallback, and every password variable, including the pre-rename `AIRE_*` names, is scrubbed immediately. This script always **replaces** this cluster's master:
   - On the rash route it first checks the jump master with `ssh -O check`, and exits **3** if the jump master is not running. With a dead jump socket, the ProxyCommand would silently fall back to a direct BatchMode connection to rash, and rash's "Permission denied" must not be mistaken for a rejected cluster password.
   - It tears down only this cluster's previous master: `ssh -O exit`, socket removal, a pid-file kill, and a verified process-pattern kill. A process is killed only if it is titled `ssh: <socket> [mux]`, or if it is an `ssh` whose *first* `ControlPath=` option is exactly this socket and that carries `ControlMaster=yes`. The jump master, other clusters' masters, and every cluster's `-W` proxy therefore never match. This cluster's previous keepalive is killed only when its argv is `hpc_target_keepalive.zsh` followed by this control path. A leftover launchd keepalive job from older releases is removed.
   - It launches a detached `ssh -f` ControlMaster with `ControlPersist=24h`, `NumberOfPasswordPrompts=1` and `PreferredAuthentications=password,keyboard-interactive`. On the direct route it uses `ProxyCommand=none` and `ProxyJump=none`, so a `~/.ssh/config` entry for the host cannot reroute it. On the rash route it uses `ProxyCommand=ssh -o BatchMode=yes -o ControlPath=<jump socket> -o User=<user> -W %h:%p <jump host>`, which rides the shared jump master.
   - It answers the password and Duo prompts through `SSH_ASKPASS` (`scripts/hpc_ssh_askpass.sh`). The password reaches askpass through a **0600 FIFO** in this cluster's 0700 runtime directory, served exactly once (AIRE and Calder offer only keyboard-interactive, so a login has a single password prompt; a second prompt finds no FIFO and is refused, so a wrong password is never sent twice). A writer subshell serves it and exits as soon as ssh returns or the starter dies. An expired password (a password-change prompt) is refused and reported as exit 14. The password is never put in ssh's environment, because `ssh -f` daemonizes into the long-lived master with that environment intact. Askpass answers Duo prompts with `HPC_ASKPASS_DUO_OPTION`, and refuses password-change flows and unknown prompts.
   - It polls the socket (`ssh -O check`, then a read-only `auth_ok|host|user|date` verification) for up to 90 seconds (`HPC_VERIFY_TIMEOUT`), records the master's pid, and starts the keepalive.
3. **Keepalive.** `scripts/hpc_target_keepalive.zsh` is detached through `scripts/hpc_start_background_ssh.zsh`, one per cluster. It exercises the master every 5 seconds with a no-op command. It exits **cleanly** as soon as `ssh -O check` fails or after 3 consecutive failed probes. Nothing supervises or restarts it, so a dead master can never turn into a reconnect loop that hammers the cluster.

Each leg has a 190-second process watchdog. The combined stdout and stderr of both legs is appended to the cluster's `login_debug.log`, and the expect helper writes its own event log to the same file. After sign-in, refreshes, terminals, file operations and `scancel` all multiplex over the cluster's socket with `BatchMode=yes`, so they never prompt for a password or Duo. `runRemoteCommand` and `runTransfer` first run `requireLiveMaster` (`ssh -O check`, 5 s). Without that check, a dead master would make OpenSSH silently dial the host directly, bypassing the jump host, and hang into a misleading timeout.

### Environment contract (`HPC_*`)

Set by `MonitorService` for both legs:

| Variable | Value |
|---|---|
| `HPC_PROJECT_ROOT` | repository root |
| `HPC_RUNTIME_DIR` | `.runtime/clusters/<id>` (logs, pid files, askpass FIFO) |
| `HPC_TARGET_LABEL` | cluster display name, used in every human-readable message |
| `HPC_USERNAME`, `HPC_HOSTNAME` | account and the cluster's login host |
| `HPC_USE_JUMP_HOST` | `1` on the rash route, `0` on the direct route |
| `HPC_JUMP_HOSTNAME`, `HPC_JUMP_CONTROL_PATH` | jump host and shared jump socket (socket set on the rash route only) |
| `HPC_CONTROL_PATH` | this cluster's socket |
| `HPC_DUO_OPTION` | Duo menu answer (default `1` = push) |
| `HPC_FORCE_RELOGIN` | always `1`; applies to the **target** master only |
| `HPC_LOGIN_DEBUG_LOG` | `.runtime/clusters/<id>/login_debug.log` |
| `HPC_TIMEOUT` | `180` (seconds per interactive prompt) |
| `HPC_SKIP_TARGET` | `1`, jump leg only |

Honoured by the scripts but not set by the app: `HPC_JUMP_PROBE_TIMEOUT` (jump health probe, default 10 s), `HPC_VERIFY_TIMEOUT` (default 90 s), `HPC_SSH_VERBOSE=1` (`-vv` in the master log), `HPC_DEBUG=1` (redacted askpass prompt log), and the keepalive's `HPC_KEEPALIVE_INTERVAL` / `HPC_KEEPALIVE_MAX_FAILURES`.

### Shared jump master policy

On the rash route there is exactly one jump master per `user@jump-host`, and every cluster's target master tunnels through it. Closing it silently kills every cluster's tunnel. The expect helper therefore **reuses a healthy jump master and never tears one down because of `HPC_FORCE_RELOGIN`**. Forcing applies to the target only, and the target starter never touches the jump master. Re-signing in to AIRE does not drop Calder's tunnel, and vice versa.

A jump master counts as healthy when:

1. `ssh -O check` succeeds. This is an instant local probe of the control socket.
2. A bounded end-to-end probe succeeds. `ssh -o ControlPath=<jump> -W <cluster host>:22 <jump host>` waits up to `HPC_JUMP_PROBE_TIMEOUT` (10 s) for the far sshd's `SSH-` banner and then hangs up, so no authentication is attempted on the far side. `-O check` alone is not enough, because a master whose TCP connection silently died keeps answering its local socket while every channel through it hangs.

Two refinements keep a responsive jump master when the problem is the cluster rather than rash:

- If rash relays a refusal ("Session open refused by peer"), or the channel opens and the far sshd hangs up before its banner (Calder's "Not allowed at this time"), rash demonstrably carried traffic. The master is kept once a second `ssh -O check` confirms it survived the probe, and the target leg then reports the real error.
- If the probe to the cluster times out, a second probe asks rash for its own sshd (`127.0.0.1:22`). Any answer keeps the master.

Only a jump master that is missing, fails at the mux layer, or carries no traffic at all is closed and re-authenticated, at the cost of one rash Duo push. Because `AppModel` serializes logins, two clusters never race to build it. The flip side is that if the jump master dies (for example after a network change), every rash-route cluster's master dies with it, and the next sign-in re-authenticates rash once.

### The HPC-STATUS protocol

The helper scripts report login milestones on stdout as machine-readable lines:

```text
HPC-STATUS: starting jump-host authentication
HPC-STATUS: password sent, waiting for Duo approval on your phone (jump host)
HPC-STATUS: jump host connected
HPC-STATUS: reusing the shared jump-host session
HPC-STATUS: jump host is up, but Calder did not answer through it yet
HPC-STATUS: starting Calder authentication
HPC-STATUS: waiting for Duo approval on your phone (Calder)
HPC-STATUS: verifying Calder connection
HPC-STATUS: connected to Calder
```

`MonitorService` streams child stdout line by line as it arrives, filters for the `HPC-STATUS: ` prefix (`MonitorService.statusLinePrefix`), and forwards each message to that session's `loginProgress`. The sidebar shows one progress banner per signing-in or queued cluster. The menu bar prefixes each message with the cluster name, so the user can tell which push to approve, and can tell "your password was wrong" apart from "go approve the Duo push".

### Exit codes and failure diagnosis

- **13**: the password was rejected. The expect helper returns 13 when a second password prompt follows with no Duo exchange in between. The target starter returns 13 when the master's log shows the cluster (not the jump host) refusing the password. `MonitorService` turns 13 into `MonitorError.passwordRejected`, which stops queued logins, with a "re-enter it, check for a pending lockout" message. `NumberOfPasswordPrompts=1` normally prevents a resend entirely.
- **124**: timed out waiting for a prompt, usually a missed Duo push. `MonitorService`'s own process watchdog also reports 124 ("Process timed out after Ns").
- **3**: target starter only. The shared jump master was not running when the target leg started. This should not happen right after a successful jump leg, unless rash dropped in between.
- **2**: configuration problem (missing required variable, helper script not executable).

Other failures are matched against common ssh output by `MonitorService.explainSSHFailure`, with the cluster's name in each message:

- "UNKNOWN port 65535" (a failed ProxyCommand) blames the rash tunnel.
- "Not allowed at this time", `kex_exchange_identification`, and connection closed or reset are explained as a server-side refusal, not a wrong password.
- Banner-exchange timeouts get route advice.
- `Permission denied`, unresolvable hostnames, and a stray `ssh-askpass` each get a specific message.

Every message includes the raw ssh output.

## Runtime Layout

All paths are relative to the project root unless they start with `~`.

```text
.runtime/preferences.json                       global, password-free preferences
.runtime/clusters/<id>/latest_snapshot.json     newest good snapshot; the widget reads it, and rewrites it after a fallback collection
.runtime/clusters/<id>/snapshot_history.json    compact trend points (newest 1440)
.runtime/clusters/<id>/job_state.json           job-state baseline for notifications
.runtime/clusters/<id>/collector.json           password-free {updatedAt, script, arguments} for the widget fallback
.runtime/clusters/<id>/login_debug.log          per-login transcript (app + expect helper), 0600
.runtime/clusters/<id>/master_ssh.log|.pid      this cluster's ControlMaster output and pid
.runtime/clusters/<id>/keepalive.log|.pid       keepalive heartbeat and pid
.runtime/clusters/<id>/keepalive_starter.log    detach helper output
.runtime/clusters/<id>/askpass.fifo             exists only while a sign-in waits for ssh
.runtime/clusters/<id>/askpass.log              opt-in redacted askpass log (HPC_DEBUG=1 only)
.runtime/AIREMonitorApp.app, AIREDesktopWidget.app, swift-build.log, swift-widget-build.log

~/.ssh/ctl/<id>-<sha256(user@host:route)[:12]>.sock    cluster ControlMaster; route = "direct" or "via-<jump host>"
~/.ssh/ctl/jump-<sha256(user@jump host)[:12]>.sock     rash jump master, shared by every cluster
```

The jump leg logs to the `login_debug.log` of whichever cluster triggered it. A cache file that no longer decodes is moved aside to `<name>.bad` instead of being silently overwritten.

Control sockets live in `~/.ssh/ctl/` (mode 700) with short SHA-256-based names. macOS caps Unix domain socket paths at 104 bytes and ssh appends a random suffix during setup, so socket paths must stay short and independent of how deeply the project is nested. Do not move them to long project-relative paths. Because each target socket name includes the host and route, AIRE and Calder never share a master, and each route has its own.

**Legacy migration.** On first launch, `PreferencesStore.load()` moves the single-cluster `latest_snapshot.json`, `snapshot_history.json` and `job_state.json` from `.runtime/` into `.runtime/clusters/aire/`, never overwriting files that already exist there. If there is no `preferences.json` yet, the old `connection_profile.json` supplies the starting values: username, jump host, AIRE's host, and the rash route if the old profile used the jump host (an old alias-mode profile becomes the direct route). The old file is left in place, and `preferences.json` is written the first time a preference changes. Old per-stage files such as `.runtime/aire_master_ssh.pid` are no longer read. The socket key format is unchanged byte for byte, so an `aire-<hash>.sock` or `jump-<hash>.sock` master started by the old build is still found.

## Snapshot Collector Contract

`scripts/hpc_snapshot.py` is cluster-agnostic. One invocation collects one cluster over that cluster's existing ControlMaster. It never prompts for, receives or forwards a password, never writes remote files, and only runs read-only commands. `MonitorService.collectorArguments(settings:)` builds its argv, and the same list is saved to `collector.json`:

```text
--cluster-id <id> --cluster-name <name> --username <user> --hostname <login host>
--jump-hostname <jump host> --use-jump-host|--no-jump-host
--control-path <cluster socket> --storage-spec '<JSON>' --timeout 30
[--jump-control-path <jump socket>]                (rash route only)
```

- `--timeout` is the budget for the **whole** collection: the socket probe plus one SSH round trip. The app runs the collector under a 40-second watchdog. Before collecting, the script probes the master locally with `ssh -O check`, so a dead session produces an immediate "connection lost: SSH control master is not running" error.
- `--storage-spec` is the profile's `StorageVolumeSpec` list as JSON: `[{"label": "Scratch", "paths": ["/scratch-calder/users/$USER", "/scratch-calder/$USER"], "quota": "lustre", "optional": false}, …]`. `$USER` and `$HOME` are the only tokens, and they are expanded on the login node. Everything else is shell-quoted literally. The first candidate that is an existing directory wins. `quota` selects the method:
  - `nfs`: `quota -s -w`, falling back to `quota -s`, matched against the directory's `df` source.
  - `lustre`: if `lfs project -d <dir>` reports a non-zero project ID, `lfs quota -p <id> <mount>`, otherwise `lfs quota -u $USER <mount>`, using raw (non `-h`) output.
  - `none`: `df` only.

  An optional volume with no existing candidate is omitted. A required volume is reported as `source: "unavailable"` with null numbers and a warning. Each storage command has its own short remote timeout, and storage runs last, so a stalled filesystem costs only the storage rows.
- **Output** is one JSON object on stdout: `collected_at`, `remote`, `jobs`, `partitions` (now with `time_limit`), `nodes`, `storage`, `errors`, `warnings`, and `cluster: {"id", "name"}`. Each storage row has `label`, `path` (the **resolved** directory), `filesystem`, `source`, used, quota, limit and available GB, `used_percent`, file count, quota and limit, `over_quota`, `quota_type` (`nfs` / `lustre-project` / `lustre-user` / `df`), `project_id` and `mount`. The Swift models decode every new field as optional, so older caches still load.
- Remote sections are delimited by `=====HPC-SECTION:<name>=====` and `=====HPC-STATUS:<name>:<rc>=====`. The core sections (`remote`, `jobs`, `partitions`, `nodes`) decide whether the snapshot is good: their failure is an **error**. Enrichment sections (`job_details`, `node_details`, `storage`) only add detail, and their failure is a **warning**. Jobs come from `squeue --json` when supported, with a pipe-format fallback.
- The script exits 0 when `errors` is empty and 1 otherwise. `--self-test` runs the parsers against embedded fixtures without running ssh.

See [MONITORING_PROTOTYPE.md](MONITORING_PROTOTYPE.md) for the collector's command list and JSON details.

## Terminal

The Terminal tab of each cluster embeds real SSH sessions (SwiftTerm's `LocalProcessTerminalView`). Sessions are plain `/usr/bin/ssh -tt` child processes that **multiplex over that cluster's ControlMaster**, so opening a terminal never re-authenticates and never prompts for a password or Duo:

```text
ssh -tt -S <cluster socket> -o User=<user> -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o ConnectTimeout=5 <cluster host>
```

Before starting a session, the app pre-flights the master with `ssh -S <socket> -O check`. If the master is gone, it prints "<Cluster> SSH session is not running — use Connect for <Cluster> in the sidebar first." inside the terminal instead of launching ssh. **The app never types passwords into a terminal.**

Each cluster has its own `TerminalManager`, so an AIRE shell can never ride on Calder's session or the other way round. Its tabs survive switching dashboard tabs and switching clusters, and the cluster's accent color tints the chrome.

- Quick-command chips come from the profile: `squeue --me`, `sinfo`, the profile's `quotaCommand`, `sinfo -N -p <gpuPartition>` (only if the profile has a GPU partition), and `htop || top`. A chip types into the active live shell when that shell belongs to the same cluster, and otherwise runs in a fresh session. `htop` always gets its own session.
- The Jobs detail sheet offers **Tail output**, which opens `tail -n 200 -F '<stdout path>'` on the job's cluster and is disabled while the job is pending, and **Cancel job**, which runs `scancel` on that cluster only, after a confirmation alert, with the result shown inline.
- The Nodes tab offers **Open shell on login node**, which focuses an existing live shell or opens one.
- An exited session can be restarted with the cluster's current settings, so a restart after a route or host change targets the master that is live now. **Closing a session terminates its ssh child**, so closed tabs never leave orphaned `ssh` processes behind.

## Files

Each cluster has its own file browser. `FileBrowserModel` (UI state) is created by the cluster's `ClusterSession` and attached to it once, so a path, history entry, preview or transfer can never be replayed against the other cluster's filesystem. Every operation captures the session's `ConnectionSettings` when it starts. Navigation history, listings and transfers survive tab and sidebar switches. All remote I/O goes through `RemoteFileService`, which runs every command through `MonitorService.runRemoteCommand` / `runTransfer`. Those pre-flight the ControlMaster, so a dead session fails instantly with a readable error. Every operation is user-initiated.

- **Shortcuts.** The chip row shows Home first, then the cluster's storage spaces from its latest snapshot (home, scratch, flash order, deduplicated by path). Home is the remote `$HOME`, resolved with `realpath` on the login node and never derived from a `/users/<name>` pattern. Until that resolution has happened, the snapshot's home row stands in. The other chips use the **resolved** directories the collector reported (`/scratch-calder/users/<username>`, `/mnt/scratch/<username>`, …) verbatim. Rows marked `unavailable`, or still holding a `$USER`/`$HOME` template, get no chip. Only snapshots cached by the single-cluster collector (no `cluster` block, no `quota_type`) may name a filesystem root, and for those the username is appended. The chip tooltip says whether a space is the shared home ("the same files on AIRE and Calder") or cluster-only, with its Lustre project or user quota.
- **Listing protocol: `ls` is never parsed.** Listings run an embedded Python script on the login node, `python3 -I -c <script> <path> <showHidden>`. The remote command prefers `/usr/bin/python3` (3.9 on Calder) over whatever a user's conda or module setup puts first on `PATH`, and falls back to `python3` on `PATH`. Isolated mode (`-I`) ignores `PYTHONPATH` and user site-packages, and keeps the home directory off `sys.path`, so a stray `~/json.py` cannot shadow a standard module. The script is limited to Python 3.6 features. The target path travels as an `argv` element, never inside the script. The script emits one JSON object (or `{"error": …}` with exit 3). Undecodable names are sanitized to U+FFFD, and listings are capped at 4000 entries with an explicit truncation flag, which the view shows as a warning.
- **Identity reset.** The browser tags its open folder with the account and login host it was listed under (the route is deliberately not part of this identity: direct or through rash, the same account on the same host sees the same files). When the Files tab appears, when the session's live state changes, and after a sign-in or route change, `reconcileConnectionIdentity()` drops the folder, history, selection, filter and open dialogs if they belong to a different identity. The cached home is likewise only reused for the identity it was resolved for, and late results for an old identity are discarded. Transfers already running keep their own settings.
- **Operations.** New folder, rename (refused if the target exists, including a broken symlink), upload and download, a text preview (up to 256 KiB, via `file --mime-type` with a content sniff when `file` is missing), folder size (`du -sh`), Copy Path, and drag-and-drop upload. Uploads refuse to overwrite an existing remote file, and folders are not transferred. Downloads go to `~/Downloads` under a unique name and are revealed in Finder.
- **Transfers** are local `/usr/bin/scp` invocations with `BatchMode=yes`, `ControlMaster=no` and this cluster's `ControlPath`, so they never re-prompt and never spawn a second master. The remote spec is a single argv element after `--`. The timeout scales with size: 60 s plus 1 s per MB, capped at one hour, or 10 minutes when the size is unknown.
- **Trash-first deletion.** **Move to Trash** (after a confirmation) moves items into a fresh `.aire-trash/<timestamp>-<id>/` folder instead of removing them. The name `.aire-trash` is kept from the single-cluster release. Items on the home filesystem go to `~/.aire-trash`, and because `/users` is one NFS export, that is the same folder on AIRE and Calder. Items on another filesystem (AIRE `/mnt/scratch`, Calder `/scratch-calder` and `/flash-calder`) get a `.aire-trash` folder beside them, so the move stays a rename and never copies data into the small home quota that both clusters share. Such items keep counting against their own filesystem's quota (on Calder a Lustre project quota) until the trash is emptied. If no trash folder can be created beside them, nothing is moved: the app asks whether to copy them into the home trash, delete them permanently, or cancel. The trash is never emptied automatically.
- **Permanent delete.** `Delete Permanently` runs `rm -rf --` after two confirmations. Both delete paths independently refuse `/`, `~`, the home directory itself, non-absolute paths, and paths with `.`, `..` or empty components.
- **Injection defenses.** Remote names are untrusted data. Every interpolated value is single-quoted (`'` becomes `'\''`), and path arguments follow a `--` separator.
- **Integrations.** **Browse workdir** in the Jobs sheet opens the job's working directory in that cluster's Files tab. **Open Shell Here** opens a terminal tab on the same cluster in that directory, and the text preview offers **Open in Terminal (vim)**.

## Desktop Widget Data Flow

The widget is a separate process that shares no code with the app. Its primary data path is **file watching, not SSH**.

- **Discovery.** It lists `.runtime/clusters/` every 2 seconds, and also watches that directory, and keeps one feed per cluster directory whose name is a valid cluster id. Clusters whose `enabled` flag is `false` in `.runtime/preferences.json` are hidden and never collected. The widget reads only those flags from the file, and an unreadable file hides nothing. Feeds are sorted AIRE, Calder, then any other cluster alphabetically. The window grows by one row per cluster, up to 4 rows, and the footer mentions any rows that do not fit.
- **Primary path.** Each feed watches its cluster directory, because the app replaces `latest_snapshot.json` atomically, which shows up as a directory event. It reloads the file whenever its modification date changes. A snapshot collected at most 30 seconds ago is shown as live, and the widget opens no SSH connection of its own, so it cannot double-collect while the app is feeding that cluster.
- **Fallback collection, per cluster.** When a cluster's file is missing or older than 30 seconds, the widget loads that cluster's `collector.json` and validates it. The file must decode. Its `--cluster-id` must match the directory. The recorded script must be a relative path inside the project, with no `..`, no absolute or `~` path, and no symlink resolving outside the checkout, and it must exist. The widget then runs `/usr/bin/python3 <script> <arguments>`. At most one collection per cluster runs at a time, attempts start at most every 10 seconds per cluster, and an invalid record is rejected at that same rate. The watchdog is the recorded `--timeout` (default 30, clamped to 1–300) plus 20 seconds, so 50 seconds with the app's arguments. It sends SIGTERM, then SIGKILL 3 seconds later. Only a clean result is accepted: exit 0, valid JSON, no collector errors, no timeout, and a `cluster.id` that matches. Before writing, the widget reloads the file, and a snapshot the app wrote in the meantime wins if it is newer. Otherwise the widget atomically writes the collector's stdout to `latest_snapshot.json` and keeps collecting every 10 seconds until the app writes the file again. The collector never authenticates, so all of this only works while that cluster's ControlMaster is still alive, for example after the app quit within the 24-hour `ControlPersist` window. Without `collector.json` the row says to connect the cluster in the app.
- **States.** Each row is `connecting`, `live`, `cached` (snapshot older than 30 seconds), or `offline` (no snapshot and an error or notice). The header chip counts clusters ("all 2 clusters", "1 of 2 live") and never sums their numbers. The footer shows the most important message, and every per-cluster error is prefixed with the cluster name.
- **Rows.** Each row covers one cluster: its name and monogram in the app's accent color, a status chip with the login node (collector warnings go in its tooltip), the snapshot time, its own GPU pool (allocated, idle on available nodes and unavailable, labelled with the GPU model), running and pending counts, the first running or pending job, and a GPU-node heatmap. Job and node identities are qualified by cluster, because Slurm IDs are only unique within one cluster.
- **Window.** A borderless, movable panel at desktop-icon level on every Space. The frame is saved under the pre-rename autosave name `AIREDesktopWidget`, and when rows are added or removed the top edge stays put. The context menu offers Refresh all, per-cluster refresh, Open Leeds HPC Monitor (opens `.runtime/AIREMonitorApp.app`, or runs `scripts/run_macos_app.sh` to build it) and Quit.

The main app's sidebar and its menu bar both have a `Widget` button that opens it.

## Overview

The overview is the default landing page (`OverviewDashboard`). Two rules shape it: numbers from different clusters are never silently added together, and a cluster without a snapshot shows an explicit "not connected" or "off" state, never zeros.

- **Cluster cards**: one per cluster, in catalog order. Each card shows identity, connection state with a Connect action, snapshot age, headline figures and storage rows. The home row is marked "shared by all clusters".
- **Where can I run now?**: one tile per reporting cluster comparing idle GPUs (by model) and free CPU cores on available nodes, each with its own snapshot age. Counts are compared, never summed.
- **Combined jobs**: the user's jobs from every reporting cluster, each tagged with its cluster, running first, then pending. Job identity is cluster-qualified. The list is capped at 40 rows until expanded. Clicking a job switches to its cluster's Jobs tab with the detail sheet open.
- **Refresh all** (⌘R) refreshes every enabled cluster.

## Menu Bar Monitor

While the main app runs, it installs a native AppKit status item (`StatusBarMonitorController`) that summarises every enabled cluster:

- **Title**: `C · train 1:23` (cluster monogram, job name, elapsed) when exactly one job is running across all clusters; `3 jobs` when several are running; otherwise idle GPUs per cluster, such as `A 6 · C 27` (pools are never summed); and otherwise a state word (`Signing in`, `Syncing`, `Ready`, `Cached`, `Offline`, `Off`). The width is reserved from a digit-stable template, so the item does not jitter on every elapsed-time tick.
- **Icon tint** shows combined health: green when every enabled cluster is live; orange when only some are, or data is cached or paused, or a sign-in is running; red when nothing is live and a cluster reports an error; dimmed when offline. With every cluster off, it is a plain template icon.
- **Tooltip**: one block per cluster (connection state, sign-in progress, running and pending counts, the GPU pool, storage pressure), then the shared home quota once.
- **Dropdown** (`MenuBarMonitorView`): a combined header, then one compact section per cluster. Each section has its state pill, a single action (Connect, Resume, or turn monitoring on), GPU pool and storage meters, and running and pending jobs, truncated with "+N more". The shared home appears once below the sections, then any app-level error, then footer actions: Refresh all, Open dashboard, Widget.
- **Opening the menu** calls `refreshAll()`. Each session self-guards against overlapping refreshes and sign-ins, so the menu shows data at most a few seconds old without ever starting a sign-in.

The status item and the dropdown are both built from one `MenuBarDigest`, so the title and the panel beneath it never disagree. Model changes are coalesced, and the item is only touched when something visible changed.

## Current Views

The dashboard window is a `NavigationSplitView`. The sidebar holds the cluster switcher (Overview plus one row per cluster with a state pill and a Connect button), per-cluster sign-in banners, the shared sign-in form (route, username, password, Remember in Keychain, Duo option, and an Advanced section with per-cluster on/off toggles and hosts, the jump host and the project root), the action buttons (Connect all, Refresh, Widget), notification settings, and the selected cluster's session panel (status, staleness, pause, collector warnings, errors).

Each cluster's dashboard shows a header (host, user, snapshot age, Refresh ⌘R), summary metrics, and the tabs:

- **Jobs**: visual summary and job cards by state; clickable detail sheet combining `squeue` with `scontrol show job -o` (times, batch host, node list, TRES, work directory, stdout and stderr paths)
- **Partitions**: cards styled from the profile's partition hints, node-state bars, time limits
- **Nodes**: GPU-first dashboard (allocation, free GPUs by model, mixed and unavailable GPU nodes, slot-level occupancy) plus CPU, high-memory and teaching node classes where the cluster has them
- **Trends**: this cluster's own history (GPU availability and allocation, queue pressure, unavailable GPU nodes, home, scratch and flash pressure)
- **Storage**: one card per reported space, with used percentage, headroom, limit, file-count pressure, and how it is measured (NFS quota, Lustre project or user quota, or filesystem totals from `df`)
- **Files** and **Terminal**, as above

Detail tables are hidden by default behind `Show Details`. Before a cluster has any snapshot, its dashboard shows a connect hero instead of zeroed metrics. Shared Slurm presentation logic (state classification, GPU counting from GRES/TRES strings, byte formatting, node-list expansion) lives in `SlurmFormatting.swift`.

The visual language uses macOS system materials for the sidebar, cards, menu panel and widget shell, with each cluster's accent color (AIRE green, Calder violet) on its badge, tabs and terminal chrome. Motion is restrained: hover lift on cards, smooth meter changes, and animated detail surfaces.

## Branding

```text
assets/LeedsHPCMark.png        emblem (app sidebar, widget header), copied into both bundles
assets/LeedsHPCMonitor.icns    bundle icon of both bundles (CFBundleIconFile)
assets/AIRELogo.png            previous single-cluster artwork, no longer bundled
assets/AIREMonitor.icns
```

Both launch scripts copy `LeedsHPCMark.png` and `LeedsHPCMonitor.icns` into their bundle, so the app and the widget both carry the neutral Leeds HPC mark rather than one cluster's branding. The app still looks for `AIRELogo.png` as a fallback, which only matters for bundles assembled by older build scripts. The AIRE artwork is no longer bundled.

## Current Limitations

- The app bundles are generated locally under `.runtime/`. They are not signed or notarized.
- The rash route assumes one username for `rash.leeds.ac.uk` and every monitored cluster.
- It relies on `/usr/bin/ssh`, `/usr/bin/expect` and `/usr/bin/python3`.
- Automated monitoring is read-only. The only write-capable actions are the user-driven Terminal, the Files tab and the confirmation-gated `Cancel job`.
- Passwords are stored in the macOS Keychain only when `Remember in Keychain` is enabled. The toggle is not persisted and is on at every launch.
- The refresh interval is fixed at 10 seconds (with backoff), and final job states come from `squeue` only. `sacct` is not used yet.
- Pausing a cluster pauses only the app. A running desktop widget still runs its fallback collection for that cluster once the snapshot is older than 30 seconds, while the master is alive.
