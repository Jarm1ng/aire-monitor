# AIRE Monitor

AIRE Monitor is a local macOS monitoring app for the University of Leeds AIRE HPC cluster. It provides a visual dashboard for Slurm jobs, partitions, GPU nodes, storage quota, historical trends, and a lightweight desktop companion widget.

This project is read-only with respect to the cluster. It does not install server-side agents, submit jobs, cancel jobs, or modify remote files.

> This is an independent open-source tool and is not an official University of Leeds product. The generated logo and UI are project branding only and do not reproduce the official University crest or identity.

## Features

- SSH and Duo-compatible login flow through the user's local SSH configuration
- Slurm job dashboard with clickable job detail sheets
- Partition and node visualizations, with GPU-first monitoring
- Local macOS notifications when jobs finish, fail, cancel, time out, or leave `squeue`
- Home and scratch quota visualization
- Historical trend charts for GPU availability, queue pressure, node health, and storage usage
- Material-based macOS interface with glass surfaces and restrained state animations
- Menu bar monitor that shows the current running job first, then GPU availability when no job is running
- Desktop companion widget with quick GPU/job status
- Local cache under `.runtime/` for resilience between refreshes

## Requirements

- macOS 13 or newer
- Swift 6 / Xcode Command Line Tools
- `/usr/bin/ssh`
- `/usr/bin/expect`
- `/usr/bin/python3`
- Access to the AIRE SSH endpoint and the required jump host

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

## SSH Setup

Use your own University credentials and local SSH configuration. A generic example is provided in:

```text
config/aire_ssh_config.example
```

The app never stores passwords. It passes the password to a local `expect` helper for the current login attempt only, then relies on OpenSSH ControlMaster for follow-up read-only refreshes.

## Local Data

Runtime data is intentionally ignored by git:

```text
.runtime/latest_snapshot.json
.runtime/job_state.json
.runtime/snapshot_history.json
.runtime/ssh-control/
```

These files can contain usernames, job names, filesystem paths, and cluster state. Do not commit them.

## Documentation

- [macOS app notes](MACOS_APP.md)
- [Monitoring prototype](MONITORING_PROTOTYPE.md)
- [AIRE server guide, English](AIRE_SERVER_GUIDE_EN.md)
- [AIRE server guide, Chinese](AIRE_SERVER_GUIDE.md)

## License

MIT. See [LICENSE](LICENSE).
