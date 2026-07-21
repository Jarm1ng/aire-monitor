#!/usr/bin/env zsh
# Start the background AIRE ControlMaster (explicit/jump-host mode).
#
# The password is read from the first line of stdin when stdin is not a
# terminal; the legacy AIRE_PASSWORD / AIRE_ASKPASS_PASSWORD environment
# variables are accepted as a fallback. The secret is exported only into the
# environment of the single ssh master invocation (never argv) and is unset
# before the keepalive is started.
#
# Progress is reported on stdout as machine-readable lines:
#   AIRE-STATUS: <human-readable milestone>
#
# Exit codes:
#   13  the remote host rejected the password (wrong password)
set -euo pipefail
umask 077

ROOT_DIR="${AIRE_PROJECT_ROOT:-$(pwd)}"
REMOTE_USERNAME="${AIRE_USERNAME:?AIRE_USERNAME is required}"
AIRE_HOSTNAME="${AIRE_HOSTNAME:-aire.leeds.ac.uk}"
USE_JUMP_HOST="${AIRE_USE_JUMP_HOST:-1}"
JUMP_HOSTNAME="${AIRE_JUMP_HOSTNAME:-rash.leeds.ac.uk}"
CONTROL_PATH="${AIRE_CONTROL_PATH:?AIRE_CONTROL_PATH is required}"
JUMP_CONTROL_PATH="${AIRE_JUMP_CONTROL_PATH:-}"
DUO_OPTION="${AIRE_DUO_OPTION:-1}"

# Password: stdin first line (preferred), legacy env vars as fallback.
PASSWORD=""
if [[ ! -t 0 ]]; then
  IFS= read -rs -t 5 PASSWORD || PASSWORD=""
fi
if [[ -z "$PASSWORD" ]]; then
  PASSWORD="${AIRE_PASSWORD:-${AIRE_ASKPASS_PASSWORD:-}}"
fi
# Scrub the inherited environment so no child process sees the secret
# implicitly; it is re-exported only around the single ssh invocation below.
unset AIRE_PASSWORD AIRE_ASKPASS_PASSWORD

if [[ "$CONTROL_PATH" != /* ]]; then
  CONTROL_PATH="$ROOT_DIR/$CONTROL_PATH"
fi
if [[ -n "$JUMP_CONTROL_PATH" && "$JUMP_CONTROL_PATH" != /* ]]; then
  JUMP_CONTROL_PATH="$ROOT_DIR/$JUMP_CONTROL_PATH"
fi

if [[ -z "$PASSWORD" ]]; then
  print -u2 "AIRE password is required (stdin first line, or AIRE_PASSWORD)"
  exit 2
fi

ASKPASS="$ROOT_DIR/scripts/aire_ssh_askpass.sh"
KEEPALIVE="$ROOT_DIR/scripts/aire_target_keepalive.zsh"
STARTER="$ROOT_DIR/scripts/aire_start_background_ssh.zsh"
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
mkdir -p -m 700 -- "$control_dir" "$ROOT_DIR/.runtime"
chmod 700 "$control_dir" "$ROOT_DIR/.runtime" 2>/dev/null || true

proxy_args=()
if [[ "$USE_JUMP_HOST" == "1" ]]; then
  if [[ -z "$JUMP_CONTROL_PATH" ]]; then
    print -u2 "AIRE_JUMP_CONTROL_PATH is required when AIRE_USE_JUMP_HOST=1"
    exit 2
  fi
  proxy_command="ssh -o BatchMode=yes -o ControlPath=${(q)JUMP_CONTROL_PATH} -o User=${(q)REMOTE_USERNAME} -W %h:%p ${(q)JUMP_HOSTNAME}"
  proxy_args=(-o "ProxyCommand=$proxy_command")
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

log_path="$ROOT_DIR/.runtime/aire_master_ssh.log"
pid_path="$ROOT_DIR/.runtime/aire_master_ssh.pid"
keepalive_log_path="$ROOT_DIR/.runtime/aire_master_keepalive.log"
keepalive_pid_path="$ROOT_DIR/.runtime/aire_master_keepalive.pid"
keepalive_starter_log_path="$ROOT_DIR/.runtime/aire_master_keepalive_starter.log"
keepalive_label="local.aire.target-keepalive"

# Kill a pid only after verifying its argv is an ssh process whose *first*
# ControlPath option is exactly the socket we manage. The first-occurrence
# check matters: an AIRE master embeds the jump ControlPath inside its
# ProxyCommand string, so a naive substring match could kill the wrong master.
kill_verified_pid() {
  local pid="$1" control_path="$2" cmdline first_cp
  [[ "$pid" == <-> ]] || return 1
  cmdline="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$cmdline" == ssh\ * || "$cmdline" == ssh ]] || return 1
  first_cp="${cmdline#*ControlPath=}"
  [[ "$first_cp" != "$cmdline" ]] || return 1
  first_cp="${first_cp%% *}"
  [[ "$first_cp" == "$control_path" ]] || return 1
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
  pattern="^ssh .*ControlPath=${escaped}"
  for pid in ${(f)"$(pgrep -f "$pattern" 2>/dev/null || true)"}; do
    kill_verified_pid "$pid" "$control_path" || true
  done
}

# The keepalive pid file can be stale (the keepalive exits itself when the
# master dies, leaving the file behind), so the recorded pid may have been
# recycled by an unrelated process. Mirror kill_verified_pid: only kill after
# confirming the pid is numeric and its argv references the keepalive script.
kill_verified_keepalive_pid() {
  local pid="$1" cmdline
  [[ "$pid" == <-> ]] || return 1
  cmdline="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$cmdline" == *aire_target_keepalive.zsh* ]] || return 1
  kill "$pid" 2>/dev/null || true
  return 0
}

# Tear down any previous master for this socket: ask it to exit cleanly, then
# fall back to pid-file and verified-pattern kills.
"${verify_base[@]}" -O exit "$AIRE_HOSTNAME" >/dev/null 2>&1 || true
rm -f -- "$CONTROL_PATH"
kill_master_by_pid_file "$pid_path" "$CONTROL_PATH"
kill_master_by_pattern "$CONTROL_PATH"

verbose_args=()
if [[ "${AIRE_SSH_VERBOSE:-0}" == "1" ]]; then
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
  "$AIRE_HOSTNAME"
  sleep
  2147483647
)

# Remove any keepalive left behind by older releases that used launchd (the
# launchctl-submit approach crash-looped when the master died, hammering the
# cluster; the keepalive is now run via the background starter only).
launchctl remove "$keepalive_label" >/dev/null 2>&1 || true
if [[ -s "$keepalive_pid_path" ]]; then
  kill_verified_keepalive_pid "$(<"$keepalive_pid_path")" || true
  rm -f -- "$keepalive_pid_path"
fi

# Askpass logging is opt-in and redacted; enable with AIRE_DEBUG=1.
if [[ "${AIRE_DEBUG:-0}" == "1" ]]; then
  export AIRE_DEBUG
  export AIRE_ASKPASS_LOG="$ROOT_DIR/.runtime/aire_askpass.log"
fi

print "AIRE-STATUS: starting AIRE authentication"
# The askpass helper answers the password and Duo-option prompts instantly,
# so the foreground `ssh -f` below blocks for the entire Duo push approval:
# tell the user now, before the launch, while they still have to act.
print "AIRE-STATUS: waiting for Duo approval on your phone (AIRE)"
# The secret is passed via prefix assignment: it enters the child's
# environment directly and never appears in any argv. Capture the exit status
# with `|| rc=$?` so an authentication failure does not trip `set -e` before
# the wrong-password mapping below.
rc=0
AIRE_ASKPASS_PASSWORD="$PASSWORD" \
AIRE_ASKPASS_DUO_OPTION="$DUO_OPTION" \
SSH_ASKPASS="$ASKPASS" \
SSH_ASKPASS_REQUIRE=force \
DISPLAY="${DISPLAY:-:0}" \
"${master_args[@]}" >| "$log_path" 2>&1 || rc=$?
chmod 600 "$log_path" 2>/dev/null || true

# Drop the secret before anything else (diagnostics, keepalive, verification)
# happens, including the failure exits below.
PASSWORD=""
unset PASSWORD

if (( rc != 0 )); then
  print -u2 "AIRE background master failed to start."
  if [[ -s "$log_path" ]] && grep -qi "permission denied" "$log_path"; then
    print -u2 "AIRE rejected the password."
    exit 13
  fi
  if [[ -s "$log_path" ]]; then
    print -u2 "AIRE SSH log:"
    tail -n 80 "$log_path" >&2 || true
  fi
  exit $rc
fi

capture_master_pid() {
  local out
  out="$("${verify_base[@]}" -O check "$AIRE_HOSTNAME" 2>&1 || true)"
  if [[ "$out" =~ 'pid=([0-9]+)' ]]; then
    print -- "${match[1]}" >| "$pid_path"
  fi
}

start_keepalive() {
  AIRE_BACKGROUND_SSH_PID_FILE="$keepalive_pid_path" \
  AIRE_BACKGROUND_STARTER_LOG="$keepalive_starter_log_path" \
  "$STARTER" "$keepalive_log_path" "$KEEPALIVE" \
    "$CONTROL_PATH" \
    "$REMOTE_USERNAME" \
    "$AIRE_HOSTNAME" \
    "$USE_JUMP_HOST" \
    "$JUMP_HOSTNAME" \
    "$JUMP_CONTROL_PATH" \
    >/dev/null || true
}

# `ssh -f` returns only after authentication (password + Duo) has completed,
# so this loop just waits (bounded by wall clock) for the mux socket to become
# usable. Probe the control socket first (instant) and only then run the full
# verification command.
deadline=$(( SECONDS + ${AIRE_VERIFY_TIMEOUT:-90} ))
last_heartbeat=$(( SECONDS - 5 ))
while (( SECONDS < deadline )); do
  if "${verify_base[@]}" -O check "$AIRE_HOSTNAME" >/dev/null 2>&1; then
    if output="$("${verify_base[@]}" "$AIRE_HOSTNAME" "$target_command" 2>&1)"; then
      capture_master_pid
      start_keepalive
      print "AIRE-STATUS: connected to AIRE"
      print -- "$output"
      exit 0
    fi
  fi
  if (( SECONDS - last_heartbeat >= 5 )); then
    print "AIRE-STATUS: verifying AIRE connection"
    last_heartbeat=$SECONDS
  fi
  sleep 1
done

print -u2 "AIRE background master did not become usable."
if [[ -s "$log_path" ]]; then
  if grep -qi "permission denied" "$log_path"; then
    print -u2 "AIRE rejected the password."
    exit 13
  fi
  print -u2 "AIRE SSH log:"
  tail -n 80 "$log_path" >&2 || true
fi
exit 1
