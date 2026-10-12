#!/usr/bin/env zsh
# Start one cluster's background ControlMaster (AIRE, Calder, ...) on either
# route: direct (VPN) or tunnelled through the shared rash jump master.
#
# This script always REPLACES this cluster's target master (it is the
# "forced relogin" path); callers that want to reuse a healthy master check
# it first, as hpc_ssh_login.expect does. It never touches the jump master or
# any other cluster's master, keepalive, log or pid file: every file it
# writes lives in this cluster's HPC_RUNTIME_DIR.
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
#   HPC_DUO_OPTION         Duo menu answer (default 1 = push)
#   HPC_RUNTIME_DIR        per-cluster logs/pids (default $HPC_PROJECT_ROOT/.runtime;
#                          callers running several clusters must pass one
#                          directory per cluster — the app always does)
#   HPC_PROJECT_ROOT       repository root (default: parent of this script's dir)
#   HPC_VERIFY_TIMEOUT     seconds to wait for the master to verify (default 90)
#   HPC_SSH_VERBOSE        "1" adds -vv to the master's ssh log
#   HPC_DEBUG              "1" enables the redacted askpass prompt log
#
# The password is read from the first line of stdin when stdin is not a
# terminal; HPC_PASSWORD is accepted as a legacy fallback. Every password
# variable (including the pre-rename AIRE_* ones) is scrubbed from the
# environment immediately. The secret then reaches ssh's askpass helper only
# through a private FIFO (see start_password_writer below) — never argv, and
# never the environment, because `ssh -f` daemonizes into the long-lived
# master with its environment intact.
#
# Progress is reported on stdout as machine-readable lines:
#   HPC-STATUS: <human-readable milestone>
#
# Exit codes:
#   13  the remote host rejected the password (wrong password)
#   14  the remote host demanded a password change (expired password)
#   3   HPC_USE_JUMP_HOST=1 but the shared jump master is not running
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

if [[ -z "$PASSWORD" ]]; then
  print -u2 "$TARGET_LABEL password is required (stdin first line, or HPC_PASSWORD)"
  exit 2
fi

ASKPASS="$ROOT_DIR/scripts/hpc_ssh_askpass.sh"
KEEPALIVE="$ROOT_DIR/scripts/hpc_target_keepalive.zsh"
STARTER="$ROOT_DIR/scripts/hpc_start_background_ssh.zsh"
if [[ ! -x "$ASKPASS" ]]; then
  print -u2 "Askpass helper is missing or not executable: $ASKPASS"
  exit 2
fi
if [[ ! -x "$KEEPALIVE" ]]; then
  print -u2 "Target keepalive helper is missing or not executable: $KEEPALIVE"
  exit 2
fi
if [[ ! -x "$STARTER" ]]; then
  print -u2 "Background starter is missing or not executable: $STARTER"
  exit 2
fi

control_dir="$(dirname -- "$CONTROL_PATH")"
mkdir -p -m 700 -- "$control_dir" "$RUNTIME_DIR"
chmod 700 "$control_dir" "$RUNTIME_DIR" 2>/dev/null || true

proxy_args=()
if [[ "$USE_JUMP_HOST" == "1" ]]; then
  if [[ -z "$JUMP_CONTROL_PATH" ]]; then
    print -u2 "HPC_JUMP_CONTROL_PATH is required when HPC_USE_JUMP_HOST=1"
    exit 2
  fi
  proxy_command="ssh -o BatchMode=yes -o ControlPath=${(q)JUMP_CONTROL_PATH} -o User=${(q)REMOTE_USERNAME} -W %h:%p ${(q)JUMP_HOSTNAME}"
  proxy_args=(-o "ProxyCommand=$proxy_command")

  # The jump master is shared by every cluster and owned by
  # hpc_ssh_login.expect; this script only rides on it. Check it before
  # touching anything: with a dead jump socket the ProxyCommand's mux client
  # would silently fall back to a direct BatchMode connection to the jump
  # host, whose "Permission denied" must not be mistaken for this cluster
  # rejecting the password — and there is no point tearing down this
  # cluster's old master for a login that cannot succeed.
  if ! ssh -n -o BatchMode=yes -o ControlPath="$JUMP_CONTROL_PATH" \
      -O check -o User="$REMOTE_USERNAME" "$JUMP_HOSTNAME" >/dev/null 2>&1; then
    print -u2 "The shared jump-host session ($JUMP_HOSTNAME) is not running, so $TARGET_LABEL cannot be reached through it. Authenticate the jump host first (hpc_ssh_login.expect with HPC_SKIP_TARGET=1), then retry."
    exit 3
  fi
else
  proxy_args=(-o ProxyCommand=none -o ProxyJump=none)
fi

verify_base=(
  ssh
  -n
  -o BatchMode=yes
  -o PubkeyAuthentication=no
  -o GSSAPIAuthentication=no
  -o PasswordAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o ConnectTimeout=20
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=10
  -o TCPKeepAlive=yes
  -o ExitOnForwardFailure=yes
  -o ControlPath="$CONTROL_PATH"
  -o ControlMaster=auto
  -o User="$REMOTE_USERNAME"
  "${proxy_args[@]}"
)

target_command='printf '\''auth_ok|%s|%s|%s\n'\'' "$(hostname -f 2>/dev/null || hostname)" "$(whoami)" "$(date -Iseconds 2>/dev/null || date)"'

# Per-cluster runtime files. Names are cluster-neutral because the directory
# itself is per cluster (.runtime/clusters/<id>/ when launched by the app).
log_path="$RUNTIME_DIR/master_ssh.log"
pid_path="$RUNTIME_DIR/master_ssh.pid"
keepalive_log_path="$RUNTIME_DIR/keepalive.log"
keepalive_pid_path="$RUNTIME_DIR/keepalive.pid"
keepalive_starter_log_path="$RUNTIME_DIR/keepalive_starter.log"
askpass_fifo="$RUNTIME_DIR/askpass.fifo"
askpass_events="$RUNTIME_DIR/askpass.events"
legacy_keepalive_label="local.aire.target-keepalive"

# Kill a pid only after verifying it is one of OUR ssh processes for exactly
# this control socket. Two process shapes qualify:
#   - "ssh: <control-path> [mux]": the detached master. OpenSSH rewrites the
#     master's process title to this once it has backgrounded, so its
#     original argv (and any ControlPath= option) is no longer visible.
#   - "ssh ... ControlPath=<control-path> ... ControlMaster=yes ...": a master
#     still authenticating, or the session client that `ssh -f` with
#     ControlPersist leaves behind running the remote `sleep`.
# For the argv shape the *first* ControlPath option must match exactly:
# every master tunnelled through the shared jump host embeds the jump
# ControlPath inside its ProxyCommand string. Requiring ControlMaster=yes
# additionally keeps every cluster's `-W` proxy (an `ssh ... ControlPath=<jump>`
# mux client without ControlMaster=yes) out of reach.
kill_verified_pid() {
  local pid="$1" control_path="$2" cmdline first_cp
  [[ "$pid" == <-> ]] || return 1
  cmdline="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  # setproctitle pads the rewritten title with spaces; drop them.
  cmdline="${cmdline%"${cmdline##*[![:space:]]}"}"
  if [[ "$cmdline" == "ssh: $control_path [mux]" || "$cmdline" == "ssh: $control_path [mux] "* ]]; then
    kill "$pid" 2>/dev/null || true
    return 0
  fi
  [[ "$cmdline" == ssh\ * ]] || return 1
  first_cp="${cmdline#*ControlPath=}"
  [[ "$first_cp" != "$cmdline" ]] || return 1
  first_cp="${first_cp%% *}"
  [[ "$first_cp" == "$control_path" ]] || return 1
  [[ " $cmdline " == *" ControlMaster=yes "* ]] || return 1
  kill "$pid" 2>/dev/null || true
  return 0
}

kill_master_by_pid_file() {
  local pid_file="$1" control_path="$2"
  if [[ -s "$pid_file" ]]; then
    kill_verified_pid "$(<"$pid_file")" "$control_path" || true
  fi
  rm -f -- "$pid_file"
}

kill_master_by_pattern() {
  local control_path="$1" escaped pattern pid
  escaped="$(printf '%s' "$control_path" | sed -e 's/[][^$.*+?(){}|\\]/\\&/g')"
  # Candidates only; kill_verified_pid makes the final decision.
  for pattern in "^ssh .*ControlPath=${escaped}" "^ssh: ${escaped} \\[mux\\]"; do
    for pid in ${(f)"$(pgrep -f "$pattern" 2>/dev/null || true)"}; do
      kill_verified_pid "$pid" "$control_path" || true
    done
  done
}

# The keepalive pid file can be stale (the keepalive exits itself when the
# master dies, leaving the file behind), so the recorded pid may have been
# recycled by an unrelated process — or, with several clusters running, by
# ANOTHER cluster's keepalive. Only kill after confirming the pid is numeric
# and its argv is the keepalive script immediately followed by THIS cluster's
# control path (the keepalive's first positional argument).
kill_verified_keepalive_pid() {
  local pid="$1" control_path="$2" cmdline
  [[ "$pid" == <-> ]] || return 1
  cmdline="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$cmdline" == *"hpc_target_keepalive.zsh $control_path "* ]] || return 1
  kill "$pid" 2>/dev/null || true
  return 0
}

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
trap cleanup_secret_handoff EXIT
trap 'cleanup_secret_handoff; exit 130' INT TERM HUP

# Tear down any previous master for THIS cluster's socket: ask it to exit
# cleanly, then fall back to pid-file and verified-pattern kills. The jump
# master and other clusters' masters have different control paths and are
# never matched.
"${verify_base[@]}" -O exit "$TARGET_HOSTNAME" >/dev/null 2>&1 || true
rm -f -- "$CONTROL_PATH"
kill_master_by_pid_file "$pid_path" "$CONTROL_PATH"
kill_master_by_pattern "$CONTROL_PATH"

verbose_args=()
if [[ "${HPC_SSH_VERBOSE:-0}" == "1" ]]; then
  verbose_args=(-vv)
fi

master_args=(
  ssh
  "${verbose_args[@]}"
  -f
  -o StrictHostKeyChecking=accept-new
  -o PubkeyAuthentication=no
  -o GSSAPIAuthentication=no
  -o PreferredAuthentications=password,keyboard-interactive
  -o KbdInteractiveAuthentication=yes
  -o PasswordAuthentication=yes
  -o NumberOfPasswordPrompts=1
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=10
  -o TCPKeepAlive=yes
  -o ExitOnForwardFailure=yes
  -o ConnectTimeout=20
  -o ControlMaster=yes
  -o ControlPersist=24h
  -o ControlPath="$CONTROL_PATH"
  -o User="$REMOTE_USERNAME"
  "${proxy_args[@]}"
  "$TARGET_HOSTNAME"
  sleep
  2147483647
)

# Remove any keepalive left behind by older releases that used launchd (the
# launchctl-submit approach crash-looped when the master died, hammering the
# cluster; the keepalive is now run via the background starter only).
launchctl remove "$legacy_keepalive_label" >/dev/null 2>&1 || true
if [[ -s "$keepalive_pid_path" ]]; then
  kill_verified_keepalive_pid "$(<"$keepalive_pid_path")" "$CONTROL_PATH" || true
  rm -f -- "$keepalive_pid_path"
fi

# Askpass logging is opt-in and redacted; enable with HPC_DEBUG=1.
if [[ "${HPC_DEBUG:-0}" == "1" ]]; then
  export HPC_DEBUG
  export HPC_ASKPASS_LOG="$RUNTIME_DIR/askpass.log"
fi

print "HPC-STATUS: starting $TARGET_LABEL authentication"
# The askpass helper answers the password and Duo-option prompts instantly,
# so the foreground `ssh -f` below blocks for the entire Duo push approval:
# tell the user now, before the launch, while they still have to act.
print "HPC-STATUS: waiting for Duo approval on your phone ($TARGET_LABEL)"
# Only the FIFO's path (not a secret) and the Duo menu answer reach ssh's
# environment. Capture the exit status with `|| rc=$?` so an authentication
# failure does not trip `set -e` before the wrong-password mapping below.
# stdin is /dev/null so the daemonized master never holds the caller's pipe.
start_password_writer
rm -f -- "$askpass_events"
rc=0
HPC_ASKPASS_EVENTS="$askpass_events" \
HPC_ASKPASS_FIFO="$askpass_fifo" \
HPC_ASKPASS_DUO_OPTION="$DUO_OPTION" \
SSH_ASKPASS="$ASKPASS" \
SSH_ASKPASS_REQUIRE=force \
DISPLAY="${DISPLAY:-:0}" \
"${master_args[@]}" < /dev/null >| "$log_path" 2>&1 || rc=$?
chmod 600 "$log_path" 2>/dev/null || true

# Drop the secret before anything else (diagnostics, keepalive, verification)
# happens, including the failure exits below.
cleanup_secret_handoff
PASSWORD=""
unset PASSWORD

# True when the master's log shows this cluster refusing the password. A
# "Permission denied" attributed to the jump host comes from a `-W` proxy
# that fell back to a direct connection (the jump master died mid-login), not
# from a wrong password, and must not be reported as exit 13.
password_rejected() {
  local line lower
  [[ -s "$log_path" ]] || return 1
  while IFS= read -r line; do
    lower="${line:l}"
    [[ "$lower" == *"permission denied"* ]] || continue
    [[ "$USE_JUMP_HOST" == "1" && "$lower" == *"@${JUMP_HOSTNAME:l}:"* ]] && continue
    return 0
  done < "$log_path"
  return 1
}

password_expired() {
  [[ -s "$askpass_events" ]] && grep -qx 'password-change' "$askpass_events"
}

if (( rc != 0 )); then
  print -u2 "$TARGET_LABEL background master failed to start."
  if password_expired; then
    print -u2 "$TARGET_LABEL requires a password change (the password has expired)."
    rm -f -- "$askpass_events"
    exit 14
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

capture_master_pid() {
  local out
  out="$("${verify_base[@]}" -O check "$TARGET_HOSTNAME" 2>&1 || true)"
  if [[ "$out" =~ 'pid=([0-9]+)' ]]; then
    print -- "${match[1]}" >| "$pid_path"
  fi
}

start_keepalive() {
  HPC_BACKGROUND_SSH_PID_FILE="$keepalive_pid_path" \
  HPC_BACKGROUND_STARTER_LOG="$keepalive_starter_log_path" \
  "$STARTER" "$keepalive_log_path" "$KEEPALIVE" \
    "$CONTROL_PATH" \
    "$REMOTE_USERNAME" \
    "$TARGET_HOSTNAME" \
    "$USE_JUMP_HOST" \
    "$JUMP_HOSTNAME" \
    "$JUMP_CONTROL_PATH" \
    >/dev/null || true
}

# `ssh -f` returns only after authentication (password + Duo) has completed,
# so this loop just waits (bounded by wall clock) for the mux socket to become
# usable. Probe the control socket first (instant) and only then run the full
# verification command.
deadline=$(( SECONDS + ${HPC_VERIFY_TIMEOUT:-90} ))
last_heartbeat=$(( SECONDS - 5 ))
while (( SECONDS < deadline )); do
  if "${verify_base[@]}" -O check "$TARGET_HOSTNAME" >/dev/null 2>&1; then
    if output="$("${verify_base[@]}" "$TARGET_HOSTNAME" "$target_command" 2>&1)"; then
      capture_master_pid
      start_keepalive
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

print -u2 "$TARGET_LABEL background master did not become usable."
if [[ -s "$log_path" ]]; then
  if password_rejected; then
    print -u2 "$TARGET_LABEL rejected the password."
    exit 13
  fi
  print -u2 "$TARGET_LABEL SSH log:"
  tail -n 80 "$log_path" >&2 || true
fi
exit 1
