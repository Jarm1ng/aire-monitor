"""Real SSH encryption/auth/channel tests on loopback, never on Leeds hosts."""

import socket
import threading
from contextlib import contextmanager

import paramiko
import pytest

from aire_windows.core import PROFILES
from aire_windows.ssh import AuthenticationRejected, HostVerifier, Session, authenticate


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


class Server(paramiko.ServerInterface):
    def __init__(self, reject=False):
        self.reject = reject
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
            return paramiko.InteractiveQuery("Duo", "Choose push", ("Passcode or option:", True))
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
def ssh_server(reject=False):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(10)
    server = Server(reject)
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
                channel.sendall(OUTPUT.encode())
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


def test_real_ssh_duo_and_shared_collector(tmp_path):
    prompts = []

    def ask(kind, host, content):
        prompts.append((kind, host))
        return True if kind == "host" else "1"

    with ssh_server() as (client, server):
        HostVerifier(tmp_path / "known_hosts", ask).verify("loopback.test", client.get_remote_server_key())
        authenticate(client, "loopback.test", "demo", "test-only", ask)
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


def test_real_ssh_wrong_password_no_retry():
    with ssh_server(reject=True) as (client, server):
        with pytest.raises(AuthenticationRejected):
            authenticate(client, "loopback.test", "demo", "test-only", lambda *args: "1")
        assert server.passwords == ["test-only"]
        assert server.commands == []
