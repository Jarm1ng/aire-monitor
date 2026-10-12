# Security Notes

Leeds HPC Monitor watches the University of Leeds AIRE and Calder clusters at the same time. Its automated monitoring is strictly read-only; the only write-capable paths are user-driven features (the embedded Terminal, the confirmation-gated `Cancel job` action, and the Files tab, described below). This document describes exactly where credentials travel, what is stored where, and how to report a problem.

AIRE, Calder and the rash jump host (`rash.leeds.ac.uk`) all use the same university account and password, with keyboard-interactive login (password, then Duo). The app therefore holds **one** password, but each cluster gets its own independent SSH ControlMaster, runtime directory and helper processes.

## Credential Pipeline

The password is handed to local helper processes through **stdin only**: the first line of stdin, once per helper. It never appears on any command line (where other local users could read it via `ps`), and the app never places it in the environment of any process it starts.

Signing in to one cluster runs up to two helpers, in this order.

### Jump leg (rash route only): `scripts/hpc_ssh_login.expect`

1. The app runs the expect helper with `HPC_SKIP_TARGET=1`, so it handles only the shared rash jump master, and writes the password as the first line of its stdin.
2. The helper reads it, immediately scrubs `HPC_PASSWORD`, `HPC_ASKPASS_PASSWORD` and the pre-rename `AIRE_PASSWORD` / `AIRE_ASKPASS_PASSWORD` from its environment, and keeps the secret only in its own process memory.
3. If the shared jump master is healthy (see [Shared jump master safety](#shared-jump-master-safety)), it is reused and the password is never sent anywhere. Otherwise the helper types the password into the interactive prompt of the ssh it spawned (over its pty) and leaves a jump ControlMaster behind. Spawned ssh processes never inherit the secret in their environment.

### Target leg (both routes): `scripts/hpc_start_target_master.zsh`

1. The app writes the password as the first line of stdin to the target starter, which reads it with `IFS= read -rs` and scrubs the same variables from its environment.
2. On the rash route the starter first checks the shared jump master with `ssh -O check` and exits **3**, before touching any master, if it is not running. Otherwise, a dead jump socket would make the tunnel fall back to a direct connection to rash, and that connection's "Permission denied" could be mistaken for this cluster rejecting the password.
3. It creates a FIFO, `askpass.fifo`, with mode **0600** inside the cluster's runtime directory `.runtime/clusters/<id>/`. That directory is forced to **0700** on every login. The starter then begins offering the password on the FIFO and launches the cluster's `ssh -f` ControlMaster with `SSH_ASKPASS=scripts/hpc_ssh_askpass.sh`, `SSH_ASKPASS_REQUIRE=force` and `HPC_ASKPASS_FIFO=<fifo path>`. The password is served **once**: AIRE and Calder offer only keyboard-interactive authentication (verified 2026-10-12), so a login has exactly one password prompt. After the first read the writer deletes the FIFO, so a second password prompt (which can only follow a rejection) is refused and a wrong password is never submitted twice in one login. Password-change prompts (an expired password) are refused too; the helper records the fact in a per-login `askpass.events` file (a fixed word, never prompt text) and the starter exits 14.
4. When `ssh -f` returns (after password and Duo), the writer is stopped, the FIFO is deleted and the password variable is cleared. This happens before anything else runs (keepalive, verification, failure diagnostics).

#### Why a FIFO and not an environment variable

ssh passes its **own** environment to the askpass child. `ssh -f` then daemonizes into the long-lived ControlMaster with that environment intact. A password exported to ssh as an environment variable would therefore live inside the master process for its whole `ControlPersist=24h` lifetime, where the same user can read it with `ps eww`. With the FIFO, nothing secret reaches the master's environment: the only askpass inputs it carries are the FIFO's path (deleted by then) and the Duo menu answer.

The writer offers the password only while the starter is alive:

- Roughly every 0.1 s it checks that the FIFO is still there (and is not a symlink) and that the starter is still its parent process. Then it tries a non-blocking, `nofollow` open-for-write. That open succeeds only while the askpass helper is waiting to read, so the secret is handed over exactly when ssh asks for it. The writer never creates anything at that path.
- If the starter dies, even by `SIGKILL`, the writer is reparented, notices on its next check, and exits. It also deletes the FIFO, but only if the path still names the FIFO this run created (checked by inode), so a newer login is never disturbed. The writer polls instead of blocking because a blocking open would sit inside `open(2)` for the whole Duo wait, unable to notice that the starter had died, and would keep the password available to any later reader.
- The askpass helper reads only from a real FIFO. If the path is missing, is a regular file, or yields an empty line, it refuses (non-zero exit) instead of blocking or answering.

Legacy fallback: both login helpers still accept `HPC_PASSWORD` from the environment for manual invocation and scrub it immediately. The expect helper checks it before stdin; the starter uses it only when stdin supplied nothing. The askpass helper accepts `HPC_ASKPASS_PASSWORD` only when no FIFO is configured. The app never sets any of these.

### Askpass hardening

`scripts/hpc_ssh_askpass.sh` answers exactly two prompt kinds: login password prompts (from the FIFO) and Duo passcode/option prompts (`HPC_ASKPASS_DUO_OPTION`, default `1` = push). Anything else is refused with a non-zero exit, so ssh fails fast with a diagnosable error instead of feeding the stored password into the wrong flow. Refused prompts include password-change flows (`new password`, `retype`, `change password`, `current password`), host-key confirmations and unknown prompts or banners.

Host keys are handled with `StrictHostKeyChecking=accept-new`: a first-seen key is recorded, and a changed key aborts the login. No script deletes or edits `known_hosts`.

### Anti-lockout: `NumberOfPasswordPrompts=1`

Every interactive and askpass ssh invocation (and the example `~/.ssh/config`) sets `NumberOfPasswordPrompts=1`. ssh makes at most one password attempt per authentication method instead of retrying, because with the University IdP repeated attempts can otherwise trigger an account lockout. Further guards:

- The expect helper exits with code **13** when a second password prompt appears without a Duo exchange in between.
- The target starter exits with code **13** when the master's log shows the cluster refusing the password. A "Permission denied" attributed to the jump host comes from a broken tunnel and is not counted.
- The app maps exit 13 to a clear "password was rejected" message. When the jump leg rejected the password, the message names the jump host. The app never retries automatically, and it cancels every other queued cluster login, so the same wrong password is not sent to the next cluster.
- Background refreshes, keepalives, terminals and file operations never authenticate. They run with `BatchMode=yes` and password/keyboard-interactive disabled, and fail with a readable error when the master is gone. The collector (`scripts/hpc_snapshot.py`) also disables public-key and GSSAPI authentication and sets `ControlMaster=no`, so it can only be a client of an existing master.

### Shared jump master safety

On the rash route, every cluster's target master reaches its login host through a `ProxyCommand` that is itself a client of **one** shared rash jump master. Closing that master silently kills every other cluster's tunnel, and replacing it costs another Duo approval. The helpers therefore follow these rules:

- Every app login is a forced re-login (`HPC_FORCE_RELOGIN=1`), but forcing applies **only to the cluster's target master**, never to the jump master.
- The jump master is reused when it is healthy. Healthy means `ssh -O check` succeeds **and** a bounded end-to-end probe succeeds: a `-W <cluster-host>:22` channel through the master that must show an `SSH-` banner within `HPC_JUMP_PROBE_TIMEOUT` seconds (default 10). The probe hangs up before authenticating to anything.
- If rash relays the probe but the cluster refuses it, the jump master is kept, and the target leg reports the real error. Refusals include a refused channel, or a login node that closes before its banner (the known Calder "Not allowed at this time" quirk). If the probe merely times out, a second probe to rash's own sshd (`127.0.0.1:22`) decides. Every "refused" verdict is confirmed with another `ssh -O check`.
- Only a jump master that is missing, fails `-O check`, fails at the mux layer, or carries no traffic at all is closed and re-authenticated.
- Process kills are verified. A pid is killed only when its title is exactly `ssh: <this socket> [mux]`, or its argv's **first** `ControlPath=` is this cluster's socket and it carries `ControlMaster=yes`. Every tunnelled master embeds the jump socket path inside its ProxyCommand, so a substring match would kill all of them. A stale keepalive is killed only when its argv shows both `hpc_target_keepalive.zsh` and this cluster's control path. The target starter never touches the jump master, other clusters' masters, or their files.

### Verified by the mock-ssh harness

`python3 scripts/tests/test_login_flow.py` drives the real `scripts/hpc_*` helpers the same way the app does, against a fake `ssh` (`scripts/tests/fake_ssh.py`). It needs no network and does not touch `~/.ssh` or live sessions; see [scripts/tests/README.md](scripts/tests/README.md). Security-relevant scenarios:

- **S7** proves that, across every login in the suite, the password never appears in any logged ssh argv, any runtime file, or the environment of a daemonized master. Masters are checked both through their recorded environment and through `ps eww`. S7 also proves that no FIFO is left in any runtime directory.
- **S9** proves that killing only the starter's pid during the Duo wait leaves no password writer and no FIFO behind.
- **S6** proves that a wrong password exits 13 from the leg that rejected it, and leaves the shared jump master untouched.

## Interactive Terminal, Job Cancellation, and Files

Everything in this section is per cluster: an AIRE action always rides AIRE's own ControlMaster and can never use Calder's, and vice versa.

The embedded terminal executes only what the user explicitly types (or triggers by clicking a quick-command chip); the app never runs a terminal command on its own initiative. Every terminal is a local `ssh -tt` child that multiplexes over the cluster's **already-authenticated** ControlMaster socket. It runs with `BatchMode=yes` and password/keyboard-interactive authentication disabled, so no credentials ever pass through a terminal session. Before launching, the app checks the master with `ssh -O check`, because with a dead master ssh would otherwise dial the host directly and bypass the jump host. If the master is dead, the session fails with a readable error instead of prompting, and the app has no code path that types a password into a terminal. The `Cancel job` action runs `scancel <jobid>` (job id shell-quoted) on that job's cluster only, over the same authenticated channel and only after an explicit in-app confirmation dialog. Closing a terminal session terminates its ssh child process.

The Files tab follows the same model, with one browser per cluster. Every file operation (list, preview, upload, download, rename, delete) is user-initiated and runs over that cluster's authenticated multiplexed channel: remote commands go through the ControlMaster, and transfers go through `scp` bound to the same socket with `BatchMode=yes`. No credentials are ever involved. Destructive actions are confirmation-gated and trash-first: the default delete is a recoverable `mv` into a `.aire-trash` folder on the server. The folder keeps its single-cluster name for continuity, and the copy in the home directory is shared by AIRE and Calder because both mount the same `/users` home. The irreversible permanent delete requires two separate confirmations. It also refuses, independently of the UI, `/`, `~`, the home directory itself, relative paths, and paths with `.`/`..`/empty components. Remote file **names** are treated as untrusted data end-to-end. Directory listings arrive through a remote-python JSON protocol rather than parsed `ls` output. Every name interpolated into a shell command is single-quote-escaped and preceded by a `--` separator, so hostile names (spaces, quotes, `$()`, leading dashes, invalid UTF-8) can never become commands or flags.

The desktop widget never handles a password. It reads the app's per-cluster snapshots. As a fallback it runs the collector with the password-free arguments the app recorded in `collector.json`, over the existing ControlMaster, and the collector itself runs with `BatchMode=yes` and every interactive authentication method disabled.

## Keychain Storage

With `Remember in Keychain` enabled, the password is stored in the user's macOS Keychain after a successful sign-in:

- Item class: generic password, service **`AIREMonitor.AIREPassword`** (the name is kept from the single-cluster releases)
- Account: **`leeds:<username>`**. A single item holds the university password used for rash, AIRE and Calder.
- Accessibility: **`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`**. The item never leaves this device (it is excluded from iCloud Keychain and unencrypted backups) and is only readable while the device is unlocked. The attribute is also applied on every update, so items created before this policy converge on the next save.
- Writes: the item is saved after a successful sign-in, either when the password was typed into the form or when nothing is saved under `leeds:<username>` yet.
- Migration: older releases kept one item per connection, under `explicit:<user>@<host>:<route>` (route `direct` or `via:<jump-host>`), plus the original `<user>@leeds`. These legacy accounts are still **read** as a fallback, checked for every configured cluster host on both routes. They are **deleted** once the password has been saved under `leeds:<username>`. Items under the old `alias:<alias>` accounts (from the removed alias mode) are neither read nor deleted; remove them with Keychain Access if you have any.
- Removal: the sidebar `Forget` button deletes `leeds:<username>` and all of the legacy accounts above.

With `Remember in Keychain` disabled, the password exists only in app memory while the queued sign-ins run; the password field is cleared after a successful sign-in.

## Data Inventory

`<id>` is the cluster id (`aire`, `calder`). Each cluster has its own directory; nothing in it is shared between clusters.

| Location | Contents | Secrets? |
| --- | --- | --- |
| macOS Keychain (`AIREMonitor.AIREPassword`, account `leeds:<username>`) | The university password | Yes. This is the only persistent credential store. |
| `.runtime/preferences.json` | Username, route, jump host, Duo option, per-cluster enabled flag and hostname, sidebar selection | Password-free by design |
| `.runtime/clusters/<id>/latest_snapshot.json`, `snapshot_history.json`, `job_state.json` | Latest snapshot, trend history (up to 1440 points) and the job-state baseline for notifications, with usernames, job names, node names, filesystem paths, quota numbers and Lustre project ids | No passwords, but private cluster details |
| `.runtime/clusters/<id>/collector.json` | The exact collector argument list (username, hostnames, socket paths, storage spec) for the widget fallback | Password-free by design |
| `.runtime/clusters/<id>/login_debug.log` | Helper event log plus the stdout/stderr transcript of each sign-in, including hostnames, usernames and timings | No passwords |
| `.runtime/clusters/<id>/master_ssh.log`, `master_ssh.pid`, `keepalive.log`, `keepalive.pid`, `keepalive_starter.log` | ssh master output, pids, keepalive heartbeats | No passwords |
| `.runtime/clusters/<id>/askpass.fifo` | Exists only while that cluster's target master is authenticating; never a regular file | Carries the password in transit only |
| `.runtime/clusters/<id>/askpass.log` | Only written with `HPC_DEBUG=1`, see below | Redacted |
| `.runtime/swift-build.log`, `.runtime/swift-widget-build.log`, `.runtime/*.app` | Build output and the assembled app bundles | No |
| `~/.ssh/ctl/<id>-<hash>.sock`, `~/.ssh/ctl/jump-<hash>.sock` | OpenSSH ControlMaster sockets, see below | Access to the live authenticated session while it exists |

A JSON file that no longer decodes is renamed to `<name>.bad` next to the original instead of being overwritten.

Permissions: logs and pid files written by the helpers are created **0600** (the shell helpers run with `umask 077`, and `login_debug.log` is set to 0600 explicitly). The target starter forces `~/.ssh/ctl` and the cluster's runtime directory to **0700** on every login, and the app creates both with mode 0700 when they do not exist yet. The app writes the JSON files with default permissions (typically 0644), and nothing explicitly restricts `.runtime/` itself or `.runtime/clusters/`: `scripts/run_macos_app.sh` creates `.runtime/` with a plain `mkdir -p`. On a Mac shared with other users, run `chmod -R go-rwx .runtime` once. The entire `.runtime/` directory is gitignored.

Files from single-cluster releases are migrated on first launch. `.runtime/latest_snapshot.json`, `snapshot_history.json` and `job_state.json` are moved into `.runtime/clusters/aire/`, and `.runtime/connection_profile.json` seeds `preferences.json`. Older top-level files are not deleted automatically: `connection_profile.json`, `aire_master_ssh.log`, `aire_askpass.log`, keepalive logs and the like. Remove them once you no longer need them.

### ControlMaster sockets

All sockets live in the short, home-anchored `~/.ssh/ctl/` directory (0700), whatever the project path. Unix socket paths are capped at 104 bytes on macOS, and hashed names also keep usernames out of the file names. The hash is not a secret, though: anyone who knows the username and host can recompute it.

- **Cluster master**: `~/.ssh/ctl/<id>-<hash>.sock`, where `<hash>` is the first 12 hex characters of the SHA-256 of `<user>@<host>:direct` or `<user>@<host>:via-<jump-host>`. There is one socket per cluster and route. The key format is unchanged from the single-cluster releases, so a live AIRE master survives an upgrade.
- **Jump master**: `~/.ssh/ctl/jump-<hash>.sock`, hashed from `<user>@<jump-host>`, and **shared by every cluster**. When the expect helper is run by hand without `HPC_JUMP_CONTROL_PATH`, it falls back to `~/.ssh/ctl/jump-cli-<username>.sock`.

Masters persist for 24 h (`ControlPersist=24h`). While a master is alive, any process running as your macOS user can open new sessions through it without a password. To end one early, run `ssh -S <socket> -O exit <host>`. Closing the jump master also drops every cluster's tunnel through it.

### Debug logging (`HPC_DEBUG=1`)

Askpass prompt logging is **off by default**. When `HPC_DEBUG=1` is set in the target starter's environment, the askpass helper appends the prompt kind and text to `.runtime/clusters/<id>/askpass.log`. Every digit run is replaced by `X`, so Duo enrolled-device hints and phone numbers never reach disk. The app passes its own environment to the helpers, so to enable logging for app sign-ins, start the app executable from a shell with `HPC_DEBUG=1` set. The pre-rename `AIRE_DEBUG` is no longer read. `HPC_SSH_VERBOSE=1` adds `-vv` output to `master_ssh.log`. The password itself is never logged under any setting.

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

The tests and the collector's self-test deliberately use placeholders that this pattern also flags: the username `abcd1234` (and `alice`, `someone`, `u`), the project id `123456`, and the socket hashes the Swift tests derive from `abcd1234`. Hits on those placeholders are expected; investigate anything else.

Concretely, check that the diff contains:

- no real usernames (yours or teammates')
- no personal hostnames beyond the public `aire.leeds.ac.uk`, `calder.leeds.ac.uk` and `rash.leeds.ac.uk` names
- no control-socket paths or `.runtime/` file contents
- no pasted terminal output with home, scratch or flash paths, project ids or quota usage

## Reporting a Vulnerability

Please report suspected vulnerabilities privately through **GitHub's private security advisories** ("Report a vulnerability" under the repository's Security tab) rather than in a public issue. Include the affected script or component and reproduction steps if possible.

If you discover an accidental sensitive-data exposure (a committed credential, username, or private log), remove the affected public data immediately, rewrite history if needed, and rotate any exposed credential.
