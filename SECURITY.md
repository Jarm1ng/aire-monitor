# Security Notes

AIRE Monitor's automated monitoring is strictly read-only; the only write-capable paths are user-driven features (the embedded Terminal, the confirmation-gated `Cancel job` action, and the Files tab, described below). This document describes exactly where credentials travel, what is stored where, and how to report a problem.

## Credential Pipeline

The password is handed to local helper processes through **stdin only**. It never appears on any command line (where other local users could read it via `ps`), and the app never places it in a child process environment.

### Alias mode (`Use local SSH alias`)

1. The app writes the password as the first line of stdin to `scripts/aire_ssh_login.expect`.
2. The expect helper reads it, immediately scrubs the legacy `AIRE_PASSWORD` / `AIRE_ASKPASS_PASSWORD` environment variables, and keeps the secret only in its own process memory.
3. It answers the interactive password prompt on the spawned ssh's pty and leaves an OpenSSH ControlMaster behind. Spawned ssh processes never inherit the secret in their environment.

### Explicit mode (username + optional jump host)

1. **Jump leg**: same as alias mode — the password goes via stdin to the expect helper, which authenticates the `rash` ControlMaster interactively and exits without touching AIRE (`AIRE_SKIP_TARGET=1`).
2. **AIRE leg**: the app writes the password (stdin first line, again) to `scripts/aire_start_target_master.zsh`, which reads it with `IFS= read -rs`. The script scrubs the inherited environment, then exports the secret **only around the single ssh master invocation** — as a prefix assignment feeding `SSH_ASKPASS` (`scripts/aire_ssh_askpass.sh`) — and unsets it before anything else (keepalive, verification) is started.

Legacy fallback: both helpers still accept `AIRE_PASSWORD` from the environment for compatibility with manual invocation, and both scrub it immediately after reading. The app itself never sets it.

### Askpass hardening

`scripts/aire_ssh_askpass.sh` answers exactly two prompt kinds: login password prompts and Duo passcode/option prompts. Anything else — password-change flows (`new password`, `retype`, ...), changed host keys, unknown prompts — is refused with a non-zero exit so ssh fails fast with a diagnosable error instead of feeding the stored password into the wrong flow.

### Anti-lockout: `NumberOfPasswordPrompts=1`

Every interactive and askpass ssh invocation (and the example `~/.ssh/config`) sets `NumberOfPasswordPrompts=1`. A mistyped password fails immediately instead of being resent repeatedly, which with the University IdP can otherwise trigger an account lockout. As a second guard, the expect helper exits with code **13** if a second password prompt ever appears, and the app maps exit 13 to a clear "password was rejected" message instead of retrying.

## Interactive Terminal, Job Cancellation, and Files

The embedded terminal executes only what the user explicitly types (or triggers by clicking a quick-command chip) — the app never runs a terminal command on its own initiative. Every terminal is a local `ssh -tt` child that multiplexes over the **already-authenticated** ControlMaster socket with `BatchMode=yes` and password/keyboard-interactive authentication disabled, so no credentials ever pass through a terminal session: if the master is dead, the session fails with a readable error instead of prompting, and the app has no code path that types a password into a terminal. The `Cancel job` action runs `scancel <jobid>` (job id shell-quoted) over the same authenticated channel and only after an explicit in-app confirmation dialog. Closing a terminal session terminates its ssh child process.

The Files tab follows the same model: every file operation (list, preview, upload, download, rename, delete) is user-initiated and runs over the same authenticated multiplexed channel — remote commands through the ControlMaster, transfers through `scp` in SFTP mode bound to the same socket — so no credentials are ever involved. Destructive actions are confirmation-gated and trash-first: the default delete is a recoverable `mv` into `~/.aire-trash/<timestamp>/` on the server, and the irreversible permanent delete requires two separate confirmations and independently refuses `/`, `~`, and the home directory itself. Remote file **names** are treated as untrusted data end-to-end: directory listings arrive through a remote-python JSON protocol rather than parsed `ls` output, and every name interpolated into a shell command is single-quote-escaped and preceded by a `--` separator, so hostile names (spaces, quotes, `$()`, leading dashes, invalid UTF-8) can never become commands or flags.

## Keychain Storage

With `Remember in Keychain` enabled, the password is stored in the user's macOS Keychain after a successful login:

- Item class: generic password, service **`AIREMonitor.AIREPassword`**
- Account: one item per connection — `alias:<alias>` in alias mode, `explicit:<user>@<host>:<route>` in explicit mode (route is `direct` or `via:<jump-host>`)
- Accessibility: **`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`** — the item never leaves this device (excluded from iCloud Keychain and unencrypted backups) and is only readable while the device is unlocked. The attribute is also applied on every update, so items created before this policy converge on the next save.
- Removal: the sidebar `Forget` button deletes the saved item (including the legacy `<user>@leeds` account from older releases, which is also deleted automatically once the credential is migrated to the new naming).

With `Remember in Keychain` disabled, the password exists only in app memory for the current login attempt.

## Data Inventory

| Location | Contents | Secrets? |
| --- | --- | --- |
| macOS Keychain (`AIREMonitor.AIREPassword`) | The login password, one item per connection | Yes — the only persistent credential store |
| `.runtime/latest_snapshot.json`, `.runtime/snapshot_history.json`, `.runtime/job_state.json` | Cluster snapshots: usernames, job names, node names, filesystem paths, quota numbers | No passwords, but private cluster details |
| `.runtime/connection_profile.json` | Connection route (mode, alias, username, hostnames) | Password-free by design |
| `.runtime/ssh-control/*.sock` | OpenSSH ControlMaster sockets (mode-700 directory) | Access to the live authenticated session while it exists |
| `.runtime/*.log` (`aire_master_ssh.log`, keepalive logs, `login_debug.log`, `swift-build.log`) | ssh/build output: hostnames, usernames, timings | No passwords |
| `.runtime/aire_askpass.log` | Opt-in askpass prompt log, see below | Redacted |

The entire `.runtime/` directory is created with mode 700 and is gitignored.

### Debug logging (`AIRE_DEBUG=1`)

Askpass prompt logging is **off by default**. When `AIRE_DEBUG=1` is set, the askpass helper appends the prompt kind and text to `.runtime/aire_askpass.log` — with every digit run replaced by `X`, so Duo enrolled-device hints and phone numbers never reach disk. The password itself is never logged under any setting.

## Do Not Commit

- passwords
- SSH private keys
- local `.ssh/config` files with personal aliases (`config/aire_ssh_config.example` is the shareable template; a personalized `config/aire_ssh_config` is gitignored)
- anything under `.runtime/`
- Slurm output or error logs that include private paths or research data

### Pre-commit checklist

Before pushing, scan the staged diff for identifying material (replace `<your-username>` with your actual cluster username):

```bash
git diff --cached | grep -inE '<your-username>|/users/[a-z0-9]+|/mnt/scratch/[a-z0-9]+|ssh-control|\.sock'
```

Concretely, check that the diff contains:

- no real usernames (yours or teammates')
- no personal hostnames beyond the public `rash.leeds.ac.uk` / `aire.leeds.ac.uk` names
- no control-socket paths or `.runtime/` file contents
- no pasted terminal output with home/scratch paths

## Reporting a Vulnerability

Please report suspected vulnerabilities privately through **GitHub's private security advisories** ("Report a vulnerability" under the repository's Security tab) rather than in a public issue. Include the affected script or component and reproduction steps if possible.

If you discover an accidental sensitive-data exposure (a committed credential, username, or private log), remove the affected public data immediately, rewrite history if needed, and rotate any exposed credential.
