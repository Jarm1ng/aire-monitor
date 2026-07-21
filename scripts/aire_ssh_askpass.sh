#!/usr/bin/env sh
# SSH_ASKPASS helper for the AIRE background ControlMaster.
#
# Answers exactly two prompt kinds:
#   - login password prompts  -> AIRE_ASKPASS_PASSWORD
#   - Duo passcode/option     -> AIRE_ASKPASS_DUO_OPTION (default 1)
#
# Anything else — password-change flows, host-key confirmations, unknown
# prompts — is refused (nothing printed, non-zero exit) so ssh fails fast with
# a diagnosable error instead of looping on a wrong answer. ssh itself runs
# with NumberOfPasswordPrompts=1, so a rejected password aborts rather than
# re-asking.
set -eu
umask 077

prompt="${1:-}"
lower_prompt="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')"

log_prompt() {
    # Logging is opt-in (AIRE_DEBUG=1) and digit runs are redacted so Duo
    # enrolled-device hints and phone numbers never reach disk.
    if [ "${AIRE_DEBUG:-0}" = "1" ] && [ -n "${AIRE_ASKPASS_LOG:-}" ]; then
        redacted="$(printf '%s' "$prompt" | tr '0-9' 'X')"
        printf '%s\n' "$1 prompt: $redacted" >> "$AIRE_ASKPASS_LOG" 2>/dev/null || true
    fi
}

case "$lower_prompt" in
    *"new password"*|*"retype"*|*"change password"*|*"current password"*)
        # Never feed the stored password into a password-change flow.
        log_prompt refused-password-change
        exit 1
        ;;
    *password*)
        log_prompt password
        printf '%s\n' "${AIRE_ASKPASS_PASSWORD:-}"
        ;;
    *passcode*|*option*|*verification*|*response*)
        log_prompt duo
        printf '%s\n' "${AIRE_ASKPASS_DUO_OPTION:-1}"
        ;;
    *)
        # Unknown prompt (changed host key, legal banner, ...): refuse.
        log_prompt refused-unknown
        exit 1
        ;;
esac
