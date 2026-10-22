# Login-script tests

A mock-`ssh` harness that exercises the real `scripts/hpc_*` login helpers
for the multi-cluster (AIRE + Calder) behaviour, without touching the network,
`~/.ssh`, launchd, or any live session.

## Files

- `fake_ssh.py` — a deterministic stand-in for the OpenSSH `ssh` client. It is
  copied to a throwaway `bin/ssh` and placed first on `$PATH` (next to a no-op
  `launchctl`), so the genuine scripts call it by name exactly as they would
  call OpenSSH. It emulates `-O check`/`-O exit`, interactive ControlMaster
  creation with the real keyboard-interactive prompts (`(user@host) Password: `
  and the multi-line Duo menu ending `Passcode or option (1-2): `) over the
  tty or via `$SSH_ASKPASS`, tunnelled target masters bound to the very jump
  master *process* they rode in on (they die with it, as with real OpenSSH)
  and kept company by a real `-W` proxy child, `-W` proxy channels, and
  BatchMode mux clients. Processes look in `ps` the way OpenSSH's do. A
  master started with `-N` (every master the scripts start) keeps its argv
  as its title once detached — `ssh ... ControlMaster=yes ...
  ControlPath=<socket> ...` — because with `ControlPersist` and no session
  or stdio forward to hand over, OpenSSH daemonizes without
  `control_persist_detach()`, the only place that retitles a master
  `ssh: <socket> [mux]`. That is the same shape as a master still
  authenticating; only a master started *with* a remote command (as older
  releases did) gets the `[mux]` title, and the fake does that too. Every
  control socket, state file and log it creates lives under the harness work
  dir (`$HPC_FAKE_HOME`) — never `~/.ssh`.
  Test knobs (one word or number in `<work dir>/<knob>/<host>`):
  - `w_mode` — how the far end answers when rash opens `host:22`:
    `refused` (real mux wording *"Stdio forwarding request failed: Session
    open refused by peer"*, exit 255), `penalized` (sshd `drop_connection()`:
    *"Not allowed at this time"* then close, exit 0), `silent` (no banner), or
    one-shot `kill-jump` (the jump master dies mid-probe; the mux client exits
    0 with no output).
  - `duo_delay` — seconds the simulated Duo push takes to approve.
  - `duo_mode` — how the push ends, as pam_duo does it: `deny` (*"Login
    request denied."* and the menu again), `timeout` (after `duo_delay`,
    *"Login timed out."* and the menu again), `grace` (the server closes the
    connection mid-wait, sshd's LoginGraceTime), `hang` (never answered).
    An empty answer to the menu counts as another push (pam_duo may pick its
    default factor), so a script that merely refuses a repeated prompt shows
    up as an extra push.
  - `duo_prompts` — pam_duo's `prompts` option (default 3).
  - `pw_change` — an expired password: `after` / `before` Duo (pam_sss:
    *"Password expired. Change your password now."* + `Current Password: `)
    or `rhel7` (pam_unix: `(current) UNIX password: `). Any answer is
    recorded (as a kind, never the text) in `logs/pw_change/<host>.log`.
  - `password_delay` — seconds before the server asks for the password (a
    slow or silent server).
  - `duo_warning` — any value: a PAM warning that the password expires soon
    comes on its own line in front of every Duo menu.
  - `kbdint_only` — a wrong password gets no second prompt, just
    "Permission denied" (what AIRE, Calder and rash really do).
- `test_snapshot.py` — the collector's unit tests: the parsers, the
  generated remote script run under `sh`, `dash`, `bash` and `zsh` against
  stub Slurm/df/quota/lfs commands, and whole collections through a stub
  `ssh`. Local only, about 20 s. `python3 scripts/tests/test_snapshot.py`
  runs it (so do `hpc_snapshot.py --self-test` and
  `scripts/test_all.sh collector`); `--write-fixture` regenerates the
  contract fixtures in `Tests/Fixtures/*.json` that the Swift
  `CollectorContractTests` decode.
- `test_login_flow.py` — drives the real scripts the same way
  `MonitorService` does (expect jump leg with `HPC_SKIP_TARGET=1`, then
  `hpc_start_target_master.zsh`; `hpc_stop_master.zsh` to sign out; password
  on stdin; one control socket per cluster *and route*) and checks scenarios
  S1–S17. `python3 scripts/tests/test_login_flow.py S10 S11` runs a subset.

## Running

```sh
python3 scripts/tests/test_login_flow.py    # the login harness alone
python3 scripts/tests/test_snapshot.py      # the collector tests alone
scripts/test_all.sh                         # every suite: swift, collector, login, desktop
```

The login harness takes about a minute. It prints a PASS/FAIL table and exits
non-zero on any failure. It creates a private temp work dir. Every script leg
runs in its own process group, which is killed if the leg times out (30 s).
Every fake `ssh` is a Python process, so on a heavily loaded machine (parallel
builds) `HPC_LOGIN_TEST_SLOWDOWN=<factor>` stretches the harness's own default
waits — the per-leg limit, `HPC_TIMEOUT` and the jump-probe timeout — by that
factor; limits a scenario sets explicitly (S13's) are left alone. On
exit (success or failure) the harness kills only processes whose argv or
launch environment (`ps -E`) mentions that work dir. Every process it starts
inherits `HPC_FAKE_HOME=<work dir>`, which also catches forked helpers whose
argv names only the real script. The user's real `ssh` sessions (which
reference `~/.ssh` and the real project path) are never touched.

## Exit codes the app relies on

`MonitorService` classifies a failed sign-in by the helper's exit code, so
these are a contract (each script's header lists all of its codes):

| Code | Leg | Meaning | What the app says |
|------|-----|---------|-------------------|
| 13 | either | the password was rejected | wrong password; a saved one is flagged and never sent again |
| 14 | either | the password has expired | change it first |
| 15 | either | the password was accepted, Duo was not approved | never a password problem |
| 124 | either | timed out before Duo was reached | login timed out |
| 4 | starter, `HPC_REUSE_ONLY=1` | no healthy master to adopt | nothing (adoption is quiet housekeeping) |
| 5 | starter, plain sign-in | a master answers on the cluster's socket, but the read-only check command did not come back through it within 15 s. It was **left running**: nothing on it closed, no password was sent, no Duo push. It may be slow (an overloaded login node, a stalled home filesystem) rather than dead, and still carry terminals. | "did not answer in time, so it was left running": choose **Reconnect…** (confirmed, says how many terminals close; `HPC_FORCE_RELOGIN=1`) to replace it, or wait — a dead link closes itself within about five minutes (ServerAlive 30 s x 10) and Connect then signs in normally |

The expect helper passes the starter's codes through when it delegates the
target leg (`HPC_SKIP_TARGET` unset). On a successful sign-in, each leg that
actually sent the password prints `HPC-STATUS: password sent (<label>)`; a
leg that reused its master prints `reusing …` instead. The app saves a typed
password to the Keychain (and lifts a "rejected" flag) only when some leg
sent it, never after a sign-in that merely reused open sessions.

## Scenarios

| ID | What it proves |
|----|----------------|
| S1 | Direct login "AIRE": exit 0, HPC-STATUS names AIRE; the master runs no remote command (`-N`, so `ControlPersist` is a real idle limit); its pid file is per control path; no keepalive process or file of any kind. |
| S2 | Direct login "Calder" while AIRE is alive: both live; AIRE's pid and pid file untouched. |
| S3 | Rash route: AIRE via jump (2 Duo), then Calder via jump — jump master **reused** (same pid, 1 new Duo), AIRE target still alive, its `-W` proxy child alive. AIRE's direct-route master and pid record survive the route switch. |
| S4 | Forced re-login of AIRE via jump while Calder is alive: jump reused, AIRE master replaced (old process gone), Calder untouched. |
| S5 | (a) Wedged jump master (`-O check` passes but `-W` hangs): re-authenticated, login succeeds, and the tunnel that rode on it dies with it. (b) Jump master dies *during* the probe (exit 0, no output): the follow-up `-O check` catches it and it is re-authenticated. |
| S6 | Wrong password: exit 13 from the leg that rejected it (target starter on the direct route, expect jump leg on the rash route), no Duo push; the shared jump master is untouched. A stale exported `HPC_PASSWORD` never overrides the password on stdin, on either leg, and never reaches a master's environment. |
| S7 | No password (including the stale and special-character ones) appears in any logged argv, runtime file, or a daemonized master's environment, and no FIFO is left in any runtime dir. Runs last, so it covers every login in the suite. |
| S8 | Calder refuses rash's channel (`refused`), sshd drops the connection (`penalized`), or Calder stays silent (`silent`). In each case the shared jump master is kept: same pid, 0 new rash Duo, AIRE's tunnel alive. The Calder target leg then fails with a non-13/15 exit, requests no Duo, and never prints a "password sent" or "waiting for Duo" line. |
| S9 | Killing only the target starter's pid during the Duo wait leaves no password-writer process and no askpass FIFO behind. |
| S10 | A declined push (pam_duo `prompts` 3 and 1), a timed-out push, and a connection closed during the Duo wait: exit **15** (never 13) on both legs, a message saying the password was accepted, and exactly **one** push. |
| S11 | Expired password — pam_sss after Duo, pam_sss before Duo, RHEL 7 `(current) UNIX password:` — exit 14 on both legs; the password-change prompt is never answered. |
| S12 | A non-forced login reuses a healthy master (same pid, no Duo, `reusing` status), even while Calder's login node refuses new connections; leaves a master that answers its socket but runs no command untouched (exit **5**, same pid, no password sent, no Duo, the message points to Reconnect), which only a forced login replaces (one Duo); ends an old release's permanent `sleep 2147483647` session client while keeping the master; with `HPC_REUSE_ONLY=1` adopts a session without a password (retiring an old keepalive and session client) or exits 4 when there is none; and reports `starting` → `password sent` → `waiting for Duo approval` → `connected` in that order. |
| S13 | `HPC_TIMEOUT`: a server that never asks for the password gives 124 on both legs (quickly, no FIFO left); a push that is never answered gives 15; no ssh is left running. |
| S14 | A password with spaces, quotes, a backslash, `$HOME`, backticks, a tab and UTF-8 logs in on both legs. |
| S15 | `hpc_stop_master.zsh` stops exactly one route's master, its socket and pid file, and an old release's keepalive for that path; keeps the other route's master, pid record and keepalive, Calder, and the jump master; reports "nothing running" on a second call; refuses the jump socket; stops an authenticating ssh (Disconnect during sign-in); and with `HPC_STOP_JUMP_IF_UNUSED=1` stops the shared jump master only once no tunnel rides on it — with every master titled as real `-N` masters are (their own argv, never `[mux]`), so the jump master's own argv, which names the jump socket, never counts as its own rider (the helper leaves out exactly the pid `-O check` reports). A login also ends its own path's old keepalive. |
| S16 | Every ssh the scripts ran: no master with a remote command, every ProxyCommand hardened (BatchMode, no key/GSSAPI/password/kbd-int, ConnectTimeout, `ControlMaster=no`), nothing with `ControlMaster=auto`; the collector still sets `ControlMaster=no` and `BatchMode=yes`. |
| S17 | A password about to expire puts "Your password will expire in 5 day(s)." in front of Duo's menu (knob `duo_warning`). The askpass helper decides on the prompt's last line, so that is answered as Duo — one push, "waiting for Duo approval", success — never as a second password prompt (which would read as a rejected password); the expect leg's anchored patterns agree. |
