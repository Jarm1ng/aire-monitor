# Security Notes

Leeds HPC Monitor watches the University of Leeds AIRE and Calder clusters at the same time. Its automated monitoring is strictly read-only; the only write-capable paths are user-driven features (the embedded Terminal, the confirmation-gated `Cancel job` action, and the Files tab, described below). This document describes exactly where credentials travel, what is stored where, what the app cannot protect against, and how to report a problem.

AIRE, Calder and the rash jump host (`rash.leeds.ac.uk`) all use the same university account and password, with keyboard-interactive login (password, then Duo). The app therefore holds **one** password, but each cluster gets its own independent SSH ControlMaster and runtime directory.

## Credential Pipeline

The password is handed to local helper processes through **stdin only**: the first line of stdin, once per helper. It never appears on any command line (where other local users could read it via `ps`), and the app never places it in the environment of any process it starts. Every child process the app starts (both login helpers, the collector, remote commands, `scp`, `ssh -O check`, the stop helper, terminals and the widget launcher) gets the app's own environment minus `HPC_PASSWORD`, `HPC_ASKPASS_PASSWORD`, `AIRE_PASSWORD` and `AIRE_ASKPASS_PASSWORD`, so a password exported for the old command-line helpers never reaches them. Children that take no input get `/dev/null` as stdin, never the app's own (a tty when the app is started from a shell).

A plain sign-in (Connect, Connect all, Return in the password field, the menu-bar Connect) reuses a healthy ControlMaster: the password goes unused and no Duo push is sent. Nor does it close a master that still answers: one that answers on its socket but not end to end is left running (exit 5, below). Only the confirmed **Reconnect…** replaces a master (`HPC_FORCE_RELOGIN=1`). The app always sets `HPC_FORCE_RELOGIN` and `HPC_REUSE_ONLY` explicitly, so values exported in a shell are never inherited.

Signing in to one cluster runs up to two helpers, in this order.

### Jump leg (rash route only): `scripts/hpc_ssh_login.expect`

1. The app runs the expect helper with `HPC_SKIP_TARGET=1`, so it handles only the shared rash jump master, and writes the password as the first line of its stdin.
2. The helper reads stdin first and falls back to `HPC_PASSWORD` only when stdin supplied nothing (the same order as the target starter). It then scrubs `HPC_PASSWORD`, `HPC_ASKPASS_PASSWORD` and the pre-rename `AIRE_PASSWORD` / `AIRE_ASKPASS_PASSWORD` from its environment and keeps the secret only in its own process memory.
3. If the shared jump master is healthy (see [Shared jump master safety](#shared-jump-master-safety)), it is reused and the password is never sent anywhere. Otherwise the helper types the password into the interactive prompt of the ssh it spawned (over its pty) and leaves a `-N` jump ControlMaster behind. Spawned ssh processes never inherit the secret in their environment.

### Target leg (both routes): `scripts/hpc_start_target_master.zsh`

1. The app writes the password as the first line of stdin to the target starter, which reads it with `IFS= read -rs` (falling back to `HPC_PASSWORD` only when stdin is empty) and scrubs the same variables from its environment.
2. Unless `HPC_FORCE_RELOGIN=1`, a healthy master on this cluster's socket is reused: `ssh -O check` must pass and a read-only command must run through it within 15 s. Terminals riding on it survive. A master that passes `-O check` but fails the command may be dead or merely slow while it still carries terminals, so the starter leaves it running and exits **5**: nothing is closed, no password is sent, no Duo push goes out, and the app points to Reconnect.
3. On the rash route the starter then checks the shared jump master with `ssh -O check` and exits **3**, before touching any master, if it is not running. Otherwise, a dead jump socket would make the tunnel fall back to a direct connection to rash, and that connection's "Permission denied" could be mistaken for this cluster rejecting the password.
4. Any old master on this socket (on a plain sign-in, only one that failed `-O check`) is closed (`-O exit`, then verified SIGTERM and SIGKILL), and the starter waits for its processes to go, so the dying master cannot unlink the new socket.
5. It creates a FIFO, `askpass.fifo`, with mode **0600** inside the cluster's runtime directory `.runtime/clusters/<id>/`. That directory is forced to **0700** on every login. The starter then begins offering the password on the FIFO and launches the cluster's `ssh -f -N` ControlMaster with `SSH_ASKPASS=scripts/hpc_ssh_askpass.sh`, `SSH_ASKPASS_REQUIRE=force`, `HPC_ASKPASS_FIFO=<fifo path>`, a per-login events file and the cluster's control path. The password is served **once**: AIRE and Calder offer only keyboard-interactive authentication (verified 2026-10-12), so a login has exactly one password prompt. After the first read the writer deletes the FIFO, so a second password prompt (which can only follow a rejection) is refused and a wrong password is never submitted twice in one login.
6. When the authenticating ssh returns (after password and Duo, or at the `HPC_TIMEOUT` deadline), the writer is stopped, the FIFO is deleted and the password variable is cleared. This happens before anything else runs (verification, failure diagnostics).

#### Why a FIFO and not an environment variable

ssh passes its **own** environment to the askpass child. `ssh -f` then daemonizes into the long-lived ControlMaster with that environment intact. A password exported to ssh as an environment variable would therefore live inside the master process for its whole lifetime (up to 24 h after its last client), where the same user can read it with `ps eww`. With the FIFO, nothing secret reaches the master's environment: the only askpass inputs it carries are the FIFO's path (deleted by then), the events-file and control-socket paths, and the Duo menu answer.

The writer offers the password only while the starter is alive:

- Roughly every 0.1 s it checks that the FIFO is still there (and is not a symlink) and that the starter is still its parent process. Then it tries a non-blocking, `nofollow` open-for-write. That open succeeds only while the askpass helper is waiting to read, so the secret is handed over exactly when ssh asks for it. The writer never creates anything at that path.
- If the starter dies, even by `SIGKILL`, the writer is reparented, notices on its next check, and exits. It also deletes the FIFO, but only if the path still names the FIFO this run created (checked by inode), so a newer login is never disturbed. The writer polls instead of blocking because a blocking open would sit inside `open(2)` for the whole Duo wait, unable to notice that the starter had died, and would keep the password available to any later reader.
- The askpass helper reads only from a real FIFO. If the path is missing, is a regular file, or yields an empty line, it refuses (non-zero exit) instead of blocking or answering.

Cancelling a sign-in signals the running helper; the starter's trap stops the authenticating ssh and removes the FIFO.

Legacy fallback: for manual invocation, both login helpers accept `HPC_PASSWORD` when stdin supplied nothing, and scrub it immediately; run at a terminal, the expect helper prompts with echo off instead. The askpass helper accepts `HPC_ASKPASS_PASSWORD` only when no FIFO is configured, and only once. The app never sets any of these.

### Askpass hardening

`scripts/hpc_ssh_askpass.sh` answers exactly two prompt kinds, each at most **once** per login: the login password prompt (from the FIFO) and the Duo passcode/option prompt (`HPC_ASKPASS_DUO_OPTION`, default `1` = push). Anything else is refused with a non-zero exit, so ssh fails fast with a diagnosable error instead of feeding the stored password into the wrong flow.

- Password-change prompts (`new password`, `retype`, `change password`, `current password`, `(current) … password`, `password expired`, `must change your password`) are refused, and the starter reports an expired password (exit 14), not a wrong one. The expect helper refuses the same prompts on the jump leg.
- A repeated Duo prompt means the push was declined or timed out (pam_duo asks again, up to three times). A plain refusal is not enough, because ssh would then send the server an empty answer that may trigger another push. So the helper first ends the ssh that asked, after confirming that its parent's argv carries this cluster's `ControlPath=`, and the starter exits 15. The expect helper aborts its ssh the same way. One login sends at most one push.
- Host-key confirmations and unknown prompts or banners are refused.
- The helper reports to the starter only through the per-login `askpass.events` file, one fixed word per line (`password`, `password-retry`, `password-change`, `duo`, `duo-denied`, `duo-timeout`, `duo-retry`): never prompt text, never a secret.

Host keys are handled with `StrictHostKeyChecking=accept-new`: a first-seen key is recorded, and a changed key aborts the login. No script deletes or edits `known_hosts`.

### Anti-lockout: `NumberOfPasswordPrompts=1`

Every interactive ssh (the master option set in `scripts/hpc_ssh_common.zsh`) and the example `~/.ssh/config` set `NumberOfPasswordPrompts=1`. ssh makes at most one password attempt per authentication method instead of retrying, because with the University IdP repeated attempts can otherwise trigger an account lockout. Both helpers share one exit-code contract:

| Exit | Meaning |
| --- | --- |
| 2 | Configuration error (missing variable, helper or password) |
| 3 | Rash route: the shared jump master is not running (target starter) |
| 4 | `HPC_REUSE_ONLY=1` found no healthy master to adopt |
| 5 | A plain sign-in found a master that answers `-O check` but ran no command within 15 s; it was left untouched, with no password sent and no Duo (target starter) |
| 13 | The host rejected the password |
| 14 | The host demanded a password change (expired password) |
| 15 | The password was accepted but Duo was not approved (declined, timed out, or the connection dropped) |
| 124 | `HPC_TIMEOUT` passed before Duo was reached |

- Exit 13 needs proof: the password was actually sent, then a second password prompt arrived with no Duo exchange in between, or "Permission denied" followed the password. A "Permission denied" attributed to the jump host comes from a broken tunnel and is not counted.
- The app never retries automatically. On 13, 14, 15 or a failed jump leg it cancels every other queued cluster login, so the same wrong password is not sent to the next cluster and no push goes out that nobody will approve. A rejection by the jump leg is reported against the jump host.
- A saved password that was rejected (13) or had expired (14) is flagged for that username and not sent again until a typed password is checked by a server and saved in its place (see [Keychain Storage](#keychain-storage)) or the saved one is forgotten. A Duo failure (15) says nothing about the password and never flags it.
- Refreshes, terminals, file operations, job cancellation and the widget never authenticate. They run with `BatchMode=yes`, password and keyboard-interactive authentication disabled and `ControlMaster=no`, are pre-flighted with `ssh -O check`, and fail with a readable error when the master is gone.

### Shared jump master safety

On the rash route, every cluster's target master reaches its login host through a `ProxyCommand` that is itself a client of **one** shared rash jump master. Closing that master silently kills every other cluster's tunnel, and replacing it costs another Duo approval. The helpers therefore follow these rules:

- Forcing (`HPC_FORCE_RELOGIN=1`, used only by the confirmed Reconnect) applies **only to the cluster's target master**, never to the jump master.
- The jump master is reused when it is healthy. Healthy means `ssh -O check` succeeds **and** a bounded end-to-end probe succeeds: a `-W <cluster-host>:22` channel through the master that must show an `SSH-` banner within `HPC_JUMP_PROBE_TIMEOUT` seconds (default 10). The probe hangs up before authenticating to anything.
- If rash relays the probe but the cluster refuses it, the jump master is kept, and the target leg reports the real error. Refusals include a refused channel, or a login node that closes before its banner (the known Calder "Not allowed at this time" quirk). If the probe merely times out, a second probe to rash's own sshd (`127.0.0.1:22`) decides. Every "refused" verdict is confirmed with another `ssh -O check`.
- Only a jump master that is missing, fails `-O check`, fails at the mux layer, or carries no traffic at all is closed and re-authenticated.
- The tunnel's `ProxyCommand` can only be a client of the jump master: `BatchMode=yes`, public-key, GSSAPI, password and keyboard-interactive authentication off, `ConnectTimeout=20`, `ControlMaster=no`. If the jump socket is gone, ssh's fallback to a direct connection to rash fails at once instead of offering a key or waiting on a prompt. On the direct route, `ProxyCommand=none` and `ProxyJump=none` stop a `~/.ssh/config` entry from rerouting the connection.
- Process kills are verified, and the rules live in one place, `scripts/hpc_ssh_common.zsh`, shared by the starter, the stop helper and the expect helper. A pid is killed only when its argv's **first** `ControlPath=` is this cluster's socket and it carries `ControlMaster=yes`, or its title is exactly `ssh: <this socket> [mux]`. Every master the scripts start runs `-N`, and OpenSSH daemonizes such a master without `control_persist_detach()`, so it keeps its argv as its `ps` title; the `[mux]` title appears only on masters older releases started with a remote command. Every tunnelled master embeds the jump socket path inside its ProxyCommand, so a substring match would kill all of them. Keepalives from older releases are cleaned up only as leftovers, and only when the argv shows `hpc_target_keepalive.zsh` followed by this cluster's control path. The target starter never touches the jump master, other clusters' masters, or their files.

### Session lifetime and sign-out

- Every master (cluster and jump) is started with `-N`, so `ControlPersist=24h` is an **idle** limit: a master closes 24 h after its last client (a refresh, the widget's fallback collection, a terminal, a transfer) went away. There are no keepalive processes. A jump master stays up while any tunnelled cluster master rides on it.
- Quitting the app, pausing a cluster or turning its monitoring off leaves its master running, and the next launch reuses it. For a master it did not start, the app runs the starter once with `HPC_REUSE_ONLY=1`, an empty stdin and no password. That run only verifies the master and ends what older releases left beside it (a 5 s keepalive, a permanent remote `sleep` session that stopped the idle timer); it never prompts, pushes Duo or tears anything down.
- **Disconnect** runs `scripts/hpc_stop_master.zsh` for that cluster's socket only (30 s limit): `-O exit`, verified SIGTERM, SIGKILL after about 3 s, then its pid file and a dead socket file are removed. It refuses a control path equal to the jump socket. When no other enabled cluster is live, signing in or queued on the same jump socket, the app also passes `HPC_STOP_JUMP_IF_UNUSED=1`, and the helper closes the shared jump master too, but only if no process other than the jump master itself names its control path. "Itself" is the pid `ssh -O check` reports (or a `[mux]`-titled master from an older release): an `-N` master's own argv names the path too, and its title cannot tell it from a jump master still authenticating. When nothing answers the check, nothing is left out, so any process naming the path keeps the jump master. A failed Disconnect (a verified master survived SIGKILL) is shown as an error.
- Disconnect asks first when terminals or file transfers on that cluster would close. **Reconnect…** always asks, naming the Duo pushes, the terminals that close and the transfers that stop.
- A route change stops each enabled cluster's previous-route master the same way, so the route picker asks first whenever that would end a live session, a running terminal or an active transfer.
- After a sign-in under another account or host, the previous identity's master is closed only once the new sign-in has succeeded; a failed, cancelled or Duo-less attempt closes nothing. While any terminal of that cluster runs or any file transfer is waiting or running, a plain sign-in keeps the old master (a confirmed Reconnect does not), and it is closed after the first successful refresh with neither, at a later successful sign-in with neither, or by Disconnect. The master the session is live on is never closed this way.
- Route and identity changes never stop the shared jump master.

### Verified by the mock-ssh harness

`python3 scripts/tests/test_login_flow.py` drives the real `scripts/hpc_*` helpers the same way the app does, against a fake `ssh` (`scripts/tests/fake_ssh.py`), through scenarios S1–S16 in about a minute. It needs no network and does not touch `~/.ssh` or live sessions; see [scripts/tests/README.md](scripts/tests/README.md). Security-relevant scenarios:

- **S7** proves that, across every login in the suite, no password (including a stale exported one and one full of shell metacharacters) appears in any logged ssh argv, any runtime file, or the environment of a daemonized master, checked through the recorded environment and through `ps eww`. It also proves that no FIFO is left in any runtime directory.
- **S6** proves that a wrong password exits 13 from the leg that rejected it and leaves the shared jump master untouched, and that a stale exported `HPC_PASSWORD` never overrides the password on stdin.
- **S9** proves that killing only the starter's pid during the Duo wait leaves no password writer and no FIFO behind.
- **S10** and **S11** prove that a declined, timed-out or abandoned push exits 15 on both legs after exactly one push, and that a password-change prompt is never answered (exit 14).
- **S12** proves that a plain login reuses a healthy master without Duo, and that a master answering its socket but running no command is left untouched (exit 5: same pid, no password sent, no Duo) until a forced login replaces it with one push. It also proves the `password sent` contract the Keychain save relies on (a fresh login prints it, a reused master never does), and that `HPC_REUSE_ONLY=1` adopts a master without a password or exits 4. **S13** proves that a timeout leaves no ssh and no FIFO behind.
- **S15** proves that the stop helper stops exactly one route's master, refuses the jump socket, and stops the jump master only once nothing rides on it. Its masters are titled as real `-N` masters are (their own argv, never `[mux]`), so it also proves that the jump master's own argv is never counted as its own rider. **S16** proves that no master runs a remote command, every ProxyCommand is hardened, nothing uses `ControlMaster=auto`, and the collector keeps `ControlMaster=no` and `BatchMode=yes`.

### Shared sessions, Renew all and automatic sign-in

- **Sharing** only adds symlinks in `~/.ssh/ctl/` and at the `ControlPath` of your own matching `~/.ssh/config` aliases. Access is unchanged: a unix socket is reachable only by your user (0600 sockets in 0700 directories), symlink or not. Any program running as you could already open the app's sockets. Sharing makes them easy to find, so `ssh -O exit <alias>` closes the app's session too. Turn sharing off to remove every link. The app never deletes anything it did not create, apart from a dead socket that ssh would unlink itself, and never touches a socket another live session holds. Alias resolution runs `ssh -G`, which evaluates your config locally (including any `Match exec`) and never connects.
- **Renew all** is confirmed first and costs one Duo push per leg.
- **Sign in again after a drop** sends the saved password and a Duo push without a click. It is bounded so a push never arrives unasked:
  - it needs keyboard or mouse input in the last two minutes and a working network;
  - each cluster gets at most three attempts per drop;
  - nothing is retried after a declined or unanswered push, a rejected or expired password, or Cancel sign-in;
  - the existing never-resend rule for a rejected saved password still applies.

  Turn it off in the Sessions card.
- `scripts/hpc-session` never authenticates. It uses `BatchMode`, no config file and `ProxyCommand=false`, so a vanished master fails instead of dialling the host.

## Read-Only Monitoring

- The collector (`scripts/hpc_snapshot.py`) makes one batched round trip per refresh (rarely a second, jobs-only one) over the cluster's existing master. It runs only read-only commands: `sinfo`, `squeue`, `scontrol show node|job`, `df`, `quota`, `lfs quota|project`, `test -d`, `ps`, `hostname` and `whoami`. It writes nothing on the cluster, submits or cancels nothing, and never receives a password.
- It can only be a client: `BatchMode=yes`, password, keyboard-interactive, public-key and GSSAPI authentication off, `ControlMaster=no`, and the same hardened jump ProxyCommand. It checks the master with `ssh -O check` first and reports "control master is not running" instead of dialling out.
- **Job resource use** (`--job-usage`, the Jobs tab's **Sample** switch, default on) is the one section that leaves the login node:
  - Once a minute, while one of your jobs runs, the login node reaches each node of your running jobs with `ssh -o BatchMode=yes`. That uses the cluster's own key setup, and `pam_slurm_adopt` admits you only where you have a job.
  - On the node it reads cgroup counter files and runs one `nvidia-smi --query-gpu` and `sleep 1` inside the adopted job's allocation. It writes nothing, starts no job step, and never sends a password.
  - The only touch on a running job is that second of `nvidia-smi` (tens of MB charged to its cgroup).
  - A first visit may add the node's host key to your cluster-side `~/.ssh/known_hosts` (`StrictHostKeyChecking=accept-new`).
  - Switch **Sample** off to stop it.
- Usernames and hostnames must be plain SSH words (never starting with `-`), and storage path templates may expand only `$USER` and `$HOME`; everything else is single-quoted into the remote script.
- Storage commands are bounded with coreutils `timeout` where the login node has it. Killing the local ssh does not stop a remote command stuck in filesystem I/O, so a `ps -u "$USER"` check skips the whole storage section while a `df`, `quota`, `lfs` or `test -d` from an earlier refresh is still stuck, instead of piling up more. It uses no lock file and writes nothing.
- The desktop widget never handles a password. It reads the app's per-cluster snapshots. Only when the app is not feeding a cluster (no fresh `app_state.json`) does it run the collector itself, with the password-free arguments the app recorded in `collector.json`, and never when the control socket is missing. It executes only a script path that resolves inside the checkout (no absolute path, `~`, `..` or symlink escape).

## Interactive Terminal, Job Cancellation, and Files

Everything in this section is per cluster: an AIRE action always rides AIRE's own ControlMaster and can never use Calder's, and vice versa.

The embedded terminal executes only what the user explicitly types (or triggers by clicking a quick-command chip); the app never runs a terminal command on its own initiative. Every terminal is a local `ssh -tt` child that multiplexes over the cluster's **already-authenticated** ControlMaster socket, with `BatchMode=yes`, password and keyboard-interactive authentication disabled and `ControlMaster=no`, so no credentials ever pass through a terminal session. Before launching, the app checks the master with `ssh -O check`, because with a dead master ssh would otherwise dial the host directly and bypass the jump host; a dead master gives a readable error, never a prompt. Closing a terminal session terminates its ssh child process.

The `Cancel job` action runs `scancel <jobid>` (job id shell-quoted), or `scancel --state=PENDING <array id>` for a pending array remainder so its running tasks are left alone. It runs on that job's cluster only, over the same authenticated channel, and only after an explicit in-app confirmation dialog.

The Files tab follows the same model, with one browser per cluster. Every operation (list, preview, upload, download, new folder, rename, trash, restore, empty trash, permanent delete) is user-initiated and runs over that cluster's master, pre-flighted with `ssh -O check`. Remote commands go through the master, and transfers go through `scp` with the same client options. No credentials are ever involved.

- **Remote names are untrusted data.** The remote half is small Python programs run as `python3 -I -c <script> <args>` (the system `/usr/bin/python3` when present; `-I` keeps a stray `~/json.py` or `PYTHONPATH` out). Every path travels in argv, single-quote-escaped, and results come back as JSON rather than parsed `ls` output. The few shell one-liners quote every path and put `--` before it. Names that are not valid UTF-8 are flagged, and the app refuses to act on them rather than guess. Every remote command is also bounded on the server with `timeout -k 5`, because killing the local ssh does not stop it.
- **Protected paths.** Trash and permanent delete refuse relative paths, paths with `.`, `..` or empty components, top-level folders (`/users`, `/mnt`, `/scratch-calder`, ...), the home directory, every storage root and any ancestor of one. The app checks first, and the remote script checks again on the login node against `realpath`'d roots right before acting.
- **Trash first.** The default delete is a recoverable rename into a fresh run folder: `~/.aire-trash/<time>-<id>/` for items on the home filesystem, or a `.aire-trash` folder beside items on scratch or flash, so nothing is copied into the home quota. The folder keeps its single-cluster name, and AIRE and Calder share the copy in the home directory because both mount the same `/users` home. When no such folder can be created, copying into the home trash happens only after a separate confirmation. Each run carries a `.manifest.json` of original paths, and runs beside scratch/flash items are indexed in `~/.aire-trash/.index/`. Inside a run folder the names `.manifest.json` and `.manifest.json.tmp-<digits>` (the manifest and its temporary file) are reserved, so a user item with one of them is stored under a numbered name such as `.manifest (2).json` instead of being overwritten, hidden or unlinked with the manifest; a look-alike such as `.manifest.json.tmp.bak` keeps its own name. Restore never overwrites an existing name.
- **Unreachable runs.** An indexed run the login node cannot reach (the run folder, its `.aire-trash` or the folder holding them renamed, moved or trashed, or deleted outside the app; an I/O error; or a storage root not mounted there) stays listed, but is never measured, restored or emptied: what is at its path now is unknown. Its index entry is dropped on its own only when the run is provably gone (Restore emptied it, or the app's own permanent delete removed that exact run folder). Forget, offered for any missing run (its folder not at its path), drops only its index entry and deletes nothing.
- **Permanent delete** needs two separate confirmations from the file list. Empty in the Trash sheet asks once, since its items are already in the trash.
- **Detached jobs.** Permanent deletes and confirmed home-trash copies run detached on the login node, in their own session, with a private `mkdtemp` folder (`hpc-monitor-op-*`, in the login node's temp directory) holding the request, progress and errors. They keep running if the app quits or the connection drops. Cancel sends SIGTERM to the job's process group only after checking that the folder is the user's own `hpc-monitor-op-*` directory and that the pid's command line names it. A copy writes `<name>.partial`, renames it into place and only then removes the original; that removal, like the clean-up of a partial copy, runs in a session of its own, out of the signal's reach, so a cancelled copy never leaves an original half-deleted.
- **Large selections** that would not fit on one command line are uploaded as a NUL-separated list, `/tmp/hpc-monitor-args-<uuid>` on the login node. The scripts accept it only as a regular file (not a symlink) owned by the user, and delete it as soon as it is read.
- **Transfers never overwrite.** A download reserves a fresh local name, and both directions write a hidden `.<name>.part-xxxxxxxx` file first; an upload is linked into place with a no-clobber `ln` (falling back to `mv -n`). Quitting cancels unfinished transfers and removes their partial files (remote ones with a bounded, detached `rm -f`).

## Keychain Storage

With `Remember in Keychain` enabled, the password is stored in the user's macOS Keychain after a successful sign-in in which a server actually checked it:

- Item class: generic password, service **`AIREMonitor.AIREPassword`** (the name is kept from the single-cluster releases)
- Account: **`leeds:<username>`**. A single item holds the university password used for rash, AIRE and Calder.
- Accessibility: **`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`**. The item never leaves this device (it is excluded from iCloud Keychain and unencrypted backups) and is only readable while the device is unlocked. The attribute is also applied on every update, so items created before this policy converge on the next save.
- Writes: "checked" means some leg printed `HPC-STATUS: password sent (…)` and the sign-in then succeeded. The item is then saved when the password was typed into the form or nothing is saved under `leeds:<username>` yet. A sign-in that only reused open sessions never sends the password, so it never saves a typed one. Saving a typed password is also what lifts a "rejected" flag.
- Reads: Keychain calls run off the main thread. A denied access prompt is reported as such, never as "no saved password".
- Migration: older releases kept one item per connection, under `explicit:<user>@<host>:<route>` (route `direct` or `via:<jump-host>`), plus the original `<user>@leeds`. These legacy accounts are still **read** as a fallback, checked for every configured cluster host on both routes. They are **deleted** once the password has been saved under `leeds:<username>`. Items under the old `alias:<alias>` accounts (from the removed alias mode) are neither read nor deleted; remove them with Keychain Access if you have any.
- Removal: the sidebar `Forget` button deletes `leeds:<username>` and all of the legacy accounts above. Switching `Remember in Keychain` off while a password is saved asks whether to remove it too.

With `Remember in Keychain` disabled, the password exists only in app memory while the queued sign-ins run; the password field is cleared after a successful sign-in.

macOS may ask whether Leeds HPC Monitor may use your confidential information after a rebuild. `scripts/build_bundle.sh` signs both bundles with their real identifiers (`local.aire.monitor`, `local.aire.desktop-widget`), using `HPC_CODESIGN_IDENTITY` if set, otherwise a code-signing certificate named "Leeds HPC Monitor Local" if your keychain has one, otherwise ad hoc. An ad-hoc signature changes on every rebuild, so Keychain asks again after each one. To stop that, create a self-signed certificate once (Keychain Access > Certificate Assistant > Create a Certificate, name "Leeds HPC Monitor Local", identity type Self Signed Root, certificate type Code Signing).

## Data Inventory

`<id>` is the cluster id (`aire`, `calder`). Each cluster has its own directory; nothing in it is shared between clusters.

| Location | Contents | Secrets? |
| --- | --- | --- |
| macOS Keychain (`AIREMonitor.AIREPassword`, account `leeds:<username>`) | The university password | Yes. This is the only persistent credential store. |
| App defaults (domain `local.aire.monitor`) | Project root, a per-username "saved password was rejected" flag, view preferences | No |
| `.runtime/preferences.json` | Username, route, jump host, Duo option, the Remember in Keychain choice, per-cluster enabled flag and hostname, sidebar selection | Password-free by design |
| `.runtime/clusters/<id>/latest_snapshot.json`, `snapshot_history.jsonl`, `job_state.json` | Latest snapshot, trend history (up to 1440 points) and the job-state baseline for notifications, with usernames, job names, node names, filesystem paths, quota numbers and Lustre project ids | No passwords, but private cluster details |
| `.runtime/clusters/<id>/app_state.json` | Whether the app is feeding the cluster (enabled, paused, live, refresh interval, time), read by the widget | No |
| `.runtime/clusters/<id>/collector.json` | The exact collector argument list (username, hostnames, socket paths, storage spec) for the widget fallback | Password-free by design |
| `.runtime/clusters/<id>/login_debug.log` | Helper event log plus the stdout/stderr transcript of each sign-in, including hostnames, usernames and timings | No passwords |
| `.runtime/clusters/<id>/master_ssh.log`, `master-<socket name>.pid` | ssh master output; the master's pid, one file per control path (route and username) | No passwords |
| `.runtime/clusters/<id>/askpass.events` | The last login's askpass events, as fixed words | No |
| `.runtime/clusters/<id>/askpass.fifo` | Exists only while that cluster's target master is authenticating; never a regular file | Carries the password in transit only |
| `.runtime/clusters/<id>/askpass.log` | Only written with `HPC_DEBUG=1`, see below | Redacted |
| `.runtime/swift-build.log`, `swift-widget-build.log`, `widget-launcher.log`, `.build_bundle.lock`, `*.app` | Build and launcher output, the build lock, the assembled app bundles | No |
| `~/.ssh/ctl/<id>-<hash>.sock`, `~/.ssh/ctl/jump-<hash>.sock` | OpenSSH ControlMaster sockets, see below | Access to the live authenticated session while it exists |
| `~/Library/Application Support/LeedsHPCMonitor/app.lock` | Lock that keeps one app instance per user | No |
| Unified log (subsystem `local.aire.monitor`) | Refresh, sign-in, cache, notification and Keychain events; usernames and hostnames are logged as private | Never the password |

A JSON file that no longer decodes is renamed to `<name>.bad` next to the original instead of being overwritten.

Permissions: the shell helpers run with `umask 077`, so their logs, pid files and the events file are created **0600**, and `login_debug.log` is set to 0600 explicitly. The target starter forces `~/.ssh/ctl` and the cluster's runtime directory to **0700** on every login (the expect helper does the same for `~/.ssh/ctl`), and the app creates both with mode 0700 when they do not exist yet. `scripts/build_bundle.sh` creates `.runtime/` itself with mode **0700** when it is missing, but leaves an existing one as it is. The app writes the JSON files and `widget-launcher.log` with default permissions (typically 0644), so if your `.runtime/` predates that change and the Mac is shared with other users, run `chmod -R go-rwx .runtime` once. The entire `.runtime/` directory is gitignored.

Files from single-cluster releases are migrated on first launch. `.runtime/latest_snapshot.json`, `snapshot_history.json` and `job_state.json` are moved into `.runtime/clusters/aire/` (the history is then converted to `snapshot_history.jsonl`), and `.runtime/connection_profile.json` seeds `preferences.json`. Older leftovers are not deleted automatically: top-level `connection_profile.json`, `aire_master_ssh.log`, `aire_askpass.log` and keepalive logs, and `keepalive.log` / `keepalive_starter.log` in the cluster directories. Remove them once you no longer need them.

### ControlMaster sockets

All sockets live in the short, home-anchored `~/.ssh/ctl/` directory (0700), whatever the project path. Unix socket paths are capped at 104 bytes on macOS, and hashed names also keep usernames out of the file names. The hash is not a secret, though: anyone who knows the username and host can recompute it.

- **Cluster master**: `~/.ssh/ctl/<id>-<hash>.sock`, where `<hash>` is the first 12 hex characters of the SHA-256 of `<user>@<host>:direct` or `<user>@<host>:via-<jump-host>`. There is one socket per cluster and route. The key format is unchanged from the single-cluster releases, so a live AIRE master survives an upgrade.
- **Jump master**: `~/.ssh/ctl/jump-<hash>.sock`, hashed from `<user>@<jump-host>`, and **shared by every cluster**. When the expect helper is run by hand without `HPC_JUMP_CONTROL_PATH`, it falls back to `~/.ssh/ctl/jump-cli-<username>.sock`.

While a master is alive (up to 24 h after its last client), any process running as your macOS user can open new sessions through it without a password. Disconnect ends one; by hand, run `ssh -S <socket> -O exit <host>`. Closing the jump master also drops every cluster's tunnel through it.

### Debug logging (`HPC_DEBUG=1`)

Askpass prompt logging is **off by default**. When `HPC_DEBUG=1` is set in the target starter's environment, the askpass helper appends the prompt kind and text to `.runtime/clusters/<id>/askpass.log`. Every digit is replaced by `X`, so Duo enrolled-device hints and phone numbers never reach disk. The app passes its own environment to the helpers, so to enable logging for app sign-ins, quit the app and start its executable from a shell with `HPC_DEBUG=1` set. The pre-rename `AIRE_DEBUG` is no longer read. `HPC_SSH_VERBOSE=1` adds `-vv` output to `master_ssh.log`. The password itself is never logged under any setting.

## Known Limits

- Any process running as your macOS user can use a live master without a password (see above), and can read everything under `.runtime/`.
- The helpers and the collector run from the project checkout, and the helpers receive the password. Anyone who can write to that checkout can change what receives it, so keep it writable only by you.
- The app cannot wipe the password from its own memory: Swift strings are not zeroed after use.
- Terminals, transfers and remote commands do not disable public-key authentication. If a master disappears between the `-O check` pre-flight and launch, ssh dials the host directly (bounded by `ConnectTimeout=5`) and may offer a local key, which the keyboard-interactive-only clusters refuse.
- Trash folders are created with the login node's umask, not a private mode: an item trashed out of a private folder keeps its own permissions but no longer sits behind that folder. The staged argument list in `/tmp` also follows the umask; it holds paths only, and only until the script reads it.
- After a route change from rash to direct, the shared jump master is left to close on its 24 h idle limit.

## Do Not Commit

- passwords
- SSH private keys
- local `.ssh/config` files with personal aliases (`config/aire_ssh_config.example` is the shareable template; a personalized `config/aire_ssh_config` is gitignored)
- anything under `.runtime/`
- Slurm output or error logs that include private paths or research data
- real usernames, Lustre project ids, or personal quota figures in test fixtures and examples (use placeholders such as `<username>`, `<project-id>`)

### Pre-commit checklist

Before pushing, scan the staged diff for identifying material (replace `<your-username>` with your actual cluster username):

```bash
git diff --cached | grep -inE '<your-username>|/users/[a-z0-9]+|/(mnt/scratch|mnt/flash|scratch-aire|flash-aire|scratch-calder|flash-calder)/(users/)?[a-z]*[0-9]|prj [0-9]+|-[0-9a-f]{12}\.sock'
```

The pattern flags home paths, and with `-i` also local macOS `/Users/<name>` paths. It flags personal directories under AIRE and Calder scratch/flash (`/mnt/scratch/`, `/mnt/flash/`, `/scratch-calder/`, `/flash-calder/`, and the future `/scratch-aire/`, `/flash-aire/`), Lustre project ids as printed by `lfs quota -p` (`prj <id>`), and real hashed control-socket names. Path templates such as `/scratch-calder/users/$USER` do not match.

The tests, fixtures and scripts deliberately use placeholders that this pattern also flags: the username `abcd1234` (and short stand-ins such as `alice`, `someone`, `u`, `x`, `me`), the project id `123456`, the socket hashes the Swift tests derive from `abcd1234`, and the example socket name in `scripts/hpc_ssh_common.zsh`. Hits on those placeholders are expected; investigate anything else.

Concretely, check that the diff contains:

- no real usernames (yours or teammates')
- no personal hostnames beyond the public `aire.leeds.ac.uk`, `calder.leeds.ac.uk` and `rash.leeds.ac.uk` names
- no control-socket paths or `.runtime/` file contents
- no pasted terminal output with home, scratch or flash paths, project ids or quota usage

## Reporting a Vulnerability

Please report suspected vulnerabilities privately through **GitHub's private security advisories** ("Report a vulnerability" under the repository's Security tab) rather than in a public issue. Include the affected script or component and reproduction steps if possible.

If you discover an accidental sensitive-data exposure (a committed credential, username, or private log), remove the affected public data immediately, rewrite history if needed, and rotate any exposed credential.
