# AIRE Monitor

AIRE Monitor is a local macOS monitoring app for the University of Leeds AIRE HPC cluster. It provides a visual dashboard for Slurm jobs, partitions, GPU nodes, storage quota, historical trends, and a lightweight desktop companion widget.

All monitoring is read-only: the app's own background collection never submits jobs or modifies remote files, and nothing is installed server-side. On top of that, the app offers a small set of user-driven interactive features — an embedded Terminal tab, a remote file manager, and an explicit, confirmation-gated `Cancel job` action — which run only what the user types or clicks over the app's already-authenticated SSH session, exactly as the user's own `ssh` session would.

> This is an independent open-source tool and is not an official University of Leeds product. The generated logo and UI are project branding only and do not reproduce the official University crest or identity.

## Features

- Username-based SSH login with Duo two-factor support, via two routes: Direct (VPN) straight to AIRE, or through the `rash.leeds.ac.uk` jump host when off-VPN
- Persistent OpenSSH ControlMaster sessions, so refreshes never re-ask for password or Duo
- Live login progress in the sidebar (password sent, waiting for Duo approval, connected)
- Slurm job dashboard with clickable job detail sheets, live `tail -f` of a job's stdout, and a confirmation-gated `Cancel job` (scancel) action
- Embedded SSH terminal (SwiftTerm) that multiplexes over the existing ControlMaster session — multiple tabs, quick-command chips, no re-authentication
- Remote file manager over the same session: browse, upload/download, rename, preview, trash-first delete (recoverable server-side `~/.aire-trash`), and a per-job Browse-workdir shortcut
- Partition and node visualizations, with GPU-first monitoring
- Local macOS notifications when jobs finish, fail, cancel, time out, or leave `squeue`, plus an opt-in GPU-free alert when free GPUs appear
- Monitoring pause toggle that stops background collection without dropping the session
- Home and scratch quota visualization
- Historical trend charts for GPU availability, queue pressure, node health, and storage usage
- Menu bar monitor that shows the current running job first, then GPU availability when no job is running
- Desktop companion widget that follows the main app's snapshot file and only collects on its own when the data is stale
- Local cache under `.runtime/` for resilience between refreshes

## Quick Start

Clone the repository, then run:

```bash
./scripts/run_macos_app.sh
```

Launch the desktop companion widget:

```bash
./scripts/run_desktop_widget.sh
```

The scripts build local app bundles under `.runtime/` and launch them with macOS `open`.

A generic SSH configuration example (direct VPN route plus an off-VPN jump-host route) is provided in `config/aire_ssh_config.example` for use from a plain terminal. The app itself does not need those aliases — it builds the equivalent `ssh` options from its own form fields (username, AIRE host, optional jump host).

## Requirements

- macOS 13 or newer
- Swift 6 / Xcode Command Line Tools
- `/usr/bin/ssh`
- `/usr/bin/expect`
- `/usr/bin/python3`
- Access to the AIRE SSH endpoint, either directly through the University VPN or through the `rash.leeds.ac.uk` jump host

## Security Summary

Passwords are never written to project files and never appear on any command line. The only persistent credential store is the user's macOS Keychain (opt-in via `Remember in Keychain`, removable via `Forget`). During login the password is handed to local helper processes through stdin only, and ssh is configured with `NumberOfPasswordPrompts=1` so a wrong password fails fast instead of risking an account lockout. All automated cluster access (background monitoring) is read-only; the only write-capable paths are the interactive Terminal, the file manager, and the confirmation-gated `Cancel job` action, all of which execute only what the user explicitly types, clicks, or confirms. Runtime state (snapshots, ControlMaster sockets, logs) lives under `.runtime/`, which is gitignored; these files can contain usernames, job names, and filesystem paths, so do not commit them. See [SECURITY.md](SECURITY.md) for the full credential pipeline and data inventory.

## Documentation

- [macOS app internals](MACOS_APP.md) — connection architecture, build system, terminal, UI, cache, widget
- [Security notes](SECURITY.md) — credential handling, Keychain details, data inventory, reporting
- [Monitoring prototype](MONITORING_PROTOTYPE.md) — the snapshot collector script and its JSON output
- [AIRE server guide, English](AIRE_SERVER_GUIDE_EN.md)
- [AIRE server guide, Chinese](AIRE_SERVER_GUIDE.md)

## License

MIT. See [LICENSE](LICENSE).
