# Leeds HPC Monitor for Linux

A Linux desktop port of the read-only monitoring features. The macOS SwiftUI
application is unchanged. The Linux app uses Python, Qt (PySide6) and Paramiko,
and imports the same `scripts/hpc_snapshot.py` collector and parsers as the Mac.
It shares its code, in `desktop/`, with the [Windows app](WINDOWS_APP.md).
It does not need OpenSSH ControlMaster, Xcode, or anything installed on the
cluster.

## Run the portable app

Linux (64-bit `x86_64` or `aarch64` with X11/XWayland or Wayland). Extract the
**entire** `LeedsHPCMonitor-Linux-x64.tar.gz` (or `-arm64.tar.gz`) archive into a
folder you can write to, then launch `./LeedsHPCMonitor/LeedsHPCMonitor`. Keep
`_internal` next to the executable. Python is bundled; a separate Python
installation is not needed.

There is no root installer or auto-updater. Only run builds whose source and
download you trust.

1. Connect to the University VPN (or campus network), or choose **Via rash jump
   host** for off-VPN access.
2. Enter your university username and password; select AIRE, Calder, or both.
3. Optionally tick **Save in System Keyring**. The default is not to save.
4. Click **Connect selected**. On first connection, verify each host's SHA-256
   fingerprint with Leeds IT or a known-good connection before trusting it.
5. Answer any Duo selection/passcode prompts and approve the push on your phone.

Sign-ins are serial: one cluster's Duo prompt at a time. The rash SSH connection
is shared when connecting both clusters. A rejected password, cancelled Duo
dialog, or declined host key stops the remaining queued sign-ins. There is no
automatic password retry. After a failure, correct the problem before pressing
Connect again.

To try the interface without credentials or network access:

```bash
./LeedsHPCMonitor/LeedsHPCMonitor --demo
```

Demo mode labels every screen as synthetic, disables sign-in, and never writes
example snapshots into the live cache.

## Included

- Overview cards with idle GPUs per model (Calder's H200 and L40 pools are
  never added together), job counts (held jobs apart, array tasks counted one
  by one), CPUs idle on CPU nodes, storage with its fill level, snapshot age
  and explicit live/stale/offline status. The figures follow the macOS app's
  rules, so both apps show the same numbers for the same snapshot.
- Jobs, partitions, nodes and storage tables; a cluster filter on every page.
- Job details and a manually refreshed, bounded stdout tail (last 128 KiB).
- Read-only SFTP directory browsing and text previews (first 128 KiB).
- Per-cluster idle-GPU charts (all of a cluster's models on one line, as on
  the Mac) and recent CPU/queue/node-health history, in local time.
- Ten-second refreshes over persistent authenticated SSH connections. Storage
  (`df`, `quota`, `lfs quota` on shared filesystems) is collected after
  sign-in, on **Refresh now** and every five minutes; in between, the last rows
  stay on screen with their collection time. One cluster's refresh failure
  does not discard the other's data.
- System tray icon, minimize-to-tray, and notifications when a job starts or
  leaves the active queue, where the desktop provides a tray (stock GNOME needs
  the AppIndicator extension). Without one the button reads **Minimize** and
  job changes appear in the window's banner instead. Leaving the queue is
  **not** described as successful completion: its final status is unknown.
- Local, account-scoped snapshots and up to 8,640 history points per cluster.
  Offline data always remains labelled as cached/stale.

Idle GPUs are only those a new job could start on now: on nodes that accept
work (idle, mixed, allocated, completing or planned, and not in a maintenance
reservation, rebooting, powering down or unresponsive; a node powered down to
save energy still counts) and with a CPU free. Idle GPUs on nodes whose CPUs
are all taken are shown as *stranded*, and unknown GPU allocation as unknown
(`?`), never as idle. Storage turns Warning at 75 % and Critical at 90 % of
space or files, whichever is fuller, and is flagged when over quota. Slurm's
job times are cluster (UK) times and are shown in your computer's time zone.
Capacity is not a promise that your job will schedule: reservations, accounts,
QOS, memory and resource placement also matter. Home quota is shared between
clusters; `df` figures are filesystem totals, not a personal quota.

## Differences from the macOS app

This first Linux port is intentionally read-only, including explicit actions.
It has **no** embedded shell, uploads, downloads, rename/delete, job submission,
job cancellation, standalone desktop widget, or automatic GPU-availability alert.
Use your usual SSH client for those operations. Output viewing is a bounded
manual refresh, not an unbounded `tail -F` stream. Storage is not refreshed
every 10 s while the Storage page is open (use **Refresh now**). SSH sessions
end on **Quit**; they do not survive app restarts. **Minimize to tray** (or
**Minimize**) keeps the process and sessions running; closing the window quits.

## Privacy and trust

- Credentials are never put in subprocess arguments, environment variables,
  logs, snapshots, settings, or plaintext files. The optional saved password
  uses a freedesktop.org Secret Service provider explicitly (GNOME Keyring,
  KeePassXC, or a KWallet version with Secret Service support enabled), with no
  plaintext keyring fallback.
- Passwords are held transiently in process memory during sign-in. Python
  strings cannot be reliably zeroed; the input field and worker references are
  cleared after use. Passwords are not retained for automatic reconnection.
- A new host key needs explicit approval **before** authentication. A changed
  key is blocked, not silently accepted. If a key really changed, verify it
  with Leeds IT before editing the app-specific `known_hosts` file.
- There is no SSH agent forwarding. Only fixed Leeds hostnames are contacted.
  No telemetry or public service receives your snapshots or credentials.
- The collector runs its existing read-only POSIX script over SSH (`sh -s`);
  no helper is uploaded or installed remotely. File previews use SFTP read
  operations, not shell interpolation.

Local files are under `${XDG_DATA_HOME:-~/.local/share}/LeedsHPCMonitor` (mode `0700`):

| File | Contents |
|---|---|
| `settings.json` | Last username and route, no password |
| `known_hosts` | Explicitly trusted SSH public keys |
| `<username>-<cluster>.json` | Last successful snapshot and bounded history |

Snapshots contain job names, commands and remote paths. Treat them as private.
The folder is created with mode `0700` and files with mode `0600`. To remove
local monitoring data, quit the app and delete this folder. Use **Forget saved
password** separately to remove the System Keyring entry. Disconnect before
changing your account or route.

## Develop from source

Python 3.11–3.13, 64-bit (tested with Python 3.13).
From the repository root in bash:

```bash
python3 -m venv .venv
./.venv/bin/python -m pip install -r desktop/requirements-dev.txt
./scripts/run_linux_app.sh --demo
./scripts/run_linux_app.sh
```

The scripts use the venv directly; activation is unnecessary.

```bash
./.venv/bin/python -m ruff check desktop
./.venv/bin/python -m ruff format --check desktop
./.venv/bin/python -m pyright -p desktop
./.venv/bin/python -m pytest -c desktop/pyproject.toml desktop/tests -q
./.venv/bin/python scripts/hpc_snapshot.py --self-test
./scripts/build_linux_app.sh --skip-install
```

The build produces `desktop/dist/LeedsHPCMonitor-Linux-x64.tar.gz` (or
`LeedsHPCMonitor-Linux-arm64.tar.gz` on `aarch64`), prints its SHA-256 hash, and
runs an offline frozen-executable startup check. Dependency licence texts are
included alongside the executable. GitHub Actions performs the same checks and
uploads a tarball artifact; it does not publish a release.

The tests use fixtures, an isolated cache, offscreen Qt widgets and a real SSH
server bound only to `127.0.0.1`. They never contact AIRE, Calder or rash, and do
not touch your real System Keyring or SSH configuration. Live Leeds/Duo
compatibility must still be checked by someone with a Leeds account and network
access; passing fixture tests does not prove a real sign-in. Without PySide6
and Paramiko installed (for example on a Mac), `pytest` runs only the
standard-library tests and names the suites it left out.

`LEEDS_HPC_DATA_DIR` can point to an isolated local folder for development.

## Code map

The Windows and Linux apps are one package; only `platform_support.py` differs
by platform.

| Path | Role |
|---|---|
| `desktop/main.py` | Source/frozen entry point |
| `desktop/leeds_hpc_desktop/app.py` | Desktop UI, background tasks, prompts, tray |
| `desktop/leeds_hpc_desktop/ssh.py` | Host verification, Duo auth, shared rash connection, SFTP, the collector's transport |
| `desktop/leeds_hpc_desktop/core.py` | Profiles, snapshot validation, local cache |
| `desktop/leeds_hpc_desktop/rules.py` | The macOS app's rules, ported: node states, GPU pools, job counts, storage tone and cadence, times |
| `desktop/leeds_hpc_desktop/platform_support.py` | Data folder, file permissions, credential store, tray check, platform wording |
| `desktop/leeds_hpc_desktop/demo.py` | Explicit offline examples |
| `scripts/hpc_snapshot.py` | Shared collector and parsers, imported as a library; `run_collection` runs each refresh |
| `desktop/tests/` | Offline regression and loopback SSH tests |

MIT for the app; see `LICENSE` and `desktop/THIRD_PARTY_NOTICES.md` for bundled
third-party components and their separate licences.
