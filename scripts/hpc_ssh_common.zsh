# Shared helpers for the cluster login scripts. SOURCED, never executed:
#   hpc_start_target_master.zsh  (starts one cluster's ControlMaster)
#   hpc_stop_master.zsh          (stops one cluster's ControlMaster)
#   hpc_ssh_login.expect         (only for the verified kill of a dead jump
#                                 master, via `zsh -c 'source ...'`)
#
# Why one file: the rules for "which process is ours to kill" and the ssh
# option sets used to be hand-copied into every script, and the copies
# drifted (the starter's ProxyCommand lost the hardening the expect helper's
# had; a kill rule fixed in one copy stayed broken in another). Everything
# that decides a kill, names a runtime file, or spells an ssh option set for
# these scripts lives here.
#
# Nothing in this file prints secrets, reads stdin, or changes shell options.

# --------------------------------------------------------------------------
# ssh option sets
# --------------------------------------------------------------------------

# An interactive ControlMaster login (password + Duo): the target starter's
# masters and, loaded by hpc_ssh_login.expect, the shared jump master.
#   - password/keyboard-interactive only, one password prompt: a rejected
#     password aborts instead of being re-sent;
#   - ControlPersist=24h is an IDLE limit — the caller must also pass -N, or
#     the master's own session keeps it busy for ever;
#   - ServerAlive 30 s x 10 tolerates a five-minute network outage before a
#     dead link closes the master (shorter would cost a Duo push after every
#     longer Wi-Fi drop; the collector surfaces an outage much sooner anyway).
typeset -ga hpc_master_login_options
hpc_master_login_options=(
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
)

# A non-interactive client of an existing master: `-O check`, `-O exit`, the
# read-only verification command. It can never prompt, never authenticate
# on its own, and never become a master (ControlMaster=no, for the same
# reason the collector uses it: a probe that finds the master gone must
# fail, not quietly turn into a new master or a long-lived connection).
typeset -ga hpc_client_options
hpc_client_options=(
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
  -o ControlMaster=no
)

# The ProxyCommand that tunnels a cluster's connection through the shared
# jump master. It must only ever be a CLIENT of that master:
#   - ControlMaster=no: never become a master itself.
#   - BatchMode plus every authentication method off: if the jump socket is
#     gone, ssh silently falls back to a DIRECT connection to the jump host;
#     that fallback must fail at once, without offering a key from the
#     user's `Host *` IdentityFile or waiting on a prompt nobody answers.
#   - ConnectTimeout: the fallback dial is bounded too.
# Its "Permission denied" (attributed to the jump host) is what the starter
# recognises as "the jump master died", not "the cluster rejected the
# password".
# Usage: hpc_proxy_command <jump-control-path> <user> <jump-host>
hpc_proxy_command() {
  local jump_cp="$1" user="$2" jump_host="$3"
  print -r -- "ssh -o BatchMode=yes -o PubkeyAuthentication=no -o GSSAPIAuthentication=no -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o ConnectTimeout=20 -o ControlMaster=no -o ControlPath=${(q)jump_cp} -o User=${(q)user} -W %h:%p ${(q)jump_host}"
}

# Fills the global array `hpc_proxy_args` with the route options for a
# cluster connection: the jump ProxyCommand on the rash route, or explicit
# ProxyCommand=none/ProxyJump=none on the direct route so a ~/.ssh/config
# entry for the host can never reroute it.
# Usage: hpc_set_proxy_args <use-jump 1|0> <jump-control-path> <user> <jump-host>
hpc_set_proxy_args() {
  typeset -ga hpc_proxy_args
  if [[ "$1" == "1" ]]; then
    hpc_proxy_args=(-o "ProxyCommand=$(hpc_proxy_command "$2" "$3" "$4")")
  else
    hpc_proxy_args=(-o ProxyCommand=none -o ProxyJump=none)
  fi
}

# Fills the global array `hpc_verify_base` with a complete client command
# for a cluster's existing master (hpc_client_options plus its socket, user
# and route). Call hpc_set_proxy_args first.
# Usage: hpc_set_verify_base <control-path> <user>
hpc_set_verify_base() {
  typeset -ga hpc_verify_base
  hpc_verify_base=(
    ssh
    "${hpc_client_options[@]}"
    -o ControlPath="$1"
    -o User="$2"
    "${hpc_proxy_args[@]}"
  )
}

# The read-only command that proves a master really carries sessions.
hpc_target_command='printf '\''auth_ok|%s|%s|%s\n'\'' "$(hostname -f 2>/dev/null || hostname)" "$(whoami)" "$(date -Iseconds 2>/dev/null || date)"'

# --------------------------------------------------------------------------
# Runtime file names
# --------------------------------------------------------------------------

# The master's pid file is named after its CONTROL PATH, not the cluster:
# the path differs per route and username, so a login on one route must
# never overwrite (or delete) the only record of the other route's master.
# aire-3f2a9c1b0d4e.sock -> <runtime>/master-aire-3f2a9c1b0d4e.pid
# Usage: hpc_master_pid_file <runtime-dir> <control-path>
hpc_master_pid_file() {
  local name="${2:t}"
  print -r -- "$1/master-${name%.sock}.pid"
}

# --------------------------------------------------------------------------
# Verified process handling
# --------------------------------------------------------------------------

# `ps` argv of a pid with setproctitle's trailing padding removed; empty when
# the pid is gone. Output is captured (not a tty), so ps never truncates it.
hpc_ps_command() {
  local out
  out="$(ps -p "$1" -o command= 2>/dev/null || true)"
  print -r -- "${out%"${out##*[![:space:]]}"}"
}

# Succeeds only when <pid> is one of OUR ssh processes for exactly this
# control socket. Two process shapes qualify:
#   - "ssh ... ControlPath=<control-path> ... ControlMaster=yes ...": every
#     master these scripts start, detached or not. They all run -N, and with
#     ControlPersist plus -N OpenSSH daemonizes WITHOUT retitling itself:
#     control_persist_detach(), which sets the "[mux]" title, only runs when
#     a session or a stdio forward has to be handed to a foreground client.
#     So a detached master keeps its argv, exactly like a master still
#     authenticating (abandoned at a Duo prompt, say), and titles cannot
#     tell the two apart; where that matters (the stop helper's jump-rider
#     count) the socket can: `-O check` answers with the serving master's
#     pid. This shape also covers the session client that older releases
#     left running a remote `sleep`.
#   - "ssh: <control-path> [mux]": a detached master an older release
#     started WITH a remote command; OpenSSH retitled that one once it had
#     backgrounded, so its argv (and any ControlPath= option) is hidden.
# For the argv shape the *first* ControlPath option must match exactly:
# every master tunnelled through the shared jump host embeds the jump
# ControlPath inside its ProxyCommand string. Requiring ControlMaster=yes
# additionally keeps every cluster's `-W` proxy (an `ssh ... ControlPath=<jump>`
# client without ControlMaster=yes) and every collector or terminal client
# out of reach.
# Usage: hpc_is_master_process <pid> <control-path>
hpc_is_master_process() {
  local pid="$1" control_path="$2" cmdline first_cp
  [[ "$pid" == <-> ]] || return 1
  (( pid > 1 && pid != $$ )) || return 1
  [[ -n "$control_path" ]] || return 1
  cmdline="$(hpc_ps_command "$pid")"
  [[ -n "$cmdline" ]] || return 1
  if [[ "$cmdline" == "ssh: $control_path [mux]" || "$cmdline" == "ssh: $control_path [mux] "* ]]; then
    return 0
  fi
  [[ "$cmdline" == ssh\ * ]] || return 1
  first_cp="${cmdline#*ControlPath=}"
  [[ "$first_cp" != "$cmdline" ]] || return 1
  first_cp="${first_cp%% *}"
  [[ "$first_cp" == "$control_path" ]] || return 1
  [[ " $cmdline " == *" ControlMaster=yes "* ]] || return 1
  return 0
}

# Succeeds when <pid> is some ssh master or authenticating master, for ANY
# control path (either shape above). Used only to decide whether a shared,
# legacy pid file may be deleted: a live master of another route keeps its
# record.
hpc_is_any_master_process() {
  local pid="$1" cmdline
  [[ "$pid" == <-> ]] || return 1
  cmdline="$(hpc_ps_command "$pid")"
  if [[ "$cmdline" == "ssh: "*" [mux]"* ]]; then
    return 0
  fi
  [[ "$cmdline" == ssh\ * && " $cmdline " == *" ControlMaster=yes "* ]]
}

# Escape a literal for an extended regular expression (pgrep -f).
hpc_ere_escape() {
  print -r -- "$1" | sed -e 's/[][^$.*+?(){}|\\]/\\&/g'
}

# Pids that MIGHT be this control path's master processes. Candidates only:
# every caller re-verifies with hpc_is_master_process before signalling.
hpc_master_candidates() {
  local escaped pattern
  escaped="$(hpc_ere_escape "$1")"
  for pattern in "^ssh .*ControlPath=${escaped}" "^ssh: ${escaped} \\[mux\\]"; do
    pgrep -f "$pattern" 2>/dev/null || true
  done
}

# SIGTERM every verified master process of <control-path> (from the
# optional pid file and from a pattern search), then wait up to ~3 s for
# them to exit and SIGKILL any that still verify. Waiting matters: a dying
# OpenSSH master unlinks its ControlPath on the way out, so a replacement
# that binds the same path before the old one has gone would lose its
# socket. Sets `hpc_killed_count` (pids signalled) and returns non-zero
# only if a verified process survived SIGKILL.
# Usage: hpc_stop_master_processes <control-path> [pid-file]
hpc_stop_master_processes() {
  local control_path="$1" pid_file="${2:-}" pid
  local -a candidates victims
  typeset -gi hpc_killed_count=0
  if [[ -n "$pid_file" && -s "$pid_file" ]]; then
    candidates+=("$(<"$pid_file")")
  fi
  candidates+=(${(f)"$(hpc_master_candidates "$control_path")"})
  for pid in ${(u)candidates}; do
    if hpc_is_master_process "$pid" "$control_path"; then
      kill "$pid" 2>/dev/null || true
      victims+=("$pid")
    fi
  done
  hpc_killed_count=${#victims}
  hpc_wait_or_kill "$control_path" master "${victims[@]}"
}

# Wait up to ~3 s for <pids> to exit; SIGKILL the ones that still pass the
# same verification (a recycled pid never does). Returns non-zero if any
# verified process is still alive afterwards.
# Usage: hpc_wait_or_kill <control-path> master|keepalive <pid>...
hpc_wait_or_kill() {
  local control_path="$1" kind="$2" pid tries=0
  shift 2
  local -a alive
  (( $# )) || return 0
  zmodload zsh/zselect 2>/dev/null || true
  while (( tries < 30 )); do
    alive=()
    for pid in "$@"; do
      if kill -0 "$pid" 2>/dev/null; then
        alive+=("$pid")
      fi
    done
    (( ${#alive} )) || return 0
    zselect -t 10 2>/dev/null || true
    tries=$(( tries + 1 ))
  done
  for pid in "${alive[@]}"; do
    if hpc_verify_kind "$pid" "$control_path" "$kind"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  zselect -t 20 2>/dev/null || true
  for pid in "${alive[@]}"; do
    if kill -0 "$pid" 2>/dev/null && hpc_verify_kind "$pid" "$control_path" "$kind"; then
      return 1
    fi
  done
  return 0
}

hpc_verify_kind() {
  case "$3" in
    master) hpc_is_master_process "$1" "$2" ;;
    keepalive) hpc_is_legacy_keepalive "$1" "$2" ;;
    *) return 1 ;;
  esac
}

# Delete a pid file that may be SHARED by several control paths (the
# per-cluster master_ssh.pid / keepalive.pid of older releases), but only
# when it cannot be another route's record: its pid is gone, recycled by an
# unrelated process, or was ours (already stopped by the caller).
# Usage: hpc_retire_shared_pid_file <file> <control-path> master|keepalive
hpc_retire_shared_pid_file() {
  local file="$1" control_path="$2" kind="$3" pid
  [[ -e "$file" ]] || return 0
  pid=""
  if [[ -r "$file" ]]; then
    pid="$(<"$file")"
  fi
  if [[ "$pid" != <-> ]] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f -- "$file"
    return 0
  fi
  if hpc_verify_kind "$pid" "$control_path" "$kind"; then
    rm -f -- "$file"
    return 0
  fi
  case "$kind" in
    master)
      if hpc_is_any_master_process "$pid"; then
        return 0
      fi
      ;;
    keepalive)
      if [[ "$(hpc_ps_command "$pid")" == *"hpc_target_keepalive.zsh "* ]]; then
        return 0
      fi
      ;;
  esac
  rm -f -- "$file"
}

# --------------------------------------------------------------------------
# Upgrade cleanup for processes older releases left behind
# --------------------------------------------------------------------------

# Older releases ran scripts/hpc_target_keepalive.zsh (through
# hpc_start_background_ssh.zsh) next to every master: a remote `true` every
# 5 s, forever, which also kept the master from ever going idle. Both
# scripts are gone; this stops any copy still running for THIS control path.
# A keepalive (and its detached wrapper) is recognised by the script name
# immediately followed by the control path, its first argument.
hpc_is_legacy_keepalive() {
  local pid="$1" control_path="$2"
  [[ "$pid" == <-> ]] || return 1
  (( pid > 1 && pid != $$ )) || return 1
  [[ -n "$control_path" ]] || return 1
  [[ "$(hpc_ps_command "$pid")" == *"hpc_target_keepalive.zsh $control_path "* ]]
}

# Usage: hpc_stop_legacy_keepalives <control-path> [shared-keepalive-pid-file]
hpc_stop_legacy_keepalives() {
  local control_path="$1" pid_file="${2:-}" pid
  local -a candidates victims
  if [[ -n "$pid_file" && -s "$pid_file" ]]; then
    candidates+=("$(<"$pid_file")")
  fi
  candidates+=(${(f)"$(pgrep -f "hpc_target_keepalive\\.zsh $(hpc_ere_escape "$control_path") " 2>/dev/null || true)"})
  for pid in ${(u)candidates}; do
    if hpc_is_legacy_keepalive "$pid" "$control_path"; then
      kill "$pid" 2>/dev/null || true
      victims+=("$pid")
    fi
  done
  hpc_wait_or_kill "$control_path" keepalive "${victims[@]}" || true
  if [[ -n "$pid_file" ]]; then
    hpc_retire_shared_pid_file "$pid_file" "$control_path" keepalive
  fi
  # The launchd job of even older releases (it crash-looped when the master
  # died). Its label is fixed, and launchctl answers without touching the
  # network.
  launchctl remove local.aire.target-keepalive >/dev/null 2>&1 || true
}

# Older releases started the master with a remote `sleep 2147483647`. That
# session client stays attached for ever, so ControlPersist (an IDLE timer)
# never started and the master never expired. Ending the client closes only
# its session: the master itself stays up, now idle, so a reused master
# finally expires ControlPersist after its last real use.
# Usage: hpc_end_legacy_session_clients <control-path>
hpc_end_legacy_session_clients() {
  local control_path="$1" pid
  local -a victims
  for pid in ${(f)"$(pgrep -f "^ssh .*ControlPath=$(hpc_ere_escape "$control_path") .* sleep 2147483647\$" 2>/dev/null || true)"}; do
    if hpc_is_master_process "$pid" "$control_path" \
        && [[ "$(hpc_ps_command "$pid")" == "ssh "*" sleep 2147483647" ]]; then
      kill "$pid" 2>/dev/null || true
      victims+=("$pid")
    fi
  done
  hpc_wait_or_kill "$control_path" master "${victims[@]}" || true
}
