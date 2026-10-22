import socket
import stat
import sys
import threading
import time
from pathlib import Path
from unittest.mock import MagicMock

import paramiko
import pytest

from leeds_hpc_desktop.core import PROFILES
from leeds_hpc_desktop.ssh import (
    AuthenticationRejected,
    Cancelled,
    ConnectionManager,
    DuoNotApproved,
    HostVerifier,
    PasswordExpired,
    PasswordRejected,
    Session,
    authenticate,
    fingerprint,
    prefer_key_types,
    responsive,
)


@pytest.fixture
def key():
    return paramiko.RSAKey.generate(2048)


def verifier_for(tmp_path, ask, user_lines=None):
    """A HostVerifier whose "user's own known_hosts" is a file in tmp_path
    (never the real ~/.ssh/known_hosts)."""
    user = tmp_path / "user_known_hosts"
    if user_lines is not None:
        user.write_text("".join(f"{line}\n" for line in user_lines))
    return HostVerifier(tmp_path / "known_hosts", ask, user_known_hosts=user)


def entry(host, key):
    return f"{host} {key.get_name()} {key.get_base64()}"


def test_unknown_host_refused_before_auth(tmp_path, key):
    ask = MagicMock(return_value=False)
    verifier = verifier_for(tmp_path, ask)
    with pytest.raises(Cancelled):
        verifier.verify("test.example", key)
    assert not verifier.path.exists()
    assert fingerprint(key).startswith("SHA256:")


def test_host_trust_persists_and_changed_keys_blocked(tmp_path, key):
    ask = MagicMock(return_value=True)
    verifier = verifier_for(tmp_path, ask)
    verifier.verify("test.example", key)
    verifier.verify("test.example", key)
    assert ask.call_count == 1
    with pytest.raises(paramiko.SSHException, match="HOST KEY CHANGED"):
        verifier.verify("test.example", paramiko.RSAKey.generate(2048))
    assert ask.call_count == 1


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX permission bits")
def test_known_hosts_is_owner_only(tmp_path, key):
    verifier = verifier_for(tmp_path, MagicMock(return_value=True))
    verifier.verify("test.example", key)
    assert stat.S_IMODE(verifier.path.stat().st_mode) == 0o600


@pytest.mark.parametrize("hashed", [False, True])
def test_key_in_the_users_known_hosts_is_trusted_without_a_prompt(tmp_path, key, hashed):
    host = paramiko.HostKeys.hash_host("aire.test") if hashed else "aire.test"
    lines = ["# comment", "@cert-authority *.test ssh-rsa AAAA", "broken line", entry(host, key)]
    ask = MagicMock()
    verifier = verifier_for(tmp_path, ask, lines)
    before = verifier.user_known_hosts.read_bytes()
    verifier.verify("aire.test", key)
    ask.assert_not_called()
    # Read only: the user's file is untouched, and nothing is copied over.
    assert verifier.user_known_hosts.read_bytes() == before
    assert not verifier.path.exists()


def test_key_conflicting_with_the_users_known_hosts_is_blocked(tmp_path, key):
    ask = MagicMock(return_value=True)
    verifier = verifier_for(tmp_path, ask, [entry("aire.test", paramiko.RSAKey.generate(2048))])
    with pytest.raises(paramiko.SSHException, match="HOST KEY CHANGED.*your own known_hosts"):
        verifier.verify("aire.test", key)
    ask.assert_not_called()
    assert not verifier.path.exists()


def test_app_approved_key_that_conflicts_with_the_users_file_is_blocked(tmp_path, key):
    # The app's own approval (perhaps given blindly at first use) does not
    # outweigh a different key the user's ssh trusts for the same host.
    verifier = verifier_for(tmp_path, MagicMock(return_value=True))
    verifier.verify("aire.test", key)
    verifier.user_known_hosts.write_text(entry("aire.test", paramiko.RSAKey.generate(2048)) + "\n")
    with pytest.raises(paramiko.SSHException, match="HOST KEY CHANGED"):
        verifier.verify("aire.test", key)


def test_revoked_key_in_the_users_file_is_blocked(tmp_path, key):
    ask = MagicMock(return_value=True)
    verifier = verifier_for(tmp_path, ask, ["@revoked " + entry("aire.test", key)])
    with pytest.raises(paramiko.SSHException, match="revoked"):
        verifier.verify("aire.test", key)
    ask.assert_not_called()


def test_other_key_type_in_the_users_file_still_needs_approval(tmp_path, key):
    ask = MagicMock(return_value=True)
    verifier = verifier_for(tmp_path, ask, [entry("aire.test", paramiko.ECDSAKey.generate())])
    verifier.verify("aire.test", key)
    ask.assert_called_once()
    assert "different type of key" in ask.call_args.args[2]
    assert verifier.path.exists()


def test_missing_or_unreadable_users_file_falls_back_to_the_prompt(tmp_path, key):
    ask = MagicMock(return_value=True)
    verifier = HostVerifier(tmp_path / "known_hosts", ask, user_known_hosts=tmp_path / "missing")
    verifier.verify("aire.test", key)
    ask.assert_called_once()
    folder = tmp_path / "folder"
    folder.mkdir()
    ask = MagicMock(return_value=True)
    HostVerifier(tmp_path / "other_known_hosts", ask, user_known_hosts=folder).verify("aire.test", key)
    ask.assert_called_once()


def test_known_key_types_are_asked_for_first(tmp_path, key):
    ecdsa = paramiko.ECDSAKey.generate()
    verifier = verifier_for(tmp_path, MagicMock(return_value=True), [entry("aire.test", key)])
    # The user's file knows an RSA key: ask for it by its SHA-2 names first.
    assert verifier.preferred_key_types("aire.test")[:2] == ["rsa-sha2-512", "rsa-sha2-256"]
    assert verifier.preferred_key_types("calder.test") == []
    # The app's own file, once it knows the host, decides.
    verifier.verify("calder.test", ecdsa)
    assert verifier.preferred_key_types("calder.test") == [ecdsa.get_name()]
    left, right = socket.socketpair()
    try:
        t = paramiko.Transport(left)
        prefer_key_types(t, [ecdsa.get_name(), "not-a-key-type"])
        assert t.get_security_options().key_types[0] == ecdsa.get_name()
        t.close()
    finally:
        left.close()
        right.close()


def transport(methods):
    t = MagicMock()
    t.auth_none.side_effect = paramiko.BadAuthenticationType("methods", methods)
    t.is_authenticated.return_value = False
    return t


# Duo prompt wordings seen from pam_duo versions.
@pytest.mark.parametrize(
    "instructions,prompt",
    [("Pick an option", "Passcode or option:"), ("Choose an option", "Passcode or option (1-1):")],
)
def test_interactive_password_once_then_duo(instructions, prompt):
    t = transport(["keyboard-interactive"])
    ask = MagicMock(return_value="1")

    def interactive(username, callback):
        assert callback("", "", [("Password:", False)]) == ["test-only"]
        assert callback("Duo", instructions, [(prompt, True)]) == ["1"]
        t.is_authenticated.return_value = True

    t.auth_interactive.side_effect = interactive
    # True: the password was sent and the server accepted it.
    assert authenticate(t, "test.example", "demo", "test-only", ask) is True
    assert ask.call_count == 1
    t.auth_password.assert_not_called()


WARNED_DUO = "Your password will expire in 5 day(s).\nDuo two-factor login\n\nPasscode or option (1-1): "


def test_duo_prompt_carrying_an_expiry_warning_is_not_a_second_password_request():
    t = transport(["keyboard-interactive"])
    ask = MagicMock(return_value="1")

    def interactive(username, callback):
        assert callback("", "", [("Password:", False)]) == ["test-only"]
        assert callback("", "", [(WARNED_DUO, True)]) == ["1"]
        t.is_authenticated.return_value = True

    t.auth_interactive.side_effect = interactive
    assert authenticate(t, "test.example", "demo", "test-only", ask)
    assert "will expire" in ask.call_args.args[2][2]


def test_password_change_prompt_is_refused_and_answered_with_nothing():
    t = transport(["keyboard-interactive"])
    ask = MagicMock(return_value="anything")
    answers = []

    def interactive(username, callback):
        answers.append(callback("", "", [("Password:", False)]))
        answers.append(
            callback("", "", [("Password expired. Change your password now.\nCurrent Password: ", False)])
        )

    t.auth_interactive.side_effect = interactive
    with pytest.raises(PasswordExpired):
        authenticate(t, "test.example", "demo", "test-only", ask)
    assert answers == [["test-only"]]
    ask.assert_not_called()


def test_refusal_says_whether_the_password_or_duo_failed():
    t = transport(["keyboard-interactive"])

    def wrong_password(username, callback):
        callback("", "", [("Password:", False)])
        raise paramiko.AuthenticationException("failed")

    t.auth_interactive.side_effect = wrong_password
    with pytest.raises(PasswordRejected):
        authenticate(t, "test.example", "demo", "test-only", MagicMock())

    t = transport(["keyboard-interactive"])

    def duo_declined(username, callback):
        callback("", "", [("Password:", False)])
        callback("", "", [("Passcode or option (1-1): ", True)])
        raise paramiko.AuthenticationException("failed")

    t.auth_interactive.side_effect = duo_declined
    with pytest.raises(DuoNotApproved):
        authenticate(t, "test.example", "demo", "test-only", MagicMock(return_value="1"))


def test_no_password_reference_is_left_after_sign_in():
    # paramiko keeps the interactive handler, and auth_password's copy on
    # its AuthHandler, for the whole life of the connection.
    t = transport(["keyboard-interactive"])
    handlers = []

    def interactive(username, callback):
        handlers.append(callback)
        callback("", "", [("Password:", False)])
        t.is_authenticated.return_value = True

    t.auth_interactive.side_effect = interactive
    authenticate(t, "test.example", "demo", "test-only", MagicMock())
    assert "test-only" not in vars(handlers[0]).values()

    t = transport(["password"])

    def password(username, secret, fallback):
        t.auth_handler.password = secret
        t.is_authenticated.return_value = True
        return []

    t.auth_password.side_effect = password
    assert authenticate(t, "test.example", "demo", "test-only", MagicMock())
    assert t.auth_handler.password is None


def test_sign_in_without_the_password_is_not_a_verification():
    t = MagicMock()
    t.is_authenticated.return_value = True
    assert authenticate(t, "test.example", "demo", "test-only", MagicMock()) is False


def test_repeated_password_aborts_without_second_submission():
    t = transport(["keyboard-interactive"])

    def interactive(username, callback):
        callback("", "", [("Password:", False)])
        callback("", "", [("Password:", False)])

    t.auth_interactive.side_effect = interactive
    with pytest.raises(AuthenticationRejected, match="requested the password again"):
        authenticate(t, "test.example", "demo", "test-only", MagicMock())
    assert t.auth_interactive.call_count == 1


def test_rejected_password_not_retried():
    t = transport(["password", "keyboard-interactive"])
    t.auth_interactive.side_effect = paramiko.AuthenticationException("rejected")
    with pytest.raises(AuthenticationRejected):
        authenticate(t, "test.example", "demo", "test-only", MagicMock())
    assert t.auth_interactive.call_count == 1
    t.auth_password.assert_not_called()


def test_password_then_partial_interactive_mfa():
    t = transport(["password"])
    t.auth_password.return_value = ["keyboard-interactive"]

    def interactive(username, callback):
        assert callback("Duo", "", [("Passcode:", False)]) == ["123456"]
        t.is_authenticated.return_value = True

    t.auth_interactive.side_effect = interactive
    authenticate(t, "test.example", "demo", "test-only", MagicMock(return_value="123456"))
    t.auth_password.assert_called_once_with("demo", "test-only", fallback=False)


def test_cancelled_duo():
    t = transport(["keyboard-interactive"])
    t.auth_interactive.side_effect = lambda username, callback: callback("", "", [("Duo:", False)])
    with pytest.raises(Cancelled):
        authenticate(t, "test.example", "demo", "test-only", MagicMock(return_value=None))


def test_jump_reused_for_both_clusters_and_target_failure_preserves_it():
    manager = ConnectionManager(MagicMock(), MagicMock())
    jump, aire, calder = MagicMock(), MagicMock(), MagicMock()
    manager._open = MagicMock(side_effect=[(jump, True), (aire, True), (calder, True)])
    first, verified = manager.connect(PROFILES[0], "demo", "test-only", "jump")
    second, _ = manager.connect(PROFILES[1], "demo", "test-only", "jump")
    assert verified
    assert first.transport == aire
    assert second.transport == calder
    assert manager._open.call_count == 3
    assert jump.open_channel.call_count == 2
    # A live session is reused, and reusing it sends (so proves) nothing.
    assert manager.connect(PROFILES[0], "demo", "test-only", "jump") == (first, False)
    assert manager._open.call_count == 3
    calder.is_active.return_value = False
    manager._open.side_effect = OSError("target refused")
    with pytest.raises(OSError):
        manager.connect(PROFILES[1], "demo", "test-only", "jump")
    assert manager.jump is jump
    assert first.connected
    jump.close.assert_not_called()
    manager.disconnect()
    jump.close.assert_called_once()


def test_account_route_change_requires_disconnect():
    manager = ConnectionManager(MagicMock(), MagicMock())
    manager._open = MagicMock(return_value=(MagicMock(), True))
    manager.connect(PROFILES[0], "demo", "test-only", "direct")
    with pytest.raises(ValueError):
        manager.connect(PROFILES[1], "other", "test-only", "direct")
    with pytest.raises(ValueError):
        manager.connect(PROFILES[1], "demo", "test-only", "jump")
    assert manager.signed_in()


def test_failed_sign_in_does_not_pin_the_account_or_route():
    # Off VPN, "Direct" times out; switching to rash (the documented fix)
    # or correcting the username must then just work, without Disconnect.
    manager = ConnectionManager(MagicMock(), MagicMock())
    manager._open = MagicMock(side_effect=OSError("timed out"))
    with pytest.raises(OSError):
        manager.connect(PROFILES[0], "demo", "test-only", "direct")
    assert not manager.signed_in()
    jump, aire = MagicMock(), MagicMock()
    manager._open = MagicMock(side_effect=[(jump, True), (aire, True)])
    session, _ = manager.connect(PROFILES[0], "demo", "test-only", "jump")
    assert session.transport is aire
    assert manager.route == "jump"


def test_lost_links_release_the_account():
    manager = ConnectionManager(MagicMock(), MagicMock())
    old = MagicMock()
    manager._open = MagicMock(return_value=(old, True))
    manager.connect(PROFILES[0], "demo", "test-only", "direct")
    old.is_active.return_value = False
    manager._open = MagicMock(return_value=(MagicMock(), True))
    session, _ = manager.connect(PROFILES[0], "other", "test-only", "direct")
    assert manager.username == "other"
    old.close.assert_called()
    assert manager.sessions == {"aire": session}


def test_silent_session_is_replaced_not_reused():
    # Looks connected (paramiko's keepalives want no reply) but the server
    # no longer answers: a VPN expiry or a suspend.
    manager = ConnectionManager(MagicMock(), MagicMock())
    dead, fresh = MagicMock(), MagicMock()
    dead.global_request.side_effect = lambda *args, **kwargs: time.sleep(5)
    manager._open = MagicMock(side_effect=[(dead, True), (fresh, True)])
    manager.connect(PROFILES[0], "demo", "test-only", "direct")
    with pytest.MonkeyPatch.context() as patch:
        patch.setattr("leeds_hpc_desktop.ssh.PROBE_TIMEOUT", 0.2)
        session, verified = manager.connect(PROFILES[0], "demo", "test-only", "direct")
    assert session.transport is fresh and verified
    dead.close.assert_called()


def test_disconnect_cancels_a_sign_in_without_waiting_for_it():
    manager = ConnectionManager(MagicMock(), MagicMock())
    started, release = threading.Event(), threading.Event()
    transport = MagicMock()

    def slow_open(host, username, password, generation, sock=None):
        # Stands in for a Duo approval nobody gives.
        started.set()
        release.wait(5)
        manager._check_current(generation)
        return transport, True

    manager._open = slow_open
    errors = []

    def sign_in():
        try:
            manager.connect(PROFILES[0], "demo", "test-only", "direct")
        except Exception as exc:
            errors.append(exc)

    worker = threading.Thread(target=sign_in)
    worker.start()
    assert started.wait(5)
    began = time.monotonic()
    manager.disconnect()
    # disconnect() never waits on the sign-in lock.
    assert time.monotonic() - began < 1
    release.set()
    worker.join(5)
    assert len(errors) == 1 and isinstance(errors[0], Cancelled)
    assert manager.sessions == {}
    assert manager.username is None and manager.route is None


def test_session_opened_after_a_disconnect_is_not_kept():
    manager = ConnectionManager(MagicMock(), MagicMock())
    transport = MagicMock()

    def open_then_disconnected(host, username, password, generation, sock=None):
        manager.disconnect()
        return transport, True

    manager._open = open_then_disconnected
    with pytest.raises(Cancelled):
        manager.connect(PROFILES[0], "demo", "test-only", "direct")
    transport.close.assert_called()
    assert manager.sessions == {}


def test_disconnect_closes_rash_first_and_any_sign_in_in_progress():
    manager = ConnectionManager(MagicMock(), MagicMock())
    order = []
    jump, aire, opening = MagicMock(), MagicMock(), MagicMock()
    jump.close.side_effect = lambda: order.append("jump")
    aire.close.side_effect = lambda: order.append("aire")
    opening.close.side_effect = lambda: order.append("opening")
    manager._open = MagicMock(side_effect=[(jump, True), (aire, True)])
    manager.connect(PROFILES[0], "demo", "test-only", "jump")
    manager.opening.add(opening)
    manager.disconnect()
    assert order == ["jump", "opening", "aire"]
    assert not manager.signed_in()


def fake_network(monkeypatch, transport):
    monkeypatch.setattr("leeds_hpc_desktop.ssh.socket.create_connection", lambda *args, **kwargs: MagicMock())
    monkeypatch.setattr("leeds_hpc_desktop.ssh.paramiko.Transport", lambda sock: transport)


def test_open_signs_in_and_reports_whether_the_password_was_verified(monkeypatch):
    manager = ConnectionManager(MagicMock(), MagicMock())
    manager.verifier.preferred_key_types.return_value = []
    transport = MagicMock()
    fake_network(monkeypatch, transport)
    monkeypatch.setattr("leeds_hpc_desktop.ssh.authenticate", lambda *args: True)
    session, verified = manager.connect(PROFILES[0], "demo", "test-only", "direct")
    assert session.transport is transport and verified
    manager.verifier.verify.assert_called_once()
    transport.set_keepalive.assert_called_once_with(30)
    assert manager.opening == set()


def test_sign_in_ended_by_disconnect_is_a_cancel_not_a_rejection(monkeypatch):
    # Closing the transport under a sign-in looks like a failed
    # authentication to paramiko; it must not count against the password.
    manager = ConnectionManager(MagicMock(), MagicMock())
    manager.verifier.preferred_key_types.return_value = []
    transport = MagicMock()
    fake_network(monkeypatch, transport)

    def closed_under_it(*args):
        manager.disconnect()
        raise PasswordRejected("looks like a wrong password")

    monkeypatch.setattr("leeds_hpc_desktop.ssh.authenticate", closed_under_it)
    with pytest.raises(Cancelled):
        manager.connect(PROFILES[0], "demo", "test-only", "direct")
    transport.close.assert_called()

    def refused(*args):
        raise PasswordRejected("wrong password")

    monkeypatch.setattr("leeds_hpc_desktop.ssh.authenticate", refused)
    with pytest.raises(PasswordRejected):
        manager.connect(PROFILES[0], "demo", "test-only", "direct")


def test_responsive_needs_a_reply_within_the_timeout():
    t = MagicMock()
    assert responsive(t, 1)
    t.global_request.assert_called_once_with("keepalive@openssh.com", wait=True)
    silent = MagicMock()
    silent.global_request.side_effect = lambda *args, **kwargs: time.sleep(5)
    began = time.monotonic()
    assert not responsive(silent, 0.2)
    assert time.monotonic() - began < 2
    inactive = MagicMock()
    inactive.is_active.return_value = False
    assert not responsive(inactive, 1)
    inactive.global_request.assert_not_called()


def section(name, body="", status=0):
    return f"\n=====HPC-SECTION:{name}=====\n{body}\n=====HPC-STATUS:{name}:{status}=====\n"


HEAD = (
    section("remote", "fake-login|demo|/users/demo|2026-10-15T12:00:00Z")
    + section("partitions", "gpu|up|1|mix|gpu:l40s:3|48|512000|none|2-00:00:00")
    + section("nodes", "gpu001|gpu|mix|8/40/0/48|512000|gpu:l40s:3|none|none")
)
JOBS = section("jobs", "123|gpu|test-job|demo|RUNNING|1:00|2:00:00|1|gpu001") + section("job_details")
NODE_RECORD = "NodeName=gpu001 Gres=gpu:l40s:3 CfgTRES=cpu=48,gres/gpu=3 AllocTRES=cpu=8,gres/gpu=1"
NODE_DETAILS = section("node_details", NODE_RECORD)
STORAGE = section("storage")


class FakeChannel:
    """A paramiko Channel stand-in for Session._run. Each poll of
    recv_ready() delivers the next item of `arrivals` (None: nothing arrived
    by then); EOF follows the last item when `eof` is set. The exit status is
    ready from the start with status_first (OpenSSH may send it before the
    last data), otherwise once EOF has arrived."""

    def __init__(self, arrivals, *, exit_status=0, status_first=False, eof=True, stderr=b""):
        self.arrivals = [item.encode() if isinstance(item, str) else item for item in arrivals]
        self.buffer = bytearray()
        self.stderr = bytearray(stderr)
        self.exit_status = exit_status
        self.status_first = status_first
        self.eof = eof
        self.eof_received = False
        self.closed = False
        self.script = b""
        self.commands = []

    def settimeout(self, timeout):
        pass

    def exec_command(self, command):
        self.commands.append(command)

    def sendall(self, data):
        self.script += data

    def shutdown_write(self):
        pass

    def recv_ready(self):
        if self.arrivals:
            item = self.arrivals.pop(0)
            if item:
                self.buffer.extend(item)
        elif self.eof:
            self.eof_received = True
        return bool(self.buffer)

    def recv(self, size):
        data = bytes(self.buffer[:size])
        del self.buffer[:size]
        return data

    def recv_stderr_ready(self):
        return bool(self.stderr)

    def recv_stderr(self, size):
        data = bytes(self.stderr[:size])
        del self.stderr[:size]
        return data

    def exit_status_ready(self):
        return self.status_first or self.eof_received or self.closed

    def recv_exit_status(self):
        return self.exit_status

    def close(self):
        self.closed = True


def session_with(*channels):
    t = MagicMock()
    t.open_session.side_effect = list(channels)
    return Session(PROFILES[0], t), t


def test_collect_reads_past_an_early_exit_status():
    # The exit status is there before the storage section: stopping at it
    # (instead of at EOF) would lose node_details' tail and storage.
    channel = FakeChannel([HEAD + JOBS, None, None, NODE_DETAILS, None, STORAGE], status_first=True)
    session, _ = session_with(channel)
    snapshot = session.collect("demo")
    assert snapshot["errors"] == []
    assert snapshot["storage"] is not None
    assert not any("missing" in warning for warning in snapshot["warnings"])
    assert snapshot["nodes"][0]["gpu_idle"] == 2
    assert channel.commands == ["sh -s"]
    assert b"section storage" in channel.script
    assert channel.closed


def test_collect_drains_stderr():
    channel = FakeChannel([HEAD + JOBS + NODE_DETAILS + STORAGE], stderr=b"warning\n" * 20000)
    session, _ = session_with(channel)
    assert session.collect("demo")["errors"] == []
    assert channel.stderr == bytearray()


def test_cut_record_on_timeout_is_unknown_not_idle():
    # The budget ends inside the node record: the fragment must not read as
    # "no GPUs allocated" (all three idle).
    channel = FakeChannel(
        [HEAD + JOBS + "\n=====HPC-SECTION:node_details=====\n" + NODE_RECORD[:-12]], eof=False
    )
    session, _ = session_with(channel)
    snapshot = session.collect("demo", budget=1)
    assert snapshot["errors"] == []
    assert snapshot["nodes"][0]["gpu_allocated"] is None
    assert snapshot["nodes"][0]["gpu_idle"] is None
    assert any(
        "Timed out after 1s" in warning and "cut during node_details" in warning
        for warning in snapshot["warnings"]
    )
    assert channel.closed


def test_unusable_json_runs_the_fallback_on_a_second_channel():
    main = FakeChannel([HEAD + section("jobs_json", '{"jobs": [1]}') + NODE_DETAILS + STORAGE])
    fallback = FakeChannel([JOBS])
    session, t = session_with(main, fallback)
    snapshot = session.collect("demo")
    assert snapshot["errors"] == []
    assert [job["job_id"] for job in snapshot["jobs"]] == ["123"]
    assert any("pipe-format fallback" in warning for warning in snapshot["warnings"])
    assert t.open_session.call_count == 2
    assert fallback.commands == ["sh -s"]
    assert b"# hpc-round-trip: jobs-fallback" in fallback.script
    assert "jobs_fallback_round_trip" in snapshot["timings"]


def test_skip_storage_leaves_out_the_storage_commands():
    channel = FakeChannel([HEAD + JOBS + NODE_DETAILS])
    session, _ = session_with(channel)
    snapshot = session.collect("demo", skip_storage=True)
    assert b"section storage" not in channel.script
    assert snapshot["errors"] == []
    assert snapshot["storage"] is None
    assert snapshot["storage_skipped"] is True


def test_dead_link_is_closed_when_a_channel_cannot_be_opened():
    session, t = session_with()
    t.open_session.side_effect = paramiko.SSHException("Timeout opening channel.")
    with pytest.raises(ConnectionError, match="stopped responding"):
        session.collect("demo")
    t.close.assert_called_once()


def test_refused_channel_keeps_the_connection():
    # The server answered (too many sessions, say): the link works.
    session, t = session_with()
    t.open_session.side_effect = paramiko.ChannelException(2, "Connect failed")
    with pytest.raises(paramiko.ChannelException):
        session.collect("demo")
    t.close.assert_not_called()


def test_stuck_exec_request_is_ended_by_closing_its_channel(monkeypatch):
    # exec_command has no timeout: a link that dies after the channel opened
    # would otherwise hold the refresh (and the cluster's busy mark) for good.
    monkeypatch.setattr("leeds_hpc_desktop.ssh.CHANNEL_GRACE", 0.2)
    channel = FakeChannel([])

    def exec_command(command):
        while not channel.closed:
            time.sleep(0.01)
        raise paramiko.SSHException("Channel closed.")

    channel.exec_command = exec_command
    session, t = session_with(channel)
    began = time.monotonic()
    with pytest.raises(paramiko.SSHException):
        session._run("true", 0.3)
    assert time.monotonic() - began < 3
    t.close.assert_not_called()


def test_empty_output_is_a_refresh_error():
    channel = FakeChannel([])
    session, _ = session_with(channel)
    result = session.collect("demo")
    assert "no sections" in result["errors"][0]
    assert channel.commands == ["sh -s"]
    assert channel.closed


@pytest.mark.parametrize(
    "status,message",
    [(2, "exited with status 2"), (-1, "closed before the snapshot command reported its exit status")],
)
def test_failed_command_is_a_refresh_error(status, message):
    session, _ = session_with(FakeChannel([HEAD + JOBS + NODE_DETAILS + STORAGE], exit_status=status))
    assert message in session.collect("demo")["errors"][0]


@pytest.mark.parametrize("tail", [False, True])
def test_file_preview_read_only_and_bounded(monkeypatch, tail):
    sftp = MagicMock()
    remote = sftp.open.return_value.__enter__.return_value
    remote.stat.return_value.st_size = 500000
    remote.read.return_value = b"hello\n"
    monkeypatch.setattr(paramiko.SFTPClient, "from_transport", lambda t: sftp)
    result = Session(PROFILES[0], MagicMock()).preview("/users/demo/a; touch x", tail)
    sftp.open.assert_called_once_with("/users/demo/a; touch x", "rb")
    remote.read.assert_called_once_with(128 * 1024)
    if tail:
        remote.seek.assert_called_once_with(500000 - 128 * 1024)
    assert "hello" in result
    sftp.close.assert_called_once()


def test_links_are_followed_to_decide_folder_or_file(monkeypatch):
    sftp = MagicMock()
    sftp.stat.return_value.st_mode = stat.S_IFDIR | 0o755
    monkeypatch.setattr(paramiko.SFTPClient, "from_transport", lambda t: sftp)
    session = Session(PROFILES[0], MagicMock())
    assert session.is_directory("/users/demo/scratch")
    # stat follows the link; lstat (what the listing has) would not.
    sftp.stat.assert_called_once_with("/users/demo/scratch")
    sftp.lstat.assert_not_called()
    sftp.close.assert_called_once()
    sftp.stat.return_value.st_mode = stat.S_IFREG | 0o644
    assert not session.is_directory("/users/demo/link-to-file")


def test_binary_preview(monkeypatch):
    sftp = MagicMock()
    remote = sftp.open.return_value.__enter__.return_value
    remote.stat.return_value.st_size = 3
    remote.read.return_value = b"a\0b"
    monkeypatch.setattr(paramiko.SFTPClient, "from_transport", lambda t: sftp)
    assert "Binary" in Session(PROFILES[0], MagicMock()).preview("x")


def test_no_password_in_local_files(tmp_path, key):
    verifier = verifier_for(tmp_path, MagicMock(return_value=True))
    verifier.verify("test.example", key)
    assert "test-only" not in "".join(p.read_text() for p in Path(tmp_path).iterdir())
