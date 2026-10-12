#!/usr/bin/env zsh
# Periodically exercise one cluster's ControlMaster so it stays warm.
#
# One keepalive runs per cluster; its first positional argument is that
# cluster's control path, which is also how hpc_start_target_master.zsh
# recognises (and only ever kills) the keepalive belonging to the cluster it
# is replacing.
#
# Exits 0 (cleanly) as soon as the master is gone or unresponsive: nothing
# supervises or restarts this script, so a dead master must never turn into a
# reconnect loop that hammers the cluster with connection attempts.
#
# Environment:
#   HPC_KEEPALIVE_INTERVAL      seconds between probes (default 5)
#   HPC_KEEPALIVE_MAX_FAILURES  consecutive failures before giving up (default 3)
#   HPC_KEEPALIVE_PID_FILE      optional file to record this script's pid
set -euo pipefail
umask 077

if [[ $# -lt 6 ]]; then
  print -u2 "Usage: hpc_target_keepalive.zsh <control-path> <username> <hostname> <use-jump-host> <jump-hostname> <jump-control-path>"
  exit 2
fi

CONTROL_PATH="$1"
REMOTE_USERNAME="$2"
TARGET_HOSTNAME="$3"
USE_JUMP_HOST="$4"
JUMP_HOSTNAME="$5"
JUMP_CONTROL_PATH="$6"
INTERVAL="${HPC_KEEPALIVE_INTERVAL:-5}"
MAX_FAILURES="${HPC_KEEPALIVE_MAX_FAILURES:-3}"
PID_FILE="${HPC_KEEPALIVE_PID_FILE:-}"

if [[ -n "$PID_FILE" ]]; then
  mkdir -p -- "$(dirname -- "$PID_FILE")"
  print -- "$$" >| "$PID_FILE"
fi

proxy_args=()
if [[ "$USE_JUMP_HOST" == "1" ]]; then
  if [[ -z "$JUMP_CONTROL_PATH" ]]; then
    print -u2 "jump control path is required when use-jump-host is enabled"
    exit 2
  fi
  proxy_command="ssh -o BatchMode=yes -o ControlPath=${(q)JUMP_CONTROL_PATH} -o User=${(q)REMOTE_USERNAME} -W %h:%p ${(q)JUMP_HOSTNAME}"
  proxy_args=(-o "ProxyCommand=$proxy_command")
else
  proxy_args=(-o ProxyCommand=none -o ProxyJump=none)
fi

# Instant local probe of the control socket; no network traffic.
check_command=(
  ssh
  -n
  -o ControlPath="$CONTROL_PATH"
  -O check
  "$TARGET_HOSTNAME"
)

command=(
  ssh
  -n
  -o BatchMode=yes
  -o PubkeyAuthentication=no
  -o GSSAPIAuthentication=no
  -o PasswordAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o ConnectTimeout=10
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  -o TCPKeepAlive=yes
  -o ControlPath="$CONTROL_PATH"
  -o ControlMaster=auto
  -o User="$REMOTE_USERNAME"
  "${proxy_args[@]}"
  "$TARGET_HOSTNAME"
  true
)

failures=0
while true; do
  if ! "${check_command[@]}" >/dev/null 2>&1; then
    print -- "$(date -Iseconds 2>/dev/null || date) keepalive_stop master_gone"
    exit 0
  fi
  if "${command[@]}" >/dev/null 2>&1; then
    failures=0
    print -- "$(date -Iseconds 2>/dev/null || date) keepalive_ok"
  else
    failures=$((failures + 1))
    print -- "$(date -Iseconds 2>/dev/null || date) keepalive_failed count=$failures"
    if (( failures >= MAX_FAILURES )); then
      print -- "$(date -Iseconds 2>/dev/null || date) keepalive_stop master_unresponsive"
      exit 0
    fi
  fi
  sleep "$INTERVAL"
done
