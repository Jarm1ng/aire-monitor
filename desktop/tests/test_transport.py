"""Real SSH encryption/auth/channel tests on loopback, never on Leeds hosts."""

import socket
import threading
from contextlib import contextmanager

import paramiko
import pytest

from leeds_hpc_desktop.core import PROFILES
from leeds_hpc_desktop.ssh import (
    HostVerifier,
    PasswordExpired,
    PasswordRejected,
    Session,
    authenticate,
    responsive,
)


def section(name, body="", status=0):
    return f"\n=====HPC-SECTION:{name}=====\n{body}\n=====HPC-STATUS:{name}:{status}=====\n"


OUTPUT = (
    section("remote", "fake-login|demo|/users/demo|2026-10-15T12:00:00Z")
    + section("jobs", "123|gpu|test-job|demo|RUNNING|1:00|2:00:00|1|gpu001")
    + section("partitions", "gpu|up|1|mix|gpu:l40s:3|48|512000|none|2-00:00:00")
    + section("nodes", "gpu001|gpu|mix|8/40/0/48|512000|gpu:l40s:3|none|none")
    + section("job_details")
    + section(
        "node_details", "NodeName=gpu001 Gres=gpu:l40s:3 CfgTRES=cpu=48,gres/gpu=3 AllocTRES=cpu=8,gres/gpu=1"
    )
    + section("storage")
)


DUO_PROMPT = "Passcode or option:"
# What OpenSSH sends while an AD password nears expiry: pam_sss's warning in
# front of pam_duo's prompt.
WARNED_DUO_PROMPT = "Your password will expire in 5 day(s).\nPasscode or option (1-1): "
CHANGE_PROMPT = "Password expired. Change your password now.\nCurrent Password: "


class Server(paramiko.ServerInterface):
    def __init__(self, reject=False, status_first=False, second_prompt=DUO_PROMPT):
        self.reject = reject
        # Send exit-status before the output, as OpenSSH may when the
        # command exits with data still in its pipe.
        self.status_first = status_first
        # What follows an accepted password: Duo, or a password change.
        self.second_prompt = second_prompt
        self.later_responses = []
        self.stage = 0
        self.passwords = []
        self.commands = []
        self.execute = threading.Event()
        self.script = b""

    def get_allowed_auths(self, username):
        return "keyboard-interactive"

    def check_auth_interactive(self, username, submethods):
        return paramiko.InteractiveQuery("Login", "", ("Password:", False))

    def check_auth_interactive_response(self, responses):
        if self.stage == 0:
            self.passwords.extend(responses)
            if self.reject or responses != ["test-only"]:
                return paramiko.AUTH_FAILED
            self.stage += 1
            return paramiko.InteractiveQuery("Duo", "Choose push", (self.second_prompt, True))
        self.later_responses.extend(responses)
        return paramiko.AUTH_SUCCESSFUL if responses == ["1"] else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, channel_id):
        return (
            paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        )

    def check_channel_exec_request(self, channel, command):
        self.commands.append(command)
        self.execute.set()
        return True


@contextmanager
def ssh_server(reject=False, status_first=False, second_prompt=DUO_PROMPT):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(10)
    server = Server(reject, status_first, second_prompt)
    transports = []
    errors = []

    def run():
        try:
            conn, _ = listener.accept()
            t = paramiko.Transport(conn)
            transports.append(t)
            t.add_server_key(paramiko.RSAKey.generate(2048))
            t.start_server(server=server)
            channel = t.accept(5)
            if channel and server.execute.wait(5):
                while True:
                    data = channel.recv(65536)
                    if not data:
                        break
                    server.script += data
                if server.status_first:
                    channel.send_exit_status(0)
                channel.sendall(OUTPUT.encode())
                if not server.status_first:
                    channel.send_exit_status(0)
                channel.close()
        except (EOFError, OSError):
            pass
        except Exception as exc:
            errors.append(exc)

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    client = paramiko.Transport(socket.create_connection(listener.getsockname(), timeout=5))
    client.auth_timeout = 5
    client.start_client(timeout=5)
    try:
        yield client, server
    finally:
        client.close()
        for t in transports:
            t.close()
        listener.close()
        thread.join(6)
        assert not errors


def verifier(tmp_path, ask):
    # Never the real ~/.ssh/known_hosts.
    return HostVerifier(tmp_path / "known_hosts", ask, user_known_hosts=tmp_path / "user_known_hosts")


def test_real_ssh_duo_and_shared_collector(tmp_path):
    prompts = []

    def ask(kind, host, content):
        prompts.append((kind, host))
        return True if kind == "host" else "1"

    with ssh_server() as (client, server):
        verifier(tmp_path, ask).verify("loopback.test", client.get_remote_server_key())
        assert authenticate(client, "loopback.test", "demo", "test-only", ask) is True
        snapshot = Session(PROFILES[0], client).collect("demo")
        assert snapshot["errors"] == []
        assert snapshot["remote"]["user"] == "demo"
        assert snapshot["jobs"][0]["job_id"] == "123"
        assert snapshot["nodes"][0]["gpu_idle"] == 2
        assert server.passwords == ["test-only"]
        assert server.commands == [b"sh -s"]
        assert b"squeue" in server.script
        assert b"test-only" not in server.script
        assert prompts == [("host", "loopback.test"), ("challenge", "loopback.test")]


def test_real_ssh_output_after_exit_status_is_kept(tmp_path):
    def ask(kind, host, content):
        return True if kind == "host" else "1"

    with ssh_server(status_first=True) as (client, server):
        verifier(tmp_path, ask).verify("loopback.test", client.get_remote_server_key())
        authenticate(client, "loopback.test", "demo", "test-only", ask)
        snapshot = Session(PROFILES[0], client).collect("demo")
        assert snapshot["errors"] == []
        # Reading stopped at EOF, not at the exit status: the whole output,
        # storage section included, arrived.
        assert snapshot["storage"] is not None
        assert not any("missing" in warning for warning in snapshot["warnings"])
        assert snapshot["nodes"][0]["gpu_idle"] == 2


def test_real_ssh_wrong_password_no_retry():
    with ssh_server(reject=True) as (client, server):
        with pytest.raises(PasswordRejected):
            authenticate(client, "loopback.test", "demo", "test-only", lambda *args: "1")
        assert server.passwords == ["test-only"]
        assert server.commands == []


def test_real_ssh_duo_prompt_with_expiry_warning_reaches_the_user():
    shown = []

    def ask(kind, host, content):
        shown.append(content)
        return "1"

    with ssh_server(second_prompt=WARNED_DUO_PROMPT) as (client, server):
        assert authenticate(client, "loopback.test", "demo", "test-only", ask)
        assert client.is_authenticated()
        # The password went once; the warned Duo prompt went to the user.
        assert server.passwords == ["test-only"]
        assert server.later_responses == ["1"]
        assert "will expire in 5 day(s)" in shown[0][2]


def test_real_ssh_password_change_is_refused_with_nothing_sent():
    ask_calls = []
    with ssh_server(second_prompt=CHANGE_PROMPT) as (client, server):
        with pytest.raises(PasswordExpired):
            authenticate(client, "loopback.test", "demo", "test-only", lambda *args: ask_calls.append(args))
        assert server.passwords == ["test-only"]
        assert server.later_responses == []
        assert ask_calls == []


def test_real_ssh_liveness_probe_gets_a_reply():
    with ssh_server() as (client, server):
        authenticate(client, "loopback.test", "demo", "test-only", lambda *args: "1")
        # paramiko's server refuses unknown global requests, as OpenSSH does
        # for keepalive@openssh.com: a reply all the same.
        assert responsive(client, 5)
        client.close()
        assert not responsive(client, 1)
