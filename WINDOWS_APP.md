# Leeds HPC Monitor for Windows

A Windows desktop port of the read-only monitoring features. The macOS SwiftUI
application is unchanged. The Windows app uses Python, Qt (PySide6) and Paramiko,
and imports the same `scripts/hpc_snapshot.py` collector and parsers as the Mac.
It does not need WSL, OpenSSH ControlMaster, Xcode, or anything installed on the
cluster.

## Run the portable app

Windows 10/11, 64-bit. Extract the **entire** `LeedsHPCMonitor-Windows-x64.zip`
archive into a folder you can write to, then open `LeedsHPCMonitor.exe` inside
the extracted `LeedsHPCMonitor` folder. Keep `_internal` next to the executable.
Python is bundled; a separate Python installation is not needed.

The build is unsigned: Windows SmartScreen may warn about an unknown publisher.
There is no installer, auto-updater or request for administrator privileges.
Only run builds whose source and download you trust.

1. Connect to the University VPN (or campus network), or choose **Via rash jump
   host** for off-VPN access.
2. Enter your university username and password; select AIRE, Calder, or both.
3. Optionally tick **Save in Credential Manager**. The default is not to save.
4. Click **Connect selected**. On first connection, verify each host's SHA-256
   fingerprint with Leeds IT or a known-good connection before trusting it.
5. Answer any Duo selection/passcode prompts and approve the push on your phone.

Sign-ins are serial: one cluster's Duo prompt at a time. The rash SSH connection
is shared when connecting both clusters. A rejected password, cancelled Duo
dialog, or declined host key stops the remaining queued sign-ins. There is no
automatic password retry. After a failure, correct the problem before pressing
Connect again.

To try the interface without credentials or network access:

```powershell
.\LeedsHPCMonitor.exe --demo
```

Demo mode labels every screen as synthetic, disables sign-in, and never writes
example snapshots into the live cache.

## Included

- Overview cards with separate AIRE/L40S and Calder/H200 capacity, job counts,
  snapshot age and explicit live/stale/offline status.
- Jobs, partitions, nodes and storage tables; a cluster filter on every page.
- Job details and a manually refreshed, bounded stdout tail (last 128 KiB).
- Read-only SFTP directory browsing and text previews (first 128 KiB).
- Per-cluster free-GPU charts and recent CPU/queue/node-health history.
- Ten-second refreshes over persistent authenticated SSH connections. One
  cluster's refresh failure does not discard the other's data.
- Windows notification-area icon, minimize-to-tray, and notifications when a
  job starts or leaves the active queue. Leaving the queue is **not** described
  as successful completion: its final status is unknown.
- Local, account-scoped snapshots and up to 8,640 history points per cluster.
  Offline data always remains labelled as cached/stale.

Free capacity excludes down, drained, failed, unresponsive and power-transition
nodes. Unknown GPU allocation is shown as unknown, not as free. Capacity is not
a promise that your job will schedule: reservations, accounts, QOS, memory and
resource placement also matter. Home quota is shared between clusters; `df`
figures are filesystem totals, not a personal quota.

## Differences from the macOS app

This first Windows port is intentionally read-only, including explicit actions.
It has **no** embedded shell, uploads, downloads, rename/delete, job submission,
job cancellation, standalone desktop widget, or automatic GPU-availability alert.
Use your usual SSH client for those operations. Output viewing is a bounded
manual refresh, not an unbounded `tail -F` stream. SSH sessions end on **Quit**;
they do not survive app restarts. **Minimize to tray** keeps the process and
sessions running; closing the window quits.

## Privacy and trust

- Credentials are never put in subprocess arguments, environment variables,
  logs, snapshots, settings, or plaintext files. The optional saved password
  uses Windows Credential Manager explicitly (no plaintext keyring fallback).
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

Local files are under `%LOCALAPPDATA%\LeedsHPCMonitor`:

| File | Contents |
|---|---|
| `settings.json` | Last username and route, no password |
| `known_hosts` | Explicitly trusted SSH public keys |
| `<username>-<cluster>.json` | Last successful snapshot and bounded history |

Snapshots contain job names, commands and remote paths. Treat them as private.
The folder uses your Windows profile's inherited permissions. To remove local
monitoring data, quit the app and delete this folder. Use **Forget saved
password** separately to remove the Credential Manager entry. Disconnect before
changing your account or route.

## Develop from source

Python 3.11–3.13, 64-bit (the Windows build is tested with Python 3.13).
From the repository root in PowerShell:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r windows\requirements-dev.txt
.\scripts\run_windows_app.ps1 -Demo
.\scripts\run_windows_app.ps1
```

The scripts use the venv directly; activation is unnecessary. If your local
PowerShell policy blocks scripts, use `python windows\main.py` with the venv
Python, or review the script and use a process-scoped policy appropriate to your
machine. Do not change machine-wide security settings just to launch the app.

```powershell
.\.venv\Scripts\python.exe -m ruff check windows
.\.venv\Scripts\python.exe -m ruff format --check windows
.\.venv\Scripts\python.exe -m pyright -p windows
.\.venv\Scripts\python.exe -m pytest -c windows\pyproject.toml windows\tests -q
.\.venv\Scripts\python.exe scripts\hpc_snapshot.py --self-test
.\scripts\build_windows_app.ps1 -SkipInstall
```

The build produces `windows\dist\LeedsHPCMonitor-Windows-x64.zip`, prints its
SHA-256 hash, and runs an offline frozen-executable startup check. Dependency
licence texts are included alongside the executable. GitHub Actions performs
the same checks and uploads a ZIP artifact; it does not publish a release.

The tests use fixtures, an isolated cache, offscreen Qt widgets and a real SSH
server bound only to `127.0.0.1`. They never contact AIRE, Calder or rash, and do
not touch your real Credential Manager or SSH configuration. Live Leeds/Duo
compatibility must still be checked by someone with a Leeds account and network
access; passing fixture tests does not prove a real sign-in.

`LEEDS_HPC_DATA_DIR` can point to an isolated local folder for development.

## Code map

| Path | Role |
|---|---|
| `windows/main.py` | Source/frozen entry point |
| `windows/aire_windows/app.py` | Desktop UI, background tasks, prompts, tray |
| `windows/aire_windows/ssh.py` | Host verification, Duo auth, shared rash connection, SFTP |
| `windows/aire_windows/core.py` | Profiles, cache validation, capacity calculations |
| `windows/aire_windows/demo.py` | Explicit offline examples |
| `scripts/hpc_snapshot.py` | Unmodified shared collector and parsers |
| `windows/tests/` | Offline regression and loopback SSH tests |

MIT for the app; see `LICENSE` and `windows/THIRD_PARTY_NOTICES.md` for bundled
third-party components and their separate licences.
