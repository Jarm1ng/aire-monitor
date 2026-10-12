#!/usr/bin/env zsh
# Detach a long-running command (a cluster's keepalive, or an ssh master)
# from the caller. Prints the pid of the detached starter on the first
# invocation; the pid of the actual child command is written to
# HPC_BACKGROUND_SSH_PID_FILE by the daemonized re-exec.
#
# Every cluster passes its own log/pid paths (under its HPC_RUNTIME_DIR), so
# two clusters running this helper at the same time never share a file.
#
# Environment:
#   HPC_BACKGROUND_SSH_PID_FILE  where the child's pid is recorded (optional)
#   HPC_BACKGROUND_STARTER_LOG   the detached starter's own output
#                                (default: <log-path>.starter)
#   HPC_STARTER_DAEMONIZED       internal: set to 1 on the detached re-exec
set -euo pipefail
umask 077

if [[ $# -lt 2 ]]; then
  print -u2 "Usage: hpc_start_background_ssh.zsh <log-path> <command> [args...]"
  exit 2
fi

log_path="$1"
shift

pid_file="${HPC_BACKGROUND_SSH_PID_FILE:-}"
starter_log="${HPC_BACKGROUND_STARTER_LOG:-$log_path.starter}"

mkdir -p -- "$(dirname -- "$log_path")"
mkdir -p -- "$(dirname -- "$starter_log")"

if [[ "${HPC_STARTER_DAEMONIZED:-0}" != "1" ]]; then
  nohup env HPC_STARTER_DAEMONIZED=1 "$0" "$log_path" "$@" >| "$starter_log" 2>&1 < /dev/null &
  # This is the detached starter's pid, not the child command's pid; the
  # child pid lands in HPC_BACKGROUND_SSH_PID_FILE once the re-exec runs.
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
