# Login-script tests

A mock-`ssh` harness that exercises the real `scripts/hpc_*` login helpers
for the multi-cluster (AIRE + Calder) behaviour, without touching the network,
`~/.ssh`, or any live session.

## Files

- `fake_ssh.py` — a deterministic stand-in for the OpenSSH `ssh` client. It is
  copied to a throwaway `bin/ssh` and placed first on `$PATH`, so the genuine
  scripts call it by name exactly as they would call OpenSSH. It emulates
  `-O check`/`-O exit`, interactive ControlMaster creation (password + Duo over
  the tty or via `$SSH_ASKPASS`), tunnelled target masters bound to the very
  jump master *process* they rode in on (they die with it, and a replacement
  jump master at the same socket path does not revive them — as with real
  OpenSSH), `-W` proxy channels, and BatchMode mux clients. Every control
  socket, state file and log it creates lives under the harness work dir
  (`$HPC_FAKE_HOME`) — never `~/.ssh`.
  Test knobs (files under the work dir):
  - `w_mode/<host>` — how the far end answers when rash opens `host:22`:
    `refused` (real mux wording *"Stdio forwarding request failed: Session
    open refused by peer"*, exit 255), `penalized` (sshd `drop_connection()`:
    *"Not allowed at this time"* then close, exit 0), `silent` (no banner), or
    one-shot `kill-jump` (the jump master dies mid-probe; the mux client exits
    0 with no output).
  - `duo_delay/<host>` — seconds the simulated Duo push takes to approve.
- `test_login_flow.py` — drives the real scripts the same way
  `MonitorService.login` does (expect jump leg with `HPC_SKIP_TARGET=1`, then
  `hpc_start_target_master.zsh`; password on stdin; `HPC_FORCE_RELOGIN=1`) and
  checks scenarios S1–S9.

## Running

```sh
python3 scripts/tests/test_login_flow.py
```

Takes about 15 s. Prints a PASS/FAIL table and exits non-zero on any
failure. It creates a private temp work dir. Every script leg runs in its own
process group, which is killed if the leg times out (30 s). On exit (success
or failure) the harness kills only processes whose argv or launch environment
(`ps -E`) mentions that work dir. Every process it starts inherits
`HPC_FAKE_HOME=<work dir>`, which also catches forked helpers whose argv
names only the real script. The user's real `ssh`/keepalive sessions
(which reference `~/.ssh` and the real project path) are never touched.

## Scenarios

| ID | What it proves |
|----|----------------|
| S1 | Direct login "AIRE": exit 0, HPC-STATUS names AIRE, master + keepalive up, runtime files only under AIRE's dir. |
| S2 | Direct login "Calder" while AIRE is alive: both live; AIRE's pids/keepalive untouched. |
| S3 | Rash route: AIRE via jump (2 Duo), then Calder via jump — jump master **reused** (same pid, 1 new Duo), AIRE target still alive. |
| S4 | Forced re-login of AIRE via jump while Calder is alive: jump reused, AIRE master replaced, Calder untouched. |
| S5 | (a) Wedged jump master (`-O check` passes but `-W` hangs): re-authenticated, login succeeds, and the tunnel that rode on it dies with it. (b) Jump master dies *during* the probe (exit 0, no output): the follow-up `-O check` catches it and it is re-authenticated. |
| S6 | Wrong password: exit 13 from the leg that rejected it: the target starter on the direct route, and the expect jump leg on the rash route. The shared jump master is untouched. |
| S7 | The password never appears in any logged argv, runtime file, or a daemonized master's environment, and no FIFO is left in any runtime dir. Runs last, so it covers every login in the suite. |
| S8 | Calder refuses rash's channel (`refused`), sshd drops the connection (`penalized`), or Calder stays silent (`silent`). In each case the shared jump master is kept: same pid, 0 new rash Duo, AIRE's tunnel alive. The Calder target leg then fails with a non-13 exit and requests no Duo. |
| S9 | Killing only the target starter's pid during the Duo wait leaves no password-writer process and no askpass FIFO behind. |
