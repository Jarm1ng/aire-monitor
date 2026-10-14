#!/usr/bin/env zsh
# Stop ONE cluster's background ControlMaster ("sign out" of that cluster):
# after this, nothing can open a session through it without a new password
# and Duo approval.
#
# What it does, for exactly the control path it is given:
#   1. asks the master to exit (`ssh -O exit`, local socket only — a control
#      command never dials the host);
#   2. signals every process VERIFIED to be this path's master (the
#      per-path pid file, the shared pid file of older releases, and a
#      pattern search; see hpc_is_master_process in hpc_ssh_common.zsh for
#      the rules), waits for them, and SIGKILLs any that linger;
#   3. stops any keepalive an older release left running for this path;
#   4. removes this path's pid file, and the shared pid files only when they
#      cannot belong to another route, plus a stale socket file.
# It never touches the shared jump master (unless asked, see below), another
# cluster's master, or another route's master of the same cluster: every
# check is against this exact control path, and a control path equal to the
# jump master's is refused outright.
#
# Environment:
#   HPC_CONTROL_PATH       the cluster's ControlMaster socket (required)
#   HPC_HOSTNAME           the cluster's login host (required)
#   HPC_USERNAME           remote username (required)
#   HPC_RUNTIME_DIR        the cluster's runtime dir holding its pid files
#                          (default $HPC_PROJECT_ROOT/.runtime)
#   HPC_TARGET_LABEL       human name used in messages (default HPC_HOSTNAME)
#   HPC_USE_JUMP_HOST      "1" when the cluster is on the rash route
#   HPC_JUMP_CONTROL_PATH  the shared jump master's socket; used as a guard
#                          (refuse to stop it as if it were a cluster) and by
#                          HPC_STOP_JUMP_IF_UNUSED
#   HPC_JUMP_HOSTNAME      jump host (default rash.leeds.ac.uk)
#   HPC_STOP_JUMP_IF_UNUSED
#                          "1" ALSO stops the shared jump master afterwards,
#                          but only if no other tunnel still rides on it (no
#                          process other than the jump master itself names
#                          its control path; "itself" is the pid `-O check`
#                          reports, see the jump section below). Meant for
#                          "sign out of everything" after every cluster has
#                          been stopped; a jump master that is still
#                          carrying another cluster is always kept.
#   HPC_PROJECT_ROOT       repository root (default: parent of this script's dir)
#
# Output: HPC-STATUS lines on stdout ("stopped the <label> session", or
# "no <label> session was running").
#
# Exit codes:
#   0  stopped, or nothing was running
#   1  a verified master process is still alive after SIGKILL
#   2  configuration error
set -euo pipefail
umask 077

ROOT_DIR="${HPC_PROJECT_ROOT:-${0:A:h:h}}"
RUNTIME_DIR="${HPC_RUNTIME_DIR:-$ROOT_DIR/.runtime}"
CONTROL_PATH="${HPC_CONTROL_PATH:-}"
TARGET_HOSTNAME="${HPC_HOSTNAME:-}"
REMOTE_USERNAME="${HPC_USERNAME:-}"
TARGET_LABEL="${HPC_TARGET_LABEL:-${TARGET_HOSTNAME:-the cluster}}"
USE_JUMP_HOST="${HPC_USE_JUMP_HOST:-0}"
JUMP_CONTROL_PATH="${HPC_JUMP_CONTROL_PATH:-}"
JUMP_HOSTNAME="${HPC_JUMP_HOSTNAME:-rash.leeds.ac.uk}"
STOP_JUMP_IF_UNUSED="${HPC_STOP_JUMP_IF_UNUSED:-0}"

for required in HPC_CONTROL_PATH HPC_HOSTNAME HPC_USERNAME; do
  if [[ -z "${(P)required:-}" ]]; then
    print -u2 "$required is required"
    exit 2
  fi
done

if [[ "$RUNTIME_DIR" != /* ]]; then
  RUNTIME_DIR="$ROOT_DIR/$RUNTIME_DIR"
fi
if [[ "$CONTROL_PATH" != /* ]]; then
  CONTROL_PATH="$ROOT_DIR/$CONTROL_PATH"
fi
if [[ -n "$JUMP_CONTROL_PATH" && "$JUMP_CONTROL_PATH" != /* ]]; then
  JUMP_CONTROL_PATH="$ROOT_DIR/$JUMP_CONTROL_PATH"
fi

COMMON="$ROOT_DIR/scripts/hpc_ssh_common.zsh"
if [[ ! -r "$COMMON" ]]; then
  print -u2 "Shared login helpers are missing: $COMMON"
  exit 2
fi
source "$COMMON"

# The jump master is shared by every cluster on the rash route; stopping it
# as if it were one cluster's master would silently cut every other
# cluster's tunnel.
if [[ -n "$JUMP_CONTROL_PATH" && "$CONTROL_PATH" == "$JUMP_CONTROL_PATH" ]]; then
  print -u2 "Refusing to stop the shared jump-host session as $TARGET_LABEL's session: HPC_CONTROL_PATH equals HPC_JUMP_CONTROL_PATH."
  exit 2
fi

# Control commands (-O check/-O exit) only talk to the local socket, so the
# route options are irrelevant; ProxyCommand=none keeps a ~/.ssh/config
# entry for the host from ever being consulted for a connection.
hpc_set_proxy_args 0 "" "" ""
hpc_set_verify_base "$CONTROL_PATH" "$REMOTE_USERNAME"
control_base=("${hpc_verify_base[@]}")

pid_path="$(hpc_master_pid_file "$RUNTIME_DIR" "$CONTROL_PATH")"
legacy_pid_path="$RUNTIME_DIR/master_ssh.pid"
legacy_keepalive_pid_path="$RUNTIME_DIR/keepalive.pid"

master_answering() {
  perl -e 'alarm shift; exec @ARGV' 10 \
    "${control_base[@]}" -O check "$TARGET_HOSTNAME" >/dev/null 2>&1
}

was_running=0
if master_answering; then
  was_running=1
  perl -e 'alarm shift; exec @ARGV' 10 \
    "${control_base[@]}" -O exit "$TARGET_HOSTNAME" >/dev/null 2>&1 || true
fi

survivor=0
hpc_stop_master_processes "$CONTROL_PATH" "$pid_path" || survivor=1
if (( hpc_killed_count > 0 )); then
  was_running=1
fi
if [[ -s "$legacy_pid_path" ]]; then
  hpc_stop_master_processes "$CONTROL_PATH" "$legacy_pid_path" || survivor=1
  if (( hpc_killed_count > 0 )); then
    was_running=1
  fi
fi
hpc_stop_legacy_keepalives "$CONTROL_PATH" "$legacy_keepalive_pid_path"

# A master that exited removes its own socket; one that was killed leaves a
# dead socket file behind. Remove it only once nothing answers on it.
if [[ -e "$CONTROL_PATH" || -L "$CONTROL_PATH" ]] && ! master_answering; then
  rm -f -- "$CONTROL_PATH"
fi
rm -f -- "$pid_path"
hpc_retire_shared_pid_file "$legacy_pid_path" "$CONTROL_PATH" master

if (( survivor )); then
  print -u2 "A $TARGET_LABEL master process for $CONTROL_PATH survived SIGKILL."
  exit 1
fi
if (( was_running )); then
  print "HPC-STATUS: stopped the $TARGET_LABEL session"
else
  print "HPC-STATUS: no $TARGET_LABEL session was running"
fi

# ---------------------------------------------------------------------------
# Optional: the shared jump master, only when nothing rides on it any more.
# Every tunnelled cluster master names the jump control path twice over: in
# its own argv (inside its ProxyCommand) and in the `-W` proxy child it keeps
# alive. So does a cluster login in progress, a jump master still
# authenticating (someone is signing in through rash right now) and the
# expect helper's probes. Any such process means "in use".
#
# The one process naming the path that is NOT a rider is the jump master
# serving it. It runs -N, and with ControlPersist plus -N OpenSSH daemonizes
# without control_persist_detach(), so it never retitles itself
# "ssh: <path> [mux]": it keeps its argv, which names the path and carries
# ControlMaster=yes, exactly like a jump master still authenticating. Titles
# cannot tell those two apart; the socket can. `-O check` answers with the
# pid of the master actually serving it, and only that pid is left out
# (plus a "[mux]"-titled master, which an older release started with a
# remote command). When nothing answers, nothing is left out: whatever
# still names the path is kept, the conservative choice.
# ---------------------------------------------------------------------------
if [[ "$STOP_JUMP_IF_UNUSED" != "1" || "$USE_JUMP_HOST" != "1" || -z "$JUMP_CONTROL_PATH" ]]; then
  exit 0
fi

hpc_set_verify_base "$JUMP_CONTROL_PATH" "$REMOTE_USERNAME"
jump_control_base=("${hpc_verify_base[@]}")

jump_answering=0
jump_master_pid=""
if jump_check="$(perl -e 'alarm shift; exec @ARGV' 10 \
    "${jump_control_base[@]}" -O check "$JUMP_HOSTNAME" 2>&1)"; then
  jump_answering=1
  if [[ "$jump_check" =~ 'pid=([0-9]+)' ]]; then
    jump_master_pid="${match[1]}"
  fi
fi

# Verified jump-master processes (either shape, see hpc_is_master_process),
# so a cluster master merely naming the jump path in its ProxyCommand does
# not count as one.
jump_master_processes() {
  local pid
  for pid in ${(u)${(f)"$(hpc_master_candidates "$JUMP_CONTROL_PATH")"}}; do
    if hpc_is_master_process "$pid" "$JUMP_CONTROL_PATH"; then
      print -r -- "$pid"
    fi
  done
  return 0
}

jump_riders() {
  local pid escaped cmdline
  escaped="$(hpc_ere_escape "$JUMP_CONTROL_PATH")"
  for pid in ${(f)"$(pgrep -f "$escaped" 2>/dev/null || true)"}; do
    [[ "$pid" == <-> ]] || continue
    (( pid != $$ )) || continue
    [[ "$pid" != "$jump_master_pid" ]] || continue
    cmdline="$(hpc_ps_command "$pid")"
    [[ -n "$cmdline" ]] || continue
    if [[ "$cmdline" == "ssh: $JUMP_CONTROL_PATH [mux]" || "$cmdline" == "ssh: $JUMP_CONTROL_PATH [mux] "* ]]; then
      continue
    fi
    print -r -- "$pid"
  done
  return 0
}

# Nothing answers and no jump-master process exists: nothing to stop.
if (( ! jump_answering )) && [[ -z "$(jump_master_processes)" ]]; then
  exit 0
fi

riders=(${(f)"$(jump_riders)"})
if (( ${#riders} )); then
  print "HPC-STATUS: kept the shared jump-host session ($JUMP_HOSTNAME): another connection still uses it"
  exit 0
fi

perl -e 'alarm shift; exec @ARGV' 10 \
  "${jump_control_base[@]}" -O exit "$JUMP_HOSTNAME" >/dev/null 2>&1 || true
jump_survivor=0
hpc_stop_master_processes "$JUMP_CONTROL_PATH" || jump_survivor=1
if [[ -e "$JUMP_CONTROL_PATH" || -L "$JUMP_CONTROL_PATH" ]] \
    && ! perl -e 'alarm shift; exec @ARGV' 10 \
      "${jump_control_base[@]}" -O check "$JUMP_HOSTNAME" >/dev/null 2>&1; then
  rm -f -- "$JUMP_CONTROL_PATH"
fi
if (( jump_survivor )); then
  print -u2 "A jump-host master process for $JUMP_CONTROL_PATH survived SIGKILL."
  exit 1
fi
print "HPC-STATUS: stopped the shared jump-host session ($JUMP_HOSTNAME)"
exit 0
