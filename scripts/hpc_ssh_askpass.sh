#!/usr/bin/env sh
# SSH_ASKPASS helper for a cluster's background ControlMaster (AIRE, Calder,
# ...). The helper is cluster-neutral: it only ever answers the ssh process
# that hpc_start_target_master.zsh launched for one cluster.
#
# Answers exactly two prompt kinds, each at most ONCE per login:
#   - the login password prompt -> one line read from the FIFO named by
#                                  HPC_ASKPASS_FIFO (preferred), or
#                                  HPC_ASKPASS_PASSWORD (manual/legacy use only)
#   - the Duo passcode/option   -> HPC_ASKPASS_DUO_OPTION (default 1)
#
# Why a FIFO: ssh hands its *own* environment to the askpass child, and
# `ssh -f` daemonizes into the long-lived ControlMaster with that environment
# intact. A password exported to ssh as an environment variable would
# therefore live for the master's whole lifetime (readable with `ps eww` by
# the same user). The starter instead serves the password through a 0600 FIFO
# in the cluster's 0700 runtime directory and removes it as soon as ssh
# returns, so the master's environment only ever holds the (dead) FIFO path.
#
# Anything else — password-change flows, host-key confirmations, unknown
# prompts — is refused (nothing printed, non-zero exit) so ssh fails fast with
# a diagnosable error instead of looping on a wrong answer. ssh itself runs
# with NumberOfPasswordPrompts=1, so a rejected password aborts rather than
# re-asking.
#
# What happened is reported to the starter through its per-login events file
# (HPC_ASKPASS_EVENTS), one FIXED word per line — never prompt text, never a
# secret. The starter turns these into progress lines and exit codes:
#   password         the password was handed to ssh
#   password-retry   a second password prompt (the first was rejected); refused
#   password-change  a password-change prompt (expired password); refused
#   duo              the Duo option was answered (one push requested)
#   duo-denied       Duo asked again after "Login request denied."
#   duo-timeout      Duo asked again after the push timed out
#   duo-retry        Duo asked again for another reason
#
# One push per login: pam_duo re-prompts after a declined or expired push
# (its `prompts` option defaults to 3), and answering again would send the
# user a second and third push for a login they already turned down. A
# refusal is not enough to prevent that — when askpass fails, ssh sends the
# server an EMPTY answer, and what pam_duo does with an empty answer is its
# business (it may well pick its default factor and push again). So on a
# repeated Duo prompt this helper ends the authenticating ssh itself before
# returning, and no answer of any kind reaches the server.
#
# Optional, opt-in debug logging: HPC_DEBUG=1 plus HPC_ASKPASS_LOG=<path>.
set -eu
umask 077

prompt="${1:-}"
lower_prompt="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')"

log_prompt() {
    # Logging is opt-in (HPC_DEBUG=1) and digit runs are redacted so Duo
    # enrolled-device hints and phone numbers never reach disk.
    if [ "${HPC_DEBUG:-0}" = "1" ] && [ -n "${HPC_ASKPASS_LOG:-}" ]; then
        redacted="$(printf '%s' "$prompt" | tr '0-9' 'X')"
        printf '%s\n' "$1 prompt: $redacted" >> "$HPC_ASKPASS_LOG" 2>/dev/null || true
    fi
}

record_event() {
    if [ -n "${HPC_ASKPASS_EVENTS:-}" ]; then
        printf '%s\n' "$1" >> "$HPC_ASKPASS_EVENTS" 2>/dev/null || true
    fi
}

has_event() {
    [ -n "${HPC_ASKPASS_EVENTS:-}" ] && [ -s "$HPC_ASKPASS_EVENTS" ] \
        && grep -qx "$1" "$HPC_ASKPASS_EVENTS" 2>/dev/null
}

# End the ssh that asked, so it cannot send the server any answer at all.
# Only when the starter launched us (it names its master's control path in
# HPC_ASKPASS_CONTROL_PATH), and only after confirming our parent is exactly
# that authenticating ssh: an `ssh ...` whose argv carries
# ControlPath=<that path>. ssh runs askpass as its direct child and waits for
# it, so the parent cannot have exited and had its pid reused meanwhile.
stop_asking_ssh() {
    [ -n "${HPC_ASKPASS_CONTROL_PATH:-}" ] || return 0
    parent="${PPID:-}"
    case "$parent" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$parent" -gt 1 ] || return 0
    parent_cmd="$(ps -p "$parent" -o command= 2>/dev/null || true)"
    case "$parent_cmd" in
        *"ControlPath=$HPC_ASKPASS_CONTROL_PATH "*)
            kill -TERM "$parent" 2>/dev/null || true
            ;;
    esac
}

answer_password() {
    if [ -n "${HPC_ASKPASS_FIFO:-}" ]; then
        # Only ever read from a real FIFO: a missing path or a regular file
        # means the starter is gone, or this is a second password prompt
        # after the one-shot FIFO was consumed. Refuse rather than block or
        # echo whatever happens to be there.
        if [ ! -p "$HPC_ASKPASS_FIFO" ]; then
            log_prompt refused-missing-fifo
            if has_event password; then
                record_event password-retry
            fi
            exit 1
        fi
        secret=""
        IFS= read -r secret < "$HPC_ASKPASS_FIFO" || true
        if [ -z "$secret" ]; then
            log_prompt refused-empty-password
            exit 1
        fi
        printf '%s\n' "$secret"
        secret=""
        record_event password
        return 0
    fi
    if has_event password; then
        log_prompt refused-second-password
        record_event password-retry
        exit 1
    fi
    printf '%s\n' "${HPC_ASKPASS_PASSWORD:-}"
    record_event password
}

case "$lower_prompt" in
    *"new password"*|*"retype"*|*"change password"*|*"current password"*|*"(current)"*password*|*"password has expired"*|*"password expired"*|*"must change your password"*)
        # Never feed the stored password into a password-change flow
        # (RHEL 7's pam_unix asks "(current) UNIX password:"; pam_sss says
        # "Password expired. Change your password now." then "Current
        # Password:"). Tell the starter why ssh is about to fail: an expired
        # password, not a wrong one.
        log_prompt refused-password-change
        record_event password-change
        exit 1
        ;;
    *password*)
        log_prompt password
        answer_password
        ;;
    *passcode*|*option*|*verification*|*response*)
        if has_event duo; then
            # pam_duo is asking again, so the push we requested was not
            # approved. Name the reason from the server's own words (they
            # arrive prefixed to the repeated prompt), then stop: see
            # "One push per login" above.
            case "$lower_prompt" in
                *denied*) reason=duo-denied ;;
                *"timed out"*|*timeout*) reason=duo-timeout ;;
                *) reason=duo-retry ;;
            esac
            log_prompt "refused-$reason"
            record_event "$reason"
            stop_asking_ssh
            exit 1
        fi
        log_prompt duo
        printf '%s\n' "${HPC_ASKPASS_DUO_OPTION:-1}"
        record_event duo
        ;;
    *)
        # Unknown prompt (changed host key, legal banner, ...): refuse.
        log_prompt refused-unknown
        exit 1
        ;;
esac
