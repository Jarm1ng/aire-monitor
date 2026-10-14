#!/usr/bin/env zsh
# Start one cluster's background ControlMaster (AIRE, Calder, ...) on either
# route: direct (VPN) or tunnelled through the shared rash jump master.
#
# A healthy existing master for this cluster is REUSED (no Duo push) unless
# HPC_FORCE_RELOGIN=1 asks for a replacement. A replacement tears the old
# master down before authenticating, so callers should force only when the
# user explicitly asked to replace a session: a failed forced login leaves
# the cluster disconnected. Without forcing, an existing master is never
# torn down: one that answers on its socket but not end to end is left
# running and reported (exit 5), because only the user can tell a dead link
# from a slow login node that still carries their terminals. The script
# never touches the jump master or any other cluster's master, log or pid
# file: every file it writes lives in this cluster's HPC_RUNTIME_DIR, and
# every pid it signals is verified against this cluster's control socket
# (see hpc_ssh_common.zsh).
#
# Environment:
#   HPC_USERNAME           remote username (required)
#   HPC_HOSTNAME           cluster login host, e.g. calder.leeds.ac.uk (required)
#   HPC_CONTROL_PATH       this cluster's ControlMaster socket (required)
#   HPC_TARGET_LABEL       human name used in messages, e.g. "Calder"
#                          (default: HPC_HOSTNAME)
#   HPC_USE_JUMP_HOST      "1" to tunnel through the jump master (default 1)
#   HPC_JUMP_HOSTNAME      jump host (default rash.leeds.ac.uk)
#   HPC_JUMP_CONTROL_PATH  shared jump master socket (required with jump host)
#   HPC_FORCE_RELOGIN      "1" replaces this cluster's master even if it still
#                          works (default: reuse a healthy one, and leave one
#                          that does not answer end to end running; exit 5)
#   HPC_REUSE_ONLY         "1" adopts a healthy existing master and otherwise
#                          exits 4 without touching anything: no password
#                          needed, no teardown, no Duo. Also retires what
#                          older releases left next to that master (a 5 s
#                          keepalive, a permanent remote `sleep` session), so
#                          the app can run it once for a session it re-adopts
#                          at startup without signing in.
#   HPC_DUO_OPTION         Duo menu answer (default 1 = push)
#   HPC_RUNTIME_DIR        per-cluster logs/pids (default $HPC_PROJECT_ROOT/.runtime;
#                          callers running several clusters must pass one
#                          directory per cluster — the app always does)
#   HPC_PROJECT_ROOT       repository root (default: parent of this script's dir)
#   HPC_TIMEOUT            seconds the authentication (connect, password and
#                          Duo approval) may take before it is abandoned
#                          (default 150)
#   HPC_VERIFY_TIMEOUT     seconds to wait for the new master to verify (default 90)
#   HPC_SSH_VERBOSE        "1" adds -vv to the master's ssh log
#   HPC_DEBUG              "1" enables the redacted askpass prompt log
#
# The password is read from the first line of stdin when stdin is not a
# terminal; HPC_PASSWORD is accepted as a legacy fallback. Every password
# variable (including the pre-rename AIRE_* ones) is scrubbed from the
# environment immediately. The secret then reaches ssh's askpass helper only
# through a private FIFO (see start_password_writer below) — never argv, and
# never the environment, because `ssh -f` daemonizes into the long-lived
# master with its environment intact. Reusing a healthy master needs no
# password at all.
#
# Lifetime: the master runs no remote command (-N), so ControlPersist=24h is
# a real IDLE limit — it closes 24 h after its last client (the collector,
# a terminal, a transfer) went away. hpc_stop_master.zsh closes it at once.
#
# Progress is reported on stdout as machine-readable lines:
#   HPC-STATUS: <human-readable milestone>
# A "waiting for Duo approval" line is printed only once the server has
# actually asked for Duo, never while ssh is still connecting.
#
# Exit codes:
#   0    connected (a new master, or a healthy existing one reused)
#   2    configuration error (missing variable, helper or password)
#   3    HPC_USE_JUMP_HOST=1 but the shared jump master is not running
#   4    HPC_REUSE_ONLY=1 and there is no healthy master to reuse
#   5    without HPC_FORCE_RELOGIN=1: a master answers on this cluster's
#        socket, but the read-only check command did not come back through
#        it within 15 s. It was left running (nothing on it closed, no
#        password sent, no Duo); HPC_FORCE_RELOGIN=1 replaces it
#   13   the remote host rejected the password (wrong password)
#   14   the remote host demanded a password change (expired password)
#   15   the password was accepted but Duo approval was not completed (push
#        declined, timed out, or the connection dropped while waiting); no
#        second push is ever requested
#   124  timed out (HPC_TIMEOUT) before the server asked for Duo
#   other  ssh's own exit status, with the master log on stderr
set -euo pipefail
umask 077

ROOT_DIR="${HPC_PROJECT_ROOT:-${0:A:h:h}}"
RUNTIME_DIR="${HPC_RUNTIME_DIR:-$ROOT_DIR/.runtime}"
REMOTE_USERNAME="${HPC_USERNAME:?HPC_USERNAME is required}"
TARGET_HOSTNAME="${HPC_HOSTNAME:?HPC_HOSTNAME is required}"
TARGET_LABEL="${HPC_TARGET_LABEL:-$TARGET_HOSTNAME}"
USE_JUMP_HOST="${HPC_USE_JUMP_HOST:-1}"
JUMP_HOSTNAME="${HPC_JUMP_HOSTNAME:-rash.leeds.ac.uk}"
CONTROL_PATH="${HPC_CONTROL_PATH:?HPC_CONTROL_PATH is required}"
JUMP_CONTROL_PATH="${HPC_JUMP_CONTROL_PATH:-}"
DUO_OPTION="${HPC_DUO_OPTION:-1}"
FORCE_RELOGIN="${HPC_FORCE_RELOGIN:-0}"
REUSE_ONLY="${HPC_REUSE_ONLY:-0}"
AUTH_TIMEOUT="${HPC_TIMEOUT:-150}"
VERIFY_TIMEOUT="${HPC_VERIFY_TIMEOUT:-90}"
if [[ "$AUTH_TIMEOUT" != <-> ]] || (( AUTH_TIMEOUT < 1 )); then
  AUTH_TIMEOUT=150
fi
if [[ "$VERIFY_TIMEOUT" != <-> ]]; then
  VERIFY_TIMEOUT=90
fi

# Password: stdin first line (preferred), legacy env var as fallback.
PASSWORD=""
if [[ ! -t 0 ]]; then
  IFS= read -rs -t 5 PASSWORD || PASSWORD=""
fi
if [[ -z "$PASSWORD" ]]; then
  PASSWORD="${HPC_PASSWORD:-}"
fi
# Scrub the inherited environment so no child process sees the secret
# implicitly. The pre-rename AIRE_* names are scrubbed too, defensively, in
# case an older caller still exports them.
unset HPC_PASSWORD HPC_ASKPASS_PASSWORD AIRE_PASSWORD AIRE_ASKPASS_PASSWORD

if [[ "$RUNTIME_DIR" != /* ]]; then
  RUNTIME_DIR="$ROOT_DIR/$RUNTIME_DIR"
fi
if [[ "$CONTROL_PATH" != /* ]]; then
  CONTROL_PATH="$ROOT_DIR/$CONTROL_PATH"
fi
if [[ -n "$JUMP_CONTROL_PATH" && "$JUMP_CONTROL_PATH" != /* ]]; then
  JUMP_CONTROL_PATH="$ROOT_DIR/$JUMP_CONTROL_PATH"
fi

ASKPASS="$ROOT_DIR/scripts/hpc_ssh_askpass.sh"
COMMON="$ROOT_DIR/scripts/hpc_ssh_common.zsh"
if [[ ! -r "$COMMON" ]]; then
  print -u2 "Shared login helpers are missing: $COMMON"
  exit 2
fi
source "$COMMON"
if [[ ! -x "$ASKPASS" ]]; then
  print -u2 "Askpass helper is missing or not executable: $ASKPASS"
  exit 2
fi

control_dir="$(dirname -- "$CONTROL_PATH")"
mkdir -p -m 700 -- "$control_dir" "$RUNTIME_DIR"
chmod 700 "$control_dir" "$RUNTIME_DIR" 2>/dev/null || true

if [[ "$USE_JUMP_HOST" == "1" ]]; then
  if [[ -z "$JUMP_CONTROL_PATH" ]]; then
    print -u2 "HPC_JUMP_CONTROL_PATH is required when HPC_USE_JUMP_HOST=1"
    exit 2
  fi
  if [[ "$JUMP_CONTROL_PATH" == "$CONTROL_PATH" ]]; then
    print -u2 "HPC_CONTROL_PATH must differ from the shared jump master's HPC_JUMP_CONTROL_PATH"
    exit 2
  fi
fi
hpc_set_proxy_args "$USE_JUMP_HOST" "$JUMP_CONTROL_PATH" "$REMOTE_USERNAME" "$JUMP_HOSTNAME"
hpc_set_verify_base "$CONTROL_PATH" "$REMOTE_USERNAME"
verify_base=("${hpc_verify_base[@]}")
target_command="$hpc_target_command"

# Per-cluster runtime files. Names are cluster-neutral because the directory
# itself is per cluster (.runtime/clusters/<id>/ when launched by the app).
# The pid file is additionally per CONTROL PATH (route + username), so a
# login on one route never erases the record of the other route's master.
log_path="$RUNTIME_DIR/master_ssh.log"
pid_path="$(hpc_master_pid_file "$RUNTIME_DIR" "$CONTROL_PATH")"
legacy_pid_path="$RUNTIME_DIR/master_ssh.pid"
legacy_keepalive_pid_path="$RUNTIME_DIR/keepalive.pid"
askpass_fifo="$RUNTIME_DIR/askpass.fifo"
askpass_events="$RUNTIME_DIR/askpass.events"

capture_master_pid() {
  local out
  out="$("${verify_base[@]}" -O check "$TARGET_HOSTNAME" 2>&1 || true)"
  if [[ "$out" =~ 'pid=([0-9]+)' ]]; then
    print -- "${match[1]}" >| "$pid_path"
  fi
}

# Upgrade cleanup, on every path through this script: older releases ran a
# keepalive next to each master (a remote `true` every 5 s, for ever, which
# also stopped the master from ever going idle).
hpc_stop_legacy_keepalives "$CONTROL_PATH" "$legacy_keepalive_pid_path"

# ---------------------------------------------------------------------------
# Reuse a healthy master unless a replacement was explicitly requested.
# Healthy = the control socket answers (`-O check`, instant and local) AND a
# read-only command runs through it within 15 s.
#
# A master that answers on its socket but fails the second half is NOT torn
# down by a plain sign-in. It may be wedged (link dead, its terminals gone
# with it), but it may just as well be slow — an overloaded login node, a
# stalled home filesystem holding up the new session's shell — while it
# still carries the user's shells, editors and `srun --pty` allocations,
# and those two look the same from here. So the plain sign-in exits 5 and
# leaves it alone; the app then points to its confirmed Reconnect
# (HPC_FORCE_RELOGIN=1), which says how many terminals close. A really dead
# link also closes itself within about five minutes (ServerAlive 30 s x 10),
# after which a plain sign-in finds no master and logs in normally.
# ---------------------------------------------------------------------------
if [[ "$FORCE_RELOGIN" != "1" || "$REUSE_ONLY" == "1" ]]; then
  if "${verify_base[@]}" -O check "$TARGET_HOSTNAME" >/dev/null 2>&1; then
    reuse_output=""
    if reuse_output="$(perl -e 'alarm shift; exec @ARGV' 15 \
          "${verify_base[@]}" "$TARGET_HOSTNAME" "$target_command" 2>/dev/null)" \
        && [[ "$reuse_output" == *"auth_ok|"* ]]; then
      # A master from an older release still carries a permanent remote
      # `sleep` session; end it so ControlPersist can finally expire.
      hpc_end_legacy_session_clients "$CONTROL_PATH"
      capture_master_pid
      print "HPC-STATUS: reusing the existing $TARGET_LABEL session"
      print "HPC-STATUS: connected to $TARGET_LABEL"
      print -- "$reuse_output"
      exit 0
    fi
    if [[ "$REUSE_ONLY" != "1" ]]; then
      print -u2 "The existing $TARGET_LABEL session answers on its control socket, but a check command through it did not come back within 15 s. It was left running, so nothing on it was closed and no password was sent: its login node may be slow, or its connection may have died. Reconnect replaces it (its terminals close); a dead connection also closes by itself within about five minutes, and signing in then works normally."
      exit 5
    fi
  fi
fi

if [[ "$REUSE_ONLY" == "1" ]]; then
  print -u2 "No healthy $TARGET_LABEL session to reuse; sign in to $TARGET_LABEL."
  exit 4
fi

if [[ -z "$PASSWORD" ]]; then
  print -u2 "$TARGET_LABEL password is required (stdin first line, or HPC_PASSWORD)"
  exit 2
fi

if [[ "$USE_JUMP_HOST" == "1" ]]; then
  # The jump master is shared by every cluster and owned by
  # hpc_ssh_login.expect; this script only rides on it. Check it before
  # touching anything: there is no point tearing down this cluster's old
  # master for a login that cannot succeed.
  if ! ssh -n -o BatchMode=yes -o ControlPath="$JUMP_CONTROL_PATH" \
      -O check -o User="$REMOTE_USERNAME" "$JUMP_HOSTNAME" >/dev/null 2>&1; then
    print -u2 "The shared jump-host session ($JUMP_HOSTNAME) is not running, so $TARGET_LABEL cannot be reached through it. Authenticate the jump host first (hpc_ssh_login.expect with HPC_SKIP_TARGET=1), then retry."
    exit 3
  fi
fi

# Hand the password to the askpass helper without putting it in any argv or
# environment: a writer subshell offers it ONCE on a 0600 FIFO inside this
# cluster's 0700 runtime directory, and the askpass helper reads that line for
# the (single) password prompt. The writer opens the FIFO non-blocking (so it never waits
# on a reader that will not come), never creates or follows anything at that
# path (sysopen without "create", with "nofollow"), and exits as soon as the
# FIFO is removed or this script dies — even by SIGKILL — so the secret
# cannot outlive the login. cleanup_secret_handoff stops it explicitly the
# moment ssh returns.
#
# Why poll instead of a blocking open: a blocking open-for-write parks the
# writer inside open(2) for the whole Duo wait, where it cannot notice that
# this script was killed. The app signals the starter's whole process group,
# but anything that kills only this pid (a test harness timeout, `kill -9`
# by hand) would then leave the writer orphaned under launchd, still holding
# the password and still serving it to any later reader of the FIFO.
writer_pid=""
start_password_writer() {
  zmodload zsh/system zsh/zselect
  zmodload -F zsh/stat b:zstat
  rm -f -- "$askpass_fifo"
  mkfifo -m 600 "$askpass_fifo"
  local fifo_inode=""
  zstat -A fifo_inode -L +inode -- "$askpass_fifo" 2>/dev/null || fifo_inode=""
  (
    trap - EXIT INT TERM HUP
    trap '' PIPE
    local fd current_inode
    # Every ~0.1 s: confirm the FIFO is still ours and this script is still
    # our parent (sysparams[ppid] is read live; once the starter dies the
    # writer is reparented, so this also survives pid reuse of $$), then try
    # a non-blocking open-for-write. It fails (ENXIO) until the askpass
    # helper's blocking open-for-read is waiting, and then succeeds at once,
    # so the secret is handed over exactly when ssh asks for it, once per
    # password prompt. The pause after each attempt also lets a reader finish
    # its line and close before the next offer.
    while [[ -p "$askpass_fifo" && ! -L "$askpass_fifo" ]] && (( sysparams[ppid] == $$ )); do
      if sysopen -w -o nonblock,nofollow,cloexec -u fd "$askpass_fifo" 2>/dev/null; then
        print -r -u $fd -- "$PASSWORD" 2>/dev/null || true
        exec {fd}>&-
        # One-shot: AIRE and Calder offer only keyboard-interactive, so a
        # login asks for the password exactly once (verified 2026-10-12).
        # A second password prompt can only mean the first was rejected;
        # with the FIFO gone the askpass helper refuses it, so a wrong
        # password is never submitted twice in one login.
        rm -f -- "$askpass_fifo"
        break
      fi
      zselect -t 10 2>/dev/null || true
    done
    # Orphaned (the starter died without running cleanup_secret_handoff):
    # remove the FIFO too, but only if the path still names the FIFO this
    # run created — a newer login for this cluster may already have
    # replaced it with its own.
    if (( sysparams[ppid] != $$ )) && [[ -n "$fifo_inode" ]]; then
      current_inode=""
      zstat -A current_inode -L +inode -- "$askpass_fifo" 2>/dev/null || current_inode=""
      if [[ "$current_inode" == "$fifo_inode" ]]; then
        rm -f -- "$askpass_fifo"
      fi
    fi
  ) &
  writer_pid=$!
}

cleanup_secret_handoff() {
  if [[ -n "$writer_pid" ]]; then
    kill "$writer_pid" 2>/dev/null || true
    wait "$writer_pid" 2>/dev/null || true
    writer_pid=""
  fi
  rm -f -- "$askpass_fifo"
}

# The authenticating ssh runs in the background (so this script can report
# what the server is actually asking for, and enforce HPC_TIMEOUT); it must
# never outlive the script that is waiting on it.
ssh_pid=""
stop_auth_ssh() {
  local pid="$ssh_pid" tries=0
  [[ -n "$pid" ]] || return 0
  ssh_pid=""
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && (( tries < 20 )); do
    zselect -t 10 2>/dev/null || true
    tries=$(( tries + 1 ))
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
trap cleanup_secret_handoff EXIT
trap 'stop_auth_ssh; cleanup_secret_handoff; exit 130' INT TERM HUP

# Tear down any previous master for THIS cluster's socket: ask it to exit
# cleanly, then signal its verified processes (per-path pid file, the shared
# pid file of older releases, and a verified pattern search) and wait for
# them to go, so the dying master cannot unlink the replacement's socket.
# The jump master and other clusters' masters have different control paths
# and are never matched.
"${verify_base[@]}" -O exit "$TARGET_HOSTNAME" >/dev/null 2>&1 || true
rm -f -- "$CONTROL_PATH"
hpc_stop_master_processes "$CONTROL_PATH" "$pid_path" || true
if [[ -s "$legacy_pid_path" ]]; then
  hpc_stop_master_processes "$CONTROL_PATH" "$legacy_pid_path" || true
fi
hpc_retire_shared_pid_file "$legacy_pid_path" "$CONTROL_PATH" master
rm -f -- "$pid_path"

verbose_args=()
if [[ "${HPC_SSH_VERBOSE:-0}" == "1" ]]; then
  verbose_args=(-vv)
fi

# -N: no remote command. The master exists only to carry other clients'
# sessions, and with no session of its own ControlPersist counts real idle
# time (an always-attached remote command would keep it alive for ever).
# Compression applies to the target master only: on the rash route its
# stream is what travels inside the jump tunnel, so compressing the jump
# master as well would gain nothing. Snapshot JSON and file listings shrink
# several-fold.
master_args=(
  ssh
  "${verbose_args[@]}"
  -f
  -N
  "${hpc_master_login_options[@]}"
  -o Compression=yes
  -o ControlPath="$CONTROL_PATH"
  -o User="$REMOTE_USERNAME"
  "${hpc_proxy_args[@]}"
  "$TARGET_HOSTNAME"
)

# Askpass logging is opt-in and redacted; enable with HPC_DEBUG=1.
if [[ "${HPC_DEBUG:-0}" == "1" ]]; then
  export HPC_DEBUG
  export HPC_ASKPASS_LOG="$RUNTIME_DIR/askpass.log"
fi

# Events the askpass helper recorded for this login (fixed words, one per
# line; see hpc_ssh_askpass.sh). Re-read on every poll.
typeset -a events
load_events() {
  events=()
  if [[ -s "$askpass_events" ]]; then
    events=(${(f)"$(<"$askpass_events")"})
  fi
}
has_event() {
  (( ${events[(Ie)$1]} ))
}

print "HPC-STATUS: starting $TARGET_LABEL authentication"
# Only the FIFO's path, the events path and the control path (none of them
# secret) and the Duo menu answer reach ssh's environment. stdin is
# /dev/null so the daemonized master never holds the caller's pipe.
start_password_writer
rm -f -- "$askpass_events"
HPC_ASKPASS_EVENTS="$askpass_events" \
HPC_ASKPASS_FIFO="$askpass_fifo" \
HPC_ASKPASS_DUO_OPTION="$DUO_OPTION" \
HPC_ASKPASS_CONTROL_PATH="$CONTROL_PATH" \
SSH_ASKPASS="$ASKPASS" \
SSH_ASKPASS_REQUIRE=force \
DISPLAY="${DISPLAY:-:0}" \
"${master_args[@]}" < /dev/null >| "$log_path" 2>&1 &
ssh_pid=$!

# `ssh -f` returns once authentication (password + Duo) has completed or
# failed. Meanwhile, report what the server has actually asked for: the Duo
# line appears only after askpass answered a real Duo prompt, so a slow
# connect (VPN off, a busy login node) never tells the user to approve a
# push that is not coming.
auth_deadline=$(( SECONDS + AUTH_TIMEOUT ))
said_password=0
said_duo=0
timed_out=0
while kill -0 "$ssh_pid" 2>/dev/null; do
  load_events
  if (( ! said_password )) && has_event password; then
    print "HPC-STATUS: password sent ($TARGET_LABEL)"
    said_password=1
  fi
  if (( ! said_duo )) && has_event duo; then
    print "HPC-STATUS: waiting for Duo approval on your phone ($TARGET_LABEL)"
    said_duo=1
  fi
  if (( SECONDS >= auth_deadline )); then
    timed_out=1
    stop_auth_ssh
    break
  fi
  zselect -t 20 2>/dev/null || true
done
rc=0
if [[ -n "$ssh_pid" ]]; then
  wait "$ssh_pid" 2>/dev/null || rc=$?
  ssh_pid=""
fi
if (( timed_out )); then
  rc=124
fi
chmod 600 "$log_path" 2>/dev/null || true

# Drop the secret before anything else (diagnostics, verification) happens,
# including the failure exits below.
cleanup_secret_handoff
PASSWORD=""
unset PASSWORD
load_events
# The poll above can miss an exchange that finished between two looks. The
# app relies on this line: on a successful sign-in it is how the app knows
# this leg really had the password checked (a reused master never sends it).
if (( ! said_password )) && has_event password; then
  print "HPC-STATUS: password sent ($TARGET_LABEL)"
  said_password=1
fi

password_expired() {
  has_event password-change
}

# The server asked for Duo, so it had accepted the password, and the login
# still did not complete — unless pam_duo reported success (its
# "Success. Logging you in..." lands in the master log) and something
# unrelated failed afterwards.
duo_not_approved() {
  has_event duo || return 1
  if [[ -s "$log_path" ]] && grep -qi 'success\. logging you in' "$log_path"; then
    return 1
  fi
  return 0
}

# True when this cluster refused the password itself: the password was
# actually sent (askpass recorded it), no Duo prompt followed, and either a
# second password prompt arrived or the log shows "Permission denied". A
# "Permission denied" attributed to the jump host comes from a `-W` proxy
# that fell back to a direct connection (the jump master died mid-login),
# and a failure before the password was ever sent (connection refused,
# Calder's "Not allowed at this time") can never be a wrong password.
password_rejected() {
  local line lower
  has_event password || return 1
  if has_event password-retry; then
    return 0
  fi
  [[ -s "$log_path" ]] || return 1
  while IFS= read -r line; do
    lower="${line:l}"
    [[ "$lower" == *"permission denied"* ]] || continue
    if [[ "$USE_JUMP_HOST" == "1" && "$lower" == *"@${JUMP_HOSTNAME:l}:"* ]]; then
      continue
    fi
    return 0
  done < "$log_path"
  return 1
}

if (( rc != 0 )); then
  print -u2 "$TARGET_LABEL background master failed to start."
  if password_expired; then
    print -u2 "$TARGET_LABEL requires a password change (the password has expired)."
    exit 14
  fi
  if duo_not_approved; then
    if has_event duo-denied; then
      print -u2 "$TARGET_LABEL: the Duo push was declined. The password was accepted; no further push was sent."
    elif has_event duo-timeout || (( timed_out )); then
      print -u2 "$TARGET_LABEL: the Duo push was not approved in time. The password was accepted; no further push was sent."
    else
      print -u2 "$TARGET_LABEL did not receive Duo approval (declined, timed out, or the connection dropped while waiting). The password was accepted."
    fi
    exit 15
  fi
  if (( timed_out )); then
    print -u2 "Timed out while waiting for $TARGET_LABEL SSH, password, or Duo prompt (after ${AUTH_TIMEOUT}s)."
    if [[ -s "$log_path" ]]; then
      print -u2 "$TARGET_LABEL SSH log:"
      tail -n 80 "$log_path" >&2 || true
    fi
    exit 124
  fi
  if password_rejected; then
    print -u2 "$TARGET_LABEL rejected the password."
    exit 13
  fi
  if [[ -s "$log_path" ]]; then
    print -u2 "$TARGET_LABEL SSH log:"
    tail -n 80 "$log_path" >&2 || true
  fi
  exit $rc
fi

# `ssh -f` returned 0, so authentication (password + Duo) completed; this
# loop just waits (bounded by wall clock) for the mux socket to become
# usable. Probe the control socket first (instant) and only then run the
# full verification command.
deadline=$(( SECONDS + VERIFY_TIMEOUT ))
last_heartbeat=$(( SECONDS - 5 ))
while (( SECONDS < deadline )); do
  if "${verify_base[@]}" -O check "$TARGET_HOSTNAME" >/dev/null 2>&1; then
    if output="$(perl -e 'alarm shift; exec @ARGV' 25 \
          "${verify_base[@]}" "$TARGET_HOSTNAME" "$target_command" 2>&1)"; then
      capture_master_pid
      print "HPC-STATUS: connected to $TARGET_LABEL"
      print -- "$output"
      exit 0
    fi
  fi
  if (( SECONDS - last_heartbeat >= 5 )); then
    print "HPC-STATUS: verifying $TARGET_LABEL connection"
    last_heartbeat=$SECONDS
  fi
  sleep 1
done

# Authentication succeeded, so whatever went wrong here is not the password
# and not Duo: never report 13 or 15 from this point.
print -u2 "$TARGET_LABEL background master did not become usable."
if [[ -s "$log_path" ]]; then
  print -u2 "$TARGET_LABEL SSH log:"
  tail -n 80 "$log_path" >&2 || true
fi
exit 1
