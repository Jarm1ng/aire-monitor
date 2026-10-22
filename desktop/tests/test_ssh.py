import stat
import sys
from pathlib import Path
from unittest.mock import MagicMock

import paramiko
import pytest

from leeds_hpc_desktop.core import PROFILES
from leeds_hpc_desktop.ssh import (
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


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX permission bits")
def test_known_hosts_is_owner_only(tmp_path, key):
    verifier = HostVerifier(tmp_path / "known_hosts", MagicMock(return_value=True))
    verifier.verify("test.example", key)
    assert stat.S_IMODE(verifier.path.stat().st_mode) == 0o600


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
    authenticate(t, "test.example", "demo", "test-only", ask)
    assert ask.call_count == 1
    t.auth_password.assert_not_called()


def test_repeated_password_aborts_without_second_submission():
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
