"""Sign-in rules (login.py): prompt classification, the prompt responder
and the saved password's "rejected" flag. Standard library only, so these
run on any machine."""

import json
import threading
from pathlib import Path

import pytest

from leeds_hpc_desktop import login
from leeds_hpc_desktop.core import SETTINGS_FILE, LocalStore
from leeds_hpc_desktop.login import (
    OTHER,
    PASSWORD,
    PASSWORD_CHANGE,
    SAVED_PASSWORD_REJECTED,
    SECOND_FACTOR,
    AuthenticationRejected,
    Cancelled,
    DuoNotApproved,
    PasswordExpired,
    PasswordRejected,
    PromptResponder,
    SavedPasswordGuard,
    classify_prompt,
)

# OpenSSH puts PAM's info lines in front of the prompt, so this is what Duo's
# prompt reads while an AD password nears expiry.
WARNED_DUO = (
    "Your password will expire in 5 day(s).\n"
    "Duo two-factor login for demo\n\n"
    "Enter a passcode or select one of the following options:\n\n"
    " 1. Duo Push to XXX-XXX-0000\n\n"
    "Passcode or option (1-1): "
)


@pytest.mark.parametrize(
    "text,kind",
    [
        ("Password: ", PASSWORD),
        ("demo@aire.leeds.ac.uk's password: ", PASSWORD),
        ("Your password will expire in 5 day(s).\nPassword: ", PASSWORD),
        ("Passcode or option (1-1): ", SECOND_FACTOR),
        ("Passcode or option: ", SECOND_FACTOR),
        ("Passcode:", SECOND_FACTOR),
        ("Verification code: ", SECOND_FACTOR),
        # The Duo prompt with the expiry warning in front of it is Duo's.
        (WARNED_DUO, SECOND_FACTOR),
        ("Warning: your password will expire in 2 days\nPasscode or option (1-2): ", SECOND_FACTOR),
        # Password-change flows: refused, wherever the wording comes from.
        ("Current Password: ", PASSWORD_CHANGE),
        ("(current) UNIX password: ", PASSWORD_CHANGE),
        ("Password expired. Change your password now.\nCurrent Password: ", PASSWORD_CHANGE),
        ("Your password has expired.\nPassword: ", PASSWORD_CHANGE),
        ("You are required to change your password immediately (password aged)\nPassword: ", PASSWORD_CHANGE),
        ("You must change your password now.\nPassword: ", PASSWORD_CHANGE),
        ("New password: ", PASSWORD_CHANGE),
        ("Enter new UNIX password: ", PASSWORD_CHANGE),
        ("Retype new password: ", PASSWORD_CHANGE),
        ("Re-enter new password: ", PASSWORD_CHANGE),
        ("Confirm password: ", PASSWORD_CHANGE),
        # Anything else goes to the user.
        ("Duo:", OTHER),
        ("Press enter to continue", OTHER),
        ("", OTHER),
    ],
)
def test_prompt_classification(text, kind):
    assert classify_prompt(text) == kind


def test_expiry_stated_in_the_instructions_counts():
    assert classify_prompt("Password: ", "Password expired\n") == PASSWORD_CHANGE
    assert classify_prompt("Password: ", "Your password will expire soon") == PASSWORD


class Asker:
    def __init__(self, *answers):
        self.answers = list(answers)
        self.calls = []

    def __call__(self, kind, host, content):
        self.calls.append((kind, host, content))
        return self.answers.pop(0) if self.answers else None


def test_password_once_then_duo_from_the_user():
    ask = Asker("1")
    responder = PromptResponder("aire.test", "test-only", ask)
    assert responder("", "", [("Password: ", False)]) == ["test-only"]
    assert responder("Duo", "Choose", [("Passcode or option (1-1): ", True)]) == ["1"]
    assert ask.calls == [("challenge", "aire.test", ("Duo", "Choose", "Passcode or option (1-1): ", True))]
    assert responder.password_sent and responder.password_accepted


def test_duo_prompt_with_an_expiry_warning_goes_to_the_user():
    # The password-reuse guard must not mistake it for a second password
    # request (that used to stop every sign-in during the warning period).
    ask = Asker("1")
    responder = PromptResponder("aire.test", "test-only", ask)
    responder("", "", [("Password: ", False)])
    assert responder("", "", [(WARNED_DUO, True)]) == ["1"]
    # The user sees the warning with the prompt.
    assert "will expire in 5 day(s)" in ask.calls[0][2][2]


@pytest.mark.parametrize(
    "prompts",
    [
        [("Password expired. Change your password now.\nCurrent Password: ", False)],
        [("(current) UNIX password: ", False)],
        [("New password: ", False), ("Retype new password: ", False)],
        # A change prompt anywhere in the request: nothing at all is asked.
        [("Passcode or option (1-1): ", True), ("Current Password: ", False)],
    ],
)
def test_password_change_is_refused_before_anything_is_answered(prompts):
    ask = Asker("1")
    responder = PromptResponder("aire.test", "test-only", ask)
    with pytest.raises(PasswordExpired, match="expired"):
        responder("", "", prompts)
    assert ask.calls == []
    assert not responder.password_sent


def test_change_after_the_password_is_expired_not_rejected():
    responder = PromptResponder("aire.test", "test-only", Asker())
    responder("", "", [("Password: ", False)])
    with pytest.raises(PasswordExpired):
        responder("", "", [("Password expired. Change your password now.\nCurrent Password: ", False)])


def test_info_only_expiry_notice_is_refused():
    with pytest.raises(PasswordExpired):
        PromptResponder("aire.test", "x", Asker())("", "Your password has expired.", [])
    assert PromptResponder("aire.test", "x", Asker())("", "Welcome", []) == []


def test_second_password_request_is_a_rejection_and_sends_nothing():
    responder = PromptResponder("aire.test", "test-only", Asker())
    responder("", "", [("Password: ", False)])
    with pytest.raises(PasswordRejected, match="requested the password again"):
        responder("", "", [("Password: ", False)])


def test_second_password_request_after_acceptance_is_not_called_a_rejection():
    responder = PromptResponder("aire.test", "test-only", Asker())
    responder.send_password()
    responder.note_partial_success()
    with pytest.raises(AuthenticationRejected, match="after accepting it") as caught:
        responder("", "", [("Password: ", False)])
    assert not isinstance(caught.value, PasswordRejected)


def test_cancelled_challenge():
    with pytest.raises(Cancelled):
        PromptResponder("aire.test", "x", Asker(None))("", "", [("Passcode or option: ", True)])


def test_what_a_refusal_means():
    nothing = PromptResponder("aire.test", "x", Asker())
    assert type(nothing.rejected()) is AuthenticationRejected
    password_only = PromptResponder("aire.test", "x", Asker())
    password_only("", "", [("Password: ", False)])
    assert isinstance(password_only.rejected(), PasswordRejected)
    # Reaching Duo after the password proves the password was right.
    after_duo = PromptResponder("aire.test", "x", Asker("1"))
    after_duo("", "", [("Password: ", False)])
    after_duo("", "", [("Passcode or option (1-1): ", True)])
    assert isinstance(after_duo.rejected(), DuoNotApproved)


def test_a_prompt_beside_the_password_proves_nothing():
    # Both in one request: the server has not judged the password yet.
    responder = PromptResponder("aire.test", "x", Asker("1"))
    responder("", "", [("Password: ", False), ("Passcode or option: ", True)])
    assert isinstance(responder.rejected(), PasswordRejected)


def test_forget_drops_the_password():
    responder = PromptResponder("aire.test", "test-only", Asker())
    responder.forget()
    assert "test-only" not in vars(responder).values()
    with pytest.raises(Cancelled):
        responder("", "", [("Password: ", False)])


class FakeVault:
    def __init__(self, saved=None, fail_read=False, fail_save=False):
        self.saved = dict(saved or {})
        self.fail_read = fail_read
        self.fail_save = fail_save
        self.reads = 0
        self.writes = []

    def get_password(self, service, username):
        self.reads += 1
        if self.fail_read:
            raise RuntimeError("locked")
        return self.saved.get((service, username))

    def set_password(self, service, username, password):
        if self.fail_save:
            raise RuntimeError("no store")
        self.writes.append(username)
        self.saved[(service, username)] = password


def guard_with(tmp_path, vault):
    store = LocalStore(tmp_path)
    return SavedPasswordGuard(store, lambda: vault, "Svc"), store


def test_typed_password_wins_and_saved_one_is_used_otherwise(tmp_path):
    vault = FakeVault({("Svc", "demo"): "saved-pass"})
    guard, _ = guard_with(tmp_path, vault)
    assert guard.choose("demo", "typed-pass") == ("typed-pass", False)
    assert vault.reads == 0
    assert guard.choose("demo", "") == ("saved-pass", True)


def test_missing_or_unreadable_saved_password_asks_for_one(tmp_path):
    guard, _ = guard_with(tmp_path, FakeVault())
    with pytest.raises(ValueError, match="Enter your university password"):
        guard.choose("demo", "")
    guard, _ = guard_with(tmp_path, FakeVault(fail_read=True))
    with pytest.raises(ValueError, match=r"could not be read \(locked\)"):
        guard.choose("demo", "")


def test_rejected_saved_password_is_never_read_or_sent_again(tmp_path):
    vault = FakeVault({("Svc", "demo"): "old-pass"})
    guard, store = guard_with(tmp_path, vault)
    assert guard.rejected_by_server("demo") == SAVED_PASSWORD_REJECTED
    assert store.saved_password_rejected("demo")
    reads = vault.reads
    with pytest.raises(ValueError, match="rejected"):
        guard.choose("demo", "")
    assert vault.reads == reads
    # Persisted: a new run (a new guard on the same folder) keeps refusing.
    again, _ = guard_with(tmp_path, vault)
    with pytest.raises(ValueError, match="rejected"):
        again.choose("demo", "")
    # Other accounts are unaffected.
    assert not again.blocked("other")


def test_flag_is_kept_in_memory_when_the_settings_cannot_be_written(tmp_path, monkeypatch):
    guard, store = guard_with(tmp_path, FakeVault({("Svc", "demo"): "old-pass"}))

    def fail(*args, **kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(store, "write", fail)
    assert "disk full" in guard.rejected_by_server("demo")
    with pytest.raises(ValueError, match="rejected"):
        guard.choose("demo", "")


def test_typed_password_saved_with_remember_lifts_the_flag(tmp_path):
    vault = FakeVault({("Svc", "demo"): "old-pass"})
    guard, store = guard_with(tmp_path, vault)
    guard.rejected_by_server("demo")
    assert guard.verified("demo", "new-pass", True, "save failed") is None
    assert vault.saved[("Svc", "demo")] == "new-pass"
    assert not guard.blocked("demo")
    assert guard.choose("demo", "") == ("new-pass", True)


def test_flag_stays_while_a_different_saved_password_remains(tmp_path):
    # Typed and accepted, but not saved: the old (rejected) one is still
    # in the store and must stay blocked.
    vault = FakeVault({("Svc", "demo"): "old-pass"})
    guard, _ = guard_with(tmp_path, vault)
    guard.rejected_by_server("demo")
    assert guard.verified("demo", "new-pass", False, "save failed") is None
    assert guard.blocked("demo")
    assert vault.writes == []


@pytest.mark.parametrize("saved", [None, "new-pass"])
def test_flag_lifted_once_nothing_different_is_saved(tmp_path, saved):
    vault = FakeVault({("Svc", "demo"): saved} if saved else {})
    guard, _ = guard_with(tmp_path, vault)
    guard.rejected_by_server("demo")
    guard.verified("demo", "new-pass", False, "save failed")
    assert not guard.blocked("demo")


def test_flag_stays_when_the_store_cannot_be_checked_or_saved(tmp_path):
    guard, _ = guard_with(tmp_path, FakeVault(fail_read=True))
    guard.rejected_by_server("demo")
    guard.verified("demo", "new-pass", False, "save failed")
    assert guard.blocked("demo")
    guard, _ = guard_with(tmp_path, FakeVault(fail_save=True))
    assert guard.verified("demo", "new-pass", True, "save failed") == "save failed"
    assert guard.blocked("demo")


def test_flags_keep_the_other_settings_and_ignore_case(tmp_path):
    store = LocalStore(tmp_path)
    store.update_settings(username="demo", route="jump")
    store.set_saved_password_rejected("Demo", True)
    store.update_settings(username="demo", route="direct")
    settings = json.loads((tmp_path / SETTINGS_FILE).read_text())
    assert settings == {"username": "demo", "route": "direct", "saved_password_rejected": ["demo"]}
    assert store.saved_password_rejected("DEMO")
    store.set_saved_password_rejected("demo", False)
    assert json.loads((tmp_path / SETTINGS_FILE).read_text()) == {"username": "demo", "route": "direct"}
    assert "password" not in (tmp_path / SETTINGS_FILE).read_text()


@pytest.mark.parametrize("content", ["not json", "[]", '{"saved_password_rejected": "demo"}'])
def test_unreadable_flags_fail_closed(tmp_path, content):
    (tmp_path / SETTINGS_FILE).write_text(content)
    assert LocalStore(tmp_path).saved_password_rejected("demo")


def test_no_settings_file_means_no_flag(tmp_path):
    assert not LocalStore(tmp_path).saved_password_rejected("demo")


@pytest.mark.parametrize("content", ["", "not json", "[]"])
def test_replacing_an_unreadable_settings_file_keeps_failing_closed(tmp_path, content):
    # e.g. settings.json cut short by a power cut. Every Connect rewrites it
    # (username, route); that must not quietly drop the flags it may hold,
    # or the next empty-field Connect resends a rejected saved password.
    (tmp_path / SETTINGS_FILE).write_text(content)
    store = LocalStore(tmp_path)
    store.update_settings(username="demo", route="direct")
    assert store.saved_password_rejected("demo")
    assert store.saved_password_rejected("other")
    settings = json.loads((tmp_path / SETTINGS_FILE).read_text())
    assert settings["username"] == "demo" and settings["route"] == "direct"
    # A typed password a server accepted lifts that account only, and later
    # rewrites keep both answers.
    store.set_saved_password_rejected("Demo", False)
    store.update_settings(route="jump")
    assert not store.saved_password_rejected("demo")
    assert store.saved_password_rejected("other")
    # A new rejection still counts for an account lifted before.
    store.set_saved_password_rejected("demo", True)
    assert store.saved_password_rejected("demo")


def test_unreadable_flags_in_a_readable_file_keep_failing_closed(tmp_path):
    (tmp_path / SETTINGS_FILE).write_text('{"saved_password_rejected": "demo", "route": "jump"}')
    store = LocalStore(tmp_path)
    store.update_settings(username="demo")
    settings = json.loads((tmp_path / SETTINGS_FILE).read_text())
    assert settings["route"] == "jump" and settings["username"] == "demo"
    assert store.saved_password_rejected("demo") and store.saved_password_rejected("other")


def test_a_typed_password_after_an_unreadable_file_does_not_unblock_the_saved_one(tmp_path):
    # The finding's sequence: the flag was in a file that became unreadable,
    # the user types a password (accepted, not saved); the different saved
    # password, possibly the rejected one, must stay blocked.
    vault = FakeVault({("Svc", "demo"): "old-pass"})
    guard, store = guard_with(tmp_path, vault)
    (tmp_path / SETTINGS_FILE).write_text("")
    assert guard.choose("demo", "new-pass") == ("new-pass", False)
    store.update_settings(username="demo", route="direct")
    assert guard.verified("demo", "new-pass", False, "save failed") is None
    with pytest.raises(ValueError, match="rejected"):
        guard.choose("demo", "")
    # Saving the typed password replaces the saved one and lifts the flag.
    assert guard.verified("demo", "new-pass", True, "save failed") is None
    assert guard.choose("demo", "") == ("new-pass", True)


def test_concurrent_settings_writes_lose_nothing(tmp_path):
    store = LocalStore(tmp_path)
    names = [f"user{i}" for i in range(20)]
    threads = [threading.Thread(target=store.set_saved_password_rejected, args=(n, True)) for n in names]
    threads.append(threading.Thread(target=store.update_settings, kwargs={"route": "jump"}))
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    settings = json.loads((tmp_path / SETTINGS_FILE).read_text())
    assert settings["saved_password_rejected"] == sorted(names)
    assert settings["route"] == "jump"


def test_login_module_needs_only_the_standard_library():
    # Its tests run where paramiko and PySide6 are not installed.
    source = Path(login.__file__).read_text(encoding="utf-8")
    assert "import paramiko" not in source and "PySide6" not in source
