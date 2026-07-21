#!/usr/bin/env zsh
# Detach a long-running command (an ssh master or the keepalive) from the
# caller. Prints the pid of the detached starter on the first invocation; the
# pid of the actual child command is written to AIRE_BACKGROUND_SSH_PID_FILE
# by the daemonized re-exec.
set -euo pipefail
umask 077

if [[ $# -lt 2 ]]; then
  print -u2 "Usage: aire_start_background_ssh.zsh <log-path> <command> [args...]"
  exit 2
fi

log_path="$1"
shift

pid_file="${AIRE_BACKGROUND_SSH_PID_FILE:-}"
starter_log="${AIRE_BACKGROUND_STARTER_LOG:-$log_path.starter}"

mkdir -p -- "$(dirname -- "$log_path")"
mkdir -p -- "$(dirname -- "$starter_log")"

if [[ "${AIRE_STARTER_DAEMONIZED:-0}" != "1" ]]; then
  nohup env AIRE_STARTER_DAEMONIZED=1 "$0" "$log_path" "$@" >| "$starter_log" 2>&1 < /dev/null &
  # This is the detached starter's pid, not the child command's pid; the
  # child pid lands in AIRE_BACKGROUND_SSH_PID_FILE once the re-exec runs.
  print -- "$!"
  exit 0
fi

trap '' HUP
"$@" >| "$log_path" 2>&1 < /dev/null &
pid=$!
if [[ -n "$pid_file" ]]; then
  mkdir -p -- "$(dirname -- "$pid_file")"
  print -- "$pid" >| "$pid_file"
fi
print -- "$pid"
wait_status=0
wait "$pid" || wait_status=$?
# Remove the pid file once the child has exited so a later login does not
# kill a recycled pid — but only if it still holds the pid we waited on (a
# newer starter may have already overwritten it).
if [[ -n "$pid_file" && -s "$pid_file" && "$(<"$pid_file")" == "$pid" ]]; then
  rm -f -- "$pid_file"
fi
exit $wait_status
