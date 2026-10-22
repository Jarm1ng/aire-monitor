"""Sign-in rules that need only the standard library.

ssh.py (paramiko) and app.py (Qt) apply them; keeping them here lets the
stdlib-only tests check them on any machine, the same split as rules.py.

Two jobs, both about not pushing the university account towards a lockout
(every wrong password counts, across email, VPN and the clusters):

- PromptResponder answers one SSH server's keyboard-interactive prompts:
  the password only to a real password prompt and at most once, never to a
  password-change prompt, and everything else (Duo above all) to the user.
- SavedPasswordGuard keeps a saved password that a server refused from ever
  being sent again automatically, as the macOS app does (AppModel's
  savedPasswordRejected).
"""

from __future__ import annotations

import re
from collections.abc import Callable
from typing import Any, Protocol


class AuthenticationRejected(Exception):
    """A server refused the sign-in, or the app stopped it to protect the account."""


class PasswordRejected(AuthenticationRejected):
    """The server refused the password: it never moved on to a second step."""


class PasswordExpired(AuthenticationRejected):
    """The server asked for a password change. Nothing was sent to it."""


class DuoNotApproved(AuthenticationRejected):
    """The password was accepted, but the second step (Duo) was not completed."""


class Cancelled(Exception):
    pass


# What a keyboard-interactive prompt asks for (classify_prompt).
PASSWORD_CHANGE = "password-change"
PASSWORD = "password"
SECOND_FACTOR = "second-factor"
OTHER = "other"

# The patterns are scripts/hpc_ssh_login.expect's (the macOS sign-in), which
# the askpass helper's globs approximate. OpenSSH puts the PAM messages that
# precede a prompt (PAM_TEXT_INFO / PAM_ERROR_MSG) in front of the prompt's
# own text, one per line, so a prompt can read
#   "Your password will expire in 5 day(s).\nPasscode or option (1-1): "
# while an AD password nears expiry. That is Duo's prompt, not a password
# prompt: what is asked for is decided on the last line only, and only
# statements that the password HAS expired count anywhere in the text.

# Anywhere in the text (the info lines included): the password has already
# expired, or the server is in a change flow. Advance warnings ("will
# expire") deliberately do not match.
_EXPIRED = re.compile(
    r"\(current\)\s*(unix\s+|ldap\s+|kerberos\s+)?password"
    r"|password\s+(has\s+)?expired"
    r"|(must|required\s+to)\s+change\s+your\s+password",
    re.IGNORECASE,
)
# On the last line: the change flow's own prompts ("Current Password:",
# "New password:", "Retype new password:").
_CHANGE_PROMPT = re.compile(
    r"\b(new|current|old|retype|re-enter|reenter|confirm)\s+(unix\s+|ldap\s+|kerberos\s+)?password[^\n]*:\s*$",
    re.IGNORECASE,
)
_PASSWORD_PROMPT = re.compile(r"password[^\n]*:\s*$", re.IGNORECASE)
# Every Duo / second-factor prompt shape the macOS sign-in recognises, plus a
# bare "Passcode:".
_SECOND_FACTOR_PROMPT = re.compile(
    r"passcode\s+or\s+option[^\n]*:\s*$"
    r"|option\s*\([^)]*\)\s*:\s*$"
    r"|verification\s+code[^\n]*:\s*$"
    r"|response[^\n]*:\s*$"
    r"|passcode[^\n]*:\s*$",
    re.IGNORECASE,
)


def last_line(text: str) -> str:
    lines = [line for line in text.splitlines() if line.strip()]
    return lines[-1] if lines else ""


def classify_prompt(text: str, context: str = "") -> str:
    """PASSWORD_CHANGE, PASSWORD, SECOND_FACTOR or OTHER for one prompt.

    context is the request's title and instructions; some servers state the
    expiry there rather than in the prompt.
    """
    if _EXPIRED.search(f"{context}\n{text}"):
        return PASSWORD_CHANGE
    line = last_line(text)
    if _CHANGE_PROMPT.search(line):
        return PASSWORD_CHANGE
    if _PASSWORD_PROMPT.search(line):
        return PASSWORD
    if _SECOND_FACTOR_PROMPT.search(line):
        return SECOND_FACTOR
    return OTHER


Ask = Callable[[str, str, Any], Any]


class PromptResponder:
    """paramiko's keyboard-interactive handler for one SSH server.

    - The university password goes only to a real password prompt, at most
      once per server: a second request means the first was refused, and
      answering again would be one more bad attempt.
    - A password-change prompt is refused before anything is answered: the
      sign-in fails as PasswordExpired and the server receives nothing, so
      neither a typed nor a saved password is ever fed into a change flow.
    - Everything else, Duo's passcode/option prompt included, goes to the
      user with the server's own text (warning lines in front of it too).

    Raising from here (paramiko runs the handler on its transport thread)
    ends the connection without sending an answer. paramiko re-raises the
    exception in the thread that called auth_interactive; it is also kept
    in stopped_with, so the caller has the reason even if paramiko reports
    the ended connection as a plain authentication failure instead.

    rejected() then says what a refused sign-in means, from what was sent:
    the macOS rule is that reaching a later prompt (Duo) proves the password
    was accepted (hpc_ssh_login.expect).
    """

    def __init__(self, host: str, password: str, ask: Ask):
        self.host = host
        self._password: str | None = password
        self.ask = ask
        self.password_sent = False
        # Evidence the password was right: the server moved on to another
        # prompt after it, or reported partial success.
        self.password_accepted = False
        self.stopped_with: AuthenticationRejected | Cancelled | None = None

    def __call__(self, title: str, instructions: str, prompts) -> list[str]:
        try:
            return self._answer(title, instructions, prompts)
        except (AuthenticationRejected, Cancelled) as exc:
            self.stopped_with = exc
            raise

    def _answer(self, title: str, instructions: str, prompts) -> list[str]:
        context = f"{title}\n{instructions}"
        prompts = list(prompts)
        kinds = [classify_prompt(text, context) for text, _ in prompts]
        # Checked for the whole request first, so no dialog is shown and no
        # answer is prepared for a request that includes a change prompt.
        # A request without prompts (info only) can carry the notice too.
        if PASSWORD_CHANGE in kinds or (not prompts and _EXPIRED.search(context)):
            raise PasswordExpired(
                f"{self.host} reports that the password has expired and asks for a new one. "
                "Nothing was sent to the change prompt. Change your password with the University "
                "first, then connect again."
            )
        # A prompt in this request can only prove a password sent in an
        # earlier one: the server has not judged one sent alongside it yet.
        sent_before = self.password_sent
        answers = []
        for (text, echo), kind in zip(prompts, kinds):
            if kind == PASSWORD:
                answers.append(self.send_password())
                continue
            if sent_before:
                self.password_accepted = True
            answer = self.ask("challenge", self.host, (title, instructions, text, echo))
            if answer is None:
                raise Cancelled("Sign-in cancelled.")
            answers.append(str(answer))
        return answers

    def send_password(self) -> str:
        """The password, the one time it may be sent to this server."""
        if self.password_sent:
            if self.password_accepted:
                raise AuthenticationRejected(
                    f"{self.host} requested the password again after accepting it. "
                    "Sign-in stopped to avoid account lockout."
                )
            raise PasswordRejected(
                f"{self.host} requested the password again, so it was not accepted. "
                "Sign-in stopped to avoid account lockout."
            )
        if self._password is None:
            raise Cancelled("Sign-in already finished.")
        self.password_sent = True
        return self._password

    def note_partial_success(self) -> None:
        """The server accepted what was sent so far but wants another method."""
        if self.password_sent:
            self.password_accepted = True

    def rejected(self) -> AuthenticationRejected:
        """The error for a sign-in this server refused."""
        if self.password_accepted:
            return DuoNotApproved(
                f"{self.host} accepted the password, but the Duo step was not completed "
                "(declined, timed out or answered wrongly). The app does not retry it."
            )
        if self.password_sent:
            return PasswordRejected(
                f"{self.host} rejected the password. There is no automatic retry: "
                "check the password before connecting again."
            )
        return AuthenticationRejected(
            f"{self.host} did not accept the sign-in. No password was sent. Remaining sign-ins cancelled."
        )

    def forget(self) -> None:
        """Drop the password once the sign-in is over. paramiko keeps this
        handler for the life of the connection (hours), so it must not keep
        the password with it."""
        self._password = None


SAVED_PASSWORD_REJECTED = (
    "The saved password was rejected, so it will not be sent again. Type your current password "
    "(tick the save option as well to replace the saved one)."
)
MISSING_PASSWORD = "Enter your university password. It is never written to a file."


class FlagStore(Protocol):
    """Where the rejected flags persist (core.LocalStore)."""

    def saved_password_rejected(self, username: str) -> bool:
        """Whether a server rejected this account's saved password."""
        ...

    def set_saved_password_rejected(self, username: str, rejected: bool) -> None:
        """Record or lift that flag."""
        ...


class SavedPasswordGuard:
    """The optional saved password and its per-account "rejected" flag.

    Once a server refuses the saved password (or reports it expired), that
    password is never sent automatically again: every attempt counts toward
    the university account lockout, and a user who changed their password
    would otherwise burn one attempt per Connect without a Duo push to tell
    them why. The flag is persisted (settings.json) so it survives restarts,
    and kept in memory as well in case the file cannot be written.

    It is lifted only by a typed password that a server has just accepted,
    and only once no different saved password remains to be resent: the
    typed one replaced it (saving ticked), or the saved entry is gone or is
    that same password. A Duo push that was not approved says nothing about
    the password, so it never sets the flag.
    """

    def __init__(self, store: FlagStore, vault: Callable[[], Any], service: str):
        self.store = store
        # Returns the keyring backend (platform_support.credential_backend).
        self.vault = vault
        self.service = service
        self.rejected: set[str] = set()

    def blocked(self, username: str) -> bool:
        return username in self.rejected or self.store.saved_password_rejected(username)

    def read(self, username: str) -> tuple[str | None, str | None]:
        """(password, problem): the saved password or None, and why it could
        not be read or None. A missing entry is simply None; a store that
        fails is reported, so the user knows why the password is asked for."""
        try:
            return self.vault().get_password(self.service, username), None
        except Exception as exc:
            return None, f"The saved password could not be read ({exc})."

    def choose(self, username: str, typed: str) -> tuple[str, bool]:
        """(password, from_saved) for a Connect press, or ValueError with the
        message to show. A blocked saved password is not even read."""
        if typed:
            return typed, False
        if self.blocked(username):
            raise ValueError(SAVED_PASSWORD_REJECTED)
        saved, problem = self.read(username)
        if not saved:
            raise ValueError((f"{problem} " if problem else "") + MISSING_PASSWORD)
        return saved, True

    def rejected_by_server(self, username: str) -> str:
        """Record that a server refused the saved password; returns the message to show."""
        self.rejected.add(username)
        try:
            self.store.set_saved_password_rejected(username, True)
        except OSError as exc:
            return f"{SAVED_PASSWORD_REJECTED} (Could not record this in the settings file: {exc}.)"
        return SAVED_PASSWORD_REJECTED

    def verified(self, username: str, password: str, remember: bool, save_failed: str) -> str | None:
        """A typed password that a server has just accepted. Saves it when
        asked and settles the flag; returns a problem to show, or None."""
        if remember:
            try:
                self.vault().set_password(self.service, username, password)
            except Exception:
                return save_failed
            if self.blocked(username):
                self._clear(username)
            return None
        if self.blocked(username):
            saved, problem = self.read(username)
            # A different saved password is still the rejected one: keep it
            # blocked until it is replaced or forgotten.
            if problem is None and (saved is None or saved == password):
                self._clear(username)
        return None

    def _clear(self, username: str) -> None:
        self.rejected.discard(username)
        try:
            self.store.set_saved_password_rejected(username, False)
        except OSError:
            # The file still says rejected, so blocked() stays true: safe.
            pass
