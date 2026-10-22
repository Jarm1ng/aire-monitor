from pathlib import Path
from unittest.mock import MagicMock

import paramiko
import pytest

from aire_linux.core import PROFILES
from aire_linux.ssh import (
    AuthenticationRejected,
    Cancelled,
    ConnectionManager,
    HostVerifier,
    Session,
    authenticate,
    fingerprint,
)


@pytest.fixture
def key():
    return paramiko.RSAKey.generate(2048)


def test_unknown_host_refused_before_auth(tmp_path, key):
    ask = MagicMock(return_value=False)
    verifier = HostVerifier(tmp_path / "known_hosts", ask)
    with pytest.raises(Cancelled):
        verifier.verify("test.example", key)
    assert not verifier.path.exists()
    assert fingerprint(key).startswith("SHA256:")


def test_host_trust_persists_and_changed_keys_blocked(tmp_path, key):
    ask = MagicMock(return_value=True)
    verifier = HostVerifier(tmp_path / "known_hosts", ask)
    verifier.verify("test.example", key)
    verifier.verify("test.example", key)
    assert ask.call_count == 1
    with pytest.raises(paramiko.SSHException, match="HOST KEY CHANGED"):
        verifier.verify("test.example", paramiko.RSAKey.generate(2048))
    assert ask.call_count == 1


def transport(methods):
    t = MagicMock()
    t.auth_none.side_effect = paramiko.BadAuthenticationType("methods", methods)
    t.is_authenticated.return_value = False
    return t


def test_interactive_password_once_then_duo():
    t = transport(["keyboard-interactive"])
    ask = MagicMock(return_value="1")

    def interactive(username, callback):
        assert callback("", "", [("Password:", False)]) == ["test-only"]
        assert callback("Duo", "Choose an option", [("Passcode or option (1-1):", True)]) == ["1"]
        t.is_authenticated.return_value = True

    t.auth_interactive.side_effect = interactive
    authenticate(t, "test.example", "demo", "test-only", ask)
    ask.assert_called_once()


def test_second_password_prompt_rejected():
    t = transport(["keyboard-interactive"])

    def interactive(username, callback):
        callback("", "", [("Password:", False)])
        callback("", "", [("Password:", False)])

    t.auth_interactive.side_effect = interactive
    with pytest.raises(AuthenticationRejected, match="requested again"):
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
    manager._open = MagicMock(side_effect=[jump, aire, calder])
    first = manager.connect(PROFILES[0], "demo", "test-only", "jump")
    second = manager.connect(PROFILES[1], "demo", "test-only", "jump")
    assert first.transport == aire
    assert second.transport == calder
    assert manager._open.call_count == 3
    assert jump.open_channel.call_count == 2
    assert manager.connect(PROFILES[0], "demo", "test-only", "jump") is first
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
    manager._open = MagicMock(return_value=MagicMock())
    manager.connect(PROFILES[0], "demo", "test-only", "direct")
    with pytest.raises(ValueError):
        manager.connect(PROFILES[1], "other", "test-only", "direct")
    with pytest.raises(ValueError):
        manager.connect(PROFILES[1], "demo", "test-only", "jump")


def test_empty_output_is_a_refresh_error():
    t = MagicMock()
    channel = t.open_session.return_value
    channel.recv_ready.return_value = False
    channel.exit_status_ready.return_value = True
    channel.recv_exit_status.return_value = 0
    result = Session(PROFILES[0], t).collect("demo")
    assert "empty snapshot" in result["errors"][0]
    channel.exec_command.assert_called_once_with("sh -s")
    channel.close.assert_called_once()


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


def test_binary_preview(monkeypatch):
    sftp = MagicMock()
    remote = sftp.open.return_value.__enter__.return_value
    remote.stat.return_value.st_size = 3
    remote.read.return_value = b"a\0b"
    monkeypatch.setattr(paramiko.SFTPClient, "from_transport", lambda t: sftp)
    assert "Binary" in Session(PROFILES[0], MagicMock()).preview("x")


def test_no_password_in_local_files(tmp_path, key):
    verifier = HostVerifier(tmp_path / "known_hosts", MagicMock(return_value=True))
    verifier.verify("test.example", key)
    assert "test-only" not in "".join(p.read_text() for p in Path(tmp_path).iterdir())
