# Leeds HPC Monitor

Leeds HPC Monitor is a local macOS monitoring app for the University of Leeds HPC clusters. It monitors **AIRE** and **Calder** (opened October 2026) at the same time, with a visual dashboard for Slurm jobs, partitions, GPU nodes, storage quota and historical trends, a menu bar monitor, and a lightweight desktop companion widget.

Each cluster is monitored on its own: it has its own SSH ControlMaster session, refresh loop, snapshot cache and history, job notifications, terminals and file browser. A cluster that is slow, paused or signed out never affects the other one. The Overview page, the menu bar item and the desktop widget show both clusters together, but they never add numbers from different clusters into one total. An L40S and an H200 are different GPU pools, job IDs are only unique within one cluster, and the `/users` home quota is a single NFS export that both clusters report.

All monitoring is read-only. The app's own background collection never submits jobs or modifies remote files, and nothing is installed on the servers. On top of that, the app offers a small set of user-driven interactive features: an embedded Terminal tab, a remote file manager, and an explicit, confirmation-gated `Cancel job` action. These run only what the user types or clicks, over that cluster's already-authenticated SSH session, exactly as the user's own `ssh` session would.

> This is an independent open-source tool and is not an official University of Leeds product. The logo and UI are project branding only and do not reproduce the official University crest or identity.

## Features

- Two clusters in one app: AIRE (L40S GPUs; `gpu`, `nodes`, `himem`, `teachingnodes` partitions) and Calder (H200 GPUs; `calder-gpu-hopper`, `calder-cpu-turin`). You can switch either one off under Advanced.
- One sign-in for both clusters: one university account, one Keychain entry, one route choice (see [Signing in](#signing-in))
- Persistent OpenSSH ControlMaster sessions, one per cluster, so refreshes never ask for your password or Duo again
- Live sign-in progress per cluster in the sidebar (waiting, password sent, waiting for Duo approval, connected)
- Overview page: a card for each cluster (connection state, snapshot age, headline numbers, storage), a "where can I run now" strip that compares idle capacity cluster by cluster, and your jobs from every cluster in one list. Clicking a job opens it on its own cluster's Jobs tab.
- Per-cluster dashboard tabs: Jobs, Partitions, Nodes, Trends, Storage, Files, Terminal
- Slurm job detail sheets with a live `tail -F` of a job's stdout and a confirmation-gated `Cancel job`, which runs `scancel` on that job's own cluster only
- An embedded SSH terminal (SwiftTerm) for each cluster that multiplexes over that cluster's ControlMaster: multiple tabs and no re-authentication. Quick-command chips are built from the cluster's profile, so partition names and quota commands match the cluster.
- A remote file manager for each cluster: browse, upload/download, rename, preview, folder size, trash-first delete (into `~/.aire-trash` in the shared home, or a `.aire-trash` folder beside items on scratch or flash), a per-job Browse-workdir shortcut, and shortcuts to the storage directories the collector resolved for that cluster
- Storage quotas: the shared NFS home plus each cluster's Lustre scratch and flash. Calder reports Lustre project quotas and AIRE reports per-user quotas. The expected Aire 2.0 locations (`/scratch-aire`, `/flash-aire`) are already candidate paths.
- Local macOS notifications for each cluster when a job starts running or ends (finishes, fails, is cancelled, times out, or leaves `squeue`), plus an opt-in alert when a cluster's free GPU count goes from zero to at least one
- Per-cluster monitoring pause, which stops the app's background collection without dropping the session (a running desktop widget does not know about the pause, see [MACOS_APP.md](MACOS_APP.md#desktop-widget-data-flow))
- Historical trend charts for each cluster: GPU availability, queue pressure, node health, and storage usage
- A menu bar monitor that summarises every enabled cluster: the running job if there is exactly one, otherwise a running-job count, otherwise idle GPUs per cluster (for example `A 6 · C 27`)
- A desktop companion widget with one row per enabled cluster. It follows the main app's per-cluster snapshot files and only collects on its own when a cluster's data is stale.
- A local per-cluster cache under `.runtime/clusters/<id>/` that keeps the last data on screen between refreshes

## Signing in

- **One account, one password.** The same university username and password work on rash, AIRE and Calder, and the app keeps them in a single macOS Keychain item. Whether it is saved there is controlled by `Remember in Keychain`, which is on by default at every launch. Untick it before signing in to keep the password in memory only, and use `Forget` to remove a saved one.
- **One route for every cluster**, because the route depends on where your Mac is:
  - **Direct (VPN)** connects straight to each login host over the University VPN or campus network. You approve one Duo push per cluster.
  - **Via rash jump host** tunnels through `rash.leeds.ac.uk` when you are off-VPN. You approve one Duo push for rash plus one per cluster. Both clusters share the rash session, and the app reuses it for as long as it stays healthy. So signing in to the second cluster, or signing in to one cluster again, normally costs only that cluster's push.
- **One push at a time.** `Connect all` signs in to every enabled cluster that is not live yet, one after another, so Duo pushes arrive one at a time. If a password is rejected, the app cancels the remaining queued sign-ins instead of sending the same wrong password again, because repeated failures can lock the account.
- **Sessions survive restarts.** Each ControlMaster persists for up to 24 hours. If a cluster's session is still alive when the app starts, the app reconnects without asking you to sign in.
- **Calder's login nodes.** Calder's round-robin DNS sometimes lands on a login node that closes the connection before authentication, or says "Not allowed at this time". That is a server-side refusal, not a wrong password. Wait a minute and connect again.

## Quick Start

Clone the repository, then run:

```bash
./scripts/run_macos_app.sh
```

To launch the desktop companion widget:

```bash
./scripts/run_desktop_widget.sh
```

The scripts build local app bundles under `.runtime/` and launch them with macOS `open`.

For use from a plain terminal, `config/aire_ssh_config.example` is an SSH configuration example for both clusters: `aire` and `calder` for the direct VPN route, `aire-jump` and `calder-jump` for the off-VPN route through `rash`. The app itself does not use those aliases. It builds the equivalent `ssh` options from its own fields (username, route, each cluster's login host, and the jump host) and keeps its own control sockets, which never collide with the example's.

## Testing

```bash
Tests/AIREMonitorAppTests/run_tests.sh          # Swift unit tests (swift-testing)
python3 scripts/hpc_snapshot.py --self-test     # collector parsers against embedded fixtures
python3 scripts/tests/test_login_flow.py        # login scripts against a mock ssh
```

- **Unit tests** use swift-testing and cover the cluster catalog, connection settings and control-socket names, collector arguments, SSH failure wording, snapshot and cache decoding, and preference migration. They use no network, Keychain or `~/.ssh`. On a Mac with only the Command Line Tools (no Xcode), plain `swift test` cannot find `Testing.framework`, so use the wrapper script, which adds the missing flags. Extra arguments go through to `swift test`, for example `--filter PreferencesStore`.
- **Collector self-test** runs the parsers and the generated remote script against local stubs. It never runs `ssh`.
- **Login-flow tests** drive the real `scripts/hpc_*` helpers the way the app does, with a fake `ssh` placed first on `PATH`. They never contact a real host, never touch `~/.ssh`, and never touch your existing sessions. They take about 15 seconds. See [scripts/tests/README.md](scripts/tests/README.md) for the scenarios.

## Requirements

- macOS 13 or newer
- Swift 6 / Xcode Command Line Tools
- `/usr/bin/ssh`
- `/usr/bin/expect`
- `/usr/bin/python3`
- Access to both login hosts, `aire.leeds.ac.uk` and `calder.leeds.ac.uk`: either directly through the University VPN or campus network, or through the `rash.leeds.ac.uk` jump host. The same username must be valid on rash and on each cluster you monitor. Switch off a cluster you do not use under Advanced.

## Upgrading from AIRE Monitor

The app was renamed, but its internal identifiers were deliberately left unchanged so that upgrading keeps your saved state:

- SwiftPM targets and products `AIREMonitorApp` / `AIREDesktopWidget`, and the bundle IDs `local.aire.monitor` / `local.aire.desktop-widget`. Notification permission, UserDefaults and the saved window position therefore carry over.
- Keychain service `AIREMonitor.AIREPassword`
- The remote trash folder `.aire-trash` in your home directory, which both clusters share

On first launch the app migrates the old single-cluster state:

- The cache files in `.runtime/` (`latest_snapshot.json`, `snapshot_history.json`, `job_state.json`) move into `.runtime/clusters/aire/`.
- `connection_profile.json` seeds the new `.runtime/preferences.json`.
- A password saved under the old per-host Keychain accounts is still used. After the next successful sign-in it is re-saved under the shared account, and the old entries are removed.
- An AIRE or rash ControlMaster started by the old build keeps its socket name, so the new build still finds it.
- The old `AIRE_PROJECT_ROOT` environment variable is still honoured. `HPC_PROJECT_ROOT` is preferred.

## Security Summary

Passwords are never written to project files and never appear on any command line or in any long-lived environment. The only persistent credential store is your macOS Keychain: one item, saved after a successful sign-in while `Remember in Keychain` is on (the default), service `AIREMonitor.AIREPassword`, account `leeds:<username>`, device-only, readable only while the Mac is unlocked.

During sign-in, the password reaches the local helper scripts only as the first line of their stdin. It reaches ssh's askpass helper only through a private, short-lived FIFO in that cluster's runtime directory. ssh runs with `NumberOfPasswordPrompts=1`, so a wrong password fails fast. A rejected password also stops any queued sign-ins for the other cluster.

All automated cluster access (background monitoring) is read-only. The only write-capable paths are the interactive Terminal, the file manager and the confirmation-gated `Cancel job` action, and all of them run only what you explicitly type, click or confirm.

Runtime state (snapshots, logs, pid files) lives under `.runtime/`, which is gitignored. ControlMaster sockets live under `~/.ssh/ctl/`. These files can contain usernames, job names and filesystem paths, so do not commit them. See [SECURITY.md](SECURITY.md) for the full credential pipeline and data inventory.

## Documentation

- [macOS app internals](MACOS_APP.md): architecture, connection and login flow, refresh loop, runtime layout, collector contract, widget, menu bar, build system
- [Security notes](SECURITY.md): credential handling, Keychain details, data inventory, reporting
- [Monitoring prototype](MONITORING_PROTOTYPE.md): the snapshot collector script and its JSON output
- [Login-script tests](scripts/tests/README.md): the mock-ssh harness and its scenarios
- [AIRE server guide, English](AIRE_SERVER_GUIDE_EN.md)
- [AIRE server guide, Chinese](AIRE_SERVER_GUIDE.md)
- [Calder server guide, English](CALDER_SERVER_GUIDE_EN.md)
- [Calder server guide, Chinese](CALDER_SERVER_GUIDE.md)

## License

MIT. See [LICENSE](LICENSE).
