#!/usr/bin/env sh
# SSH_ASKPASS helper for a cluster's background ControlMaster (AIRE, Calder,
# ...). The helper is cluster-neutral: it only ever answers the ssh process
# that hpc_start_target_master.zsh launched for one cluster.
#
# Answers exactly two prompt kinds:
#   - login password prompts  -> one line read from the FIFO named by
#                                HPC_ASKPASS_FIFO (preferred), or
#                                HPC_ASKPASS_PASSWORD (manual/legacy use only)
#   - Duo passcode/option     -> HPC_ASKPASS_DUO_OPTION (default 1)
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

answer_password() {
    if [ -n "${HPC_ASKPASS_FIFO:-}" ]; then
        # Only ever read from a real FIFO: a missing path or a regular file
        # means the starter is gone (or something is wrong), so refuse
        # rather than block or echo whatever happens to be there.
        if [ ! -p "$HPC_ASKPASS_FIFO" ]; then
            log_prompt refused-missing-fifo
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
        return 0
    fi
    printf '%s\n' "${HPC_ASKPASS_PASSWORD:-}"
}

case "$lower_prompt" in
    *"new password"*|*"retype"*|*"change password"*|*"current password"*|*"password has expired"*|*"password expired"*)
        # Never feed the stored password into a password-change flow. Tell
        # the starter why ssh is about to fail (an expired password, not a
        # wrong one) through its per-login events file — a fixed word, never
        # prompt text or secrets.
        log_prompt refused-password-change
        if [ -n "${HPC_ASKPASS_EVENTS:-}" ]; then
            printf 'password-change\n' >> "$HPC_ASKPASS_EVENTS" 2>/dev/null || true
        fi
        exit 1
        ;;
    *password*)
        log_prompt password
        answer_password
        ;;
    *passcode*|*option*|*verification*|*response*)
        log_prompt duo
        printf '%s\n' "${HPC_ASKPASS_DUO_OPTION:-1}"
        ;;
    *)
        # Unknown prompt (changed host key, legal banner, ...): refuse.
        log_prompt refused-unknown
        exit 1
        ;;
esac
