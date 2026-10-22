from __future__ import annotations

import base64
import hashlib
import socket
import stat
import threading
import time
from dataclasses import asdict
from pathlib import Path
from typing import Callable

import hpc_snapshot as collector
import paramiko

from . import platform_support
from .core import Profile, validate_username

MAX_OUTPUT = 32 * 1024 * 1024
PREVIEW_LIMIT = 128 * 1024
JUMP_HOST = "rash.leeds.ac.uk"
# The whole collection's budget in seconds (both round trips), the same as
# the CLI collector's default and the macOS app's --timeout.
COLLECT_BUDGET = collector.DEFAULT_TIMEOUT
# Upper bound for opening one exec channel on a live transport.
CHANNEL_OPEN_TIMEOUT = 10


class AuthenticationRejected(Exception):
    pass


class Cancelled(Exception):
    pass


def fingerprint(key: paramiko.PKey) -> str:
    digest = base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
    return f"SHA256:{digest}"


class HostVerifier:
    def __init__(self, path: Path, ask: Callable):
        self.path = path
        self.ask = ask
        self.lock = threading.Lock()

    def verify(self, host: str, key: paramiko.PKey) -> None:
        with self.lock:
            keys = paramiko.HostKeys()
            if self.path.exists():
                keys.load(str(self.path))
            known = keys.lookup(host)
            if known:
                if not keys.check(host, key):
                    raise paramiko.SSHException(
                        f"HOST KEY CHANGED for {host}. Connection blocked. "
                        "Verify the new key with Leeds IT before changing the app's known_hosts file."
                    )
                return
            accepted = self.ask("host", host, f"{key.get_name()}\n{fingerprint(key)}")
            if not accepted:
                raise Cancelled("Host key was not trusted. No credentials were sent.")
            keys.add(host, key.get_name(), key)
            keys.save(str(self.path))
            platform_support.make_private_file(self.path)


def authenticate(transport, host: str, username: str, password: str, ask: Callable) -> None:
    methods = []
    try:
        transport.auth_none(username)
    except paramiko.BadAuthenticationType as exc:
        methods = exc.allowed_types
    if transport.is_authenticated():
        return

    password_sent = False

    def challenges(title, instructions, prompts):
        nonlocal password_sent
        answers = []
        for text, echo in prompts:
            # Supply the university password at most once per SSH server.
            if "password" in text.lower() and not any(
                word in text.lower() for word in ("new password", "expired", "change password")
            ):
                if password_sent:
                    raise AuthenticationRejected(
                        "Password requested again. Sign-in stopped to avoid account lockout."
                    )
                password_sent = True
                answers.append(password)
            else:
                answer = ask("challenge", host, (title, instructions, text, echo))
                if answer is None:
                    raise Cancelled("Sign-in cancelled.")
                answers.append(answer)
        return answers

    try:
        if "keyboard-interactive" in methods:
            remaining = transport.auth_interactive(username, challenges)
        elif "password" in methods:
            password_sent = True
            remaining = transport.auth_password(username, password, fallback=False)
        else:
            raise AuthenticationRejected(
                "This server does not offer password or keyboard-interactive sign-in."
            )
        if not transport.is_authenticated() and "keyboard-interactive" in (remaining or []):
            transport.auth_interactive(username, challenges)
        if not transport.is_authenticated():
            raise AuthenticationRejected("Sign-in was not accepted. Remaining sign-ins cancelled.")
    except paramiko.AuthenticationException as exc:
        raise AuthenticationRejected("Sign-in rejected or Duo timed out. No automatic retry.") from exc


class Session:
    def __init__(self, profile: Profile, transport: paramiko.Transport):
        self.profile = profile
        self.transport = transport

    @property
    def connected(self) -> bool:
        return self.transport.is_active() and self.transport.is_authenticated()

    def close(self):
        self.transport.close()

    def collect(self, username: str, skip_storage: bool = False, budget: int = COLLECT_BUDGET) -> dict:
        """One refresh: the collector's run_collection over this session.

        The collector owns the sequence (budget, cut-line trimming, the jobs
        fallback round trip, storage semantics), so this app and the CLI
        cannot drift apart; this class only supplies the transport (_run).
        skip_storage leaves out df/quota/lfs; the snapshot's storage is then
        None, meaning "keep the previous rows".
        """
        config = collector.SSHConfig(
            host=self.profile.id,
            username=username,
            hostname=self.profile.host,
            use_jump_host=False,
            jump_hostname=None,
            control_path=None,
            jump_control_path=None,
            timeout=budget,
        )
        snapshot = collector.run_collection(
            self._run,
            config,
            collector.ClusterInfo(self.profile.id, self.profile.name),
            self.profile.volumes,
            skip_storage=skip_storage,
        )
        return asdict(snapshot)

    def _run(self, script: str, timeout: float) -> tuple[str, str | None, bool]:
        """run_collection's transport: `sh -s` on a new exec channel, the
        script on its stdin. Returns (stdout, error, timed_out).

        Reads stdout and stderr until EOF (or the channel closes), not until
        the exit status arrives: OpenSSH may send exit-status before the
        last stdout chunk, which holds node_details, storage and the finish
        markers. stderr is drained so a full SSH window cannot stall stdout.
        A cut last line is left in place; run_collection drops it.
        """
        deadline = time.monotonic() + timeout
        channel = self.transport.open_session(timeout=min(CHANNEL_OPEN_TIMEOUT, timeout))
        output = bytearray()
        error = None
        timed_out = False
        try:
            channel.settimeout(10)
            channel.exec_command("sh -s")
            channel.sendall(script.encode("utf-8"))
            channel.shutdown_write()
            while True:
                if time.monotonic() >= deadline:
                    timed_out = True
                    break
                received = False
                if channel.recv_ready():
                    output.extend(channel.recv(65536))
                    received = True
                    if len(output) > MAX_OUTPUT:
                        raise ValueError("Snapshot exceeded the 32 MiB safety limit.")
                if channel.recv_stderr_ready():
                    channel.recv_stderr(65536)
                    received = True
                if received:
                    continue
                # EOF first, then the buffers: data always precedes EOF on the
                # wire, so once EOF is seen an empty buffer stays empty.
                if (
                    (channel.eof_received or channel.closed)
                    and not channel.recv_ready()
                    and not channel.recv_stderr_ready()
                ):
                    break
                time.sleep(0.01)
            # The exit status may follow EOF; wait for it within the budget.
            while not timed_out and not channel.exit_status_ready():
                if time.monotonic() >= deadline:
                    timed_out = True
                    break
                time.sleep(0.01)
            if timed_out:
                error = f"Timed out after {timeout:.0f}s: snapshot collection"
            else:
                code = channel.recv_exit_status()
                if code == -1:
                    # paramiko's value when the channel closed without one.
                    error = "The SSH channel closed before the snapshot command reported its exit status."
                elif code:
                    error = f"Snapshot command exited with status {code}."
        finally:
            channel.close()
        return output.decode("utf-8", errors="replace"), error, timed_out

    def files(self, path: str) -> tuple[str, list[dict]]:
        sftp = paramiko.SFTPClient.from_transport(self.transport)
        if sftp is None:
            raise ValueError("Could not open an SFTP session.")
        try:
            channel = sftp.get_channel()
            if channel is not None:
                channel.settimeout(20)
            path = sftp.normalize(path or ".")
            entries = []
            for entry in sftp.listdir_iter(path):
                entries.append(
                    {
                        "name": entry.filename,
                        "directory": stat.S_ISDIR(entry.st_mode or 0),
                        "symlink": stat.S_ISLNK(entry.st_mode or 0),
                        "bytes": entry.st_size,
                        "modified": entry.st_mtime,
                    }
                )
                if len(entries) >= 10000:
                    raise ValueError("Directory has 10,000+ entries. Open a smaller directory.")
            return path, sorted(entries, key=lambda f: (not f["directory"], f["name"].lower()))
        finally:
            sftp.close()

    def preview(self, path: str, tail: bool = False) -> str:
        sftp = paramiko.SFTPClient.from_transport(self.transport)
        if sftp is None:
            raise ValueError("Could not open an SFTP session.")
        try:
            channel = sftp.get_channel()
            if channel is not None:
                channel.settimeout(20)
            with sftp.open(path, "rb") as remote:
                size = remote.stat().st_size or 0
                if tail:
                    remote.seek(max(0, size - PREVIEW_LIMIT))
                data = remote.read(PREVIEW_LIMIT)
                if b"\0" in data:
                    return "Binary file. Text preview is unavailable."
                text = data.decode("utf-8", errors="replace")
                if size > PREVIEW_LIMIT:
                    text = ("[Last 128 KiB]\n" if tail else "[First 128 KiB]\n") + text
                return text
        finally:
            sftp.close()


class ConnectionManager:
    def __init__(self, verifier: HostVerifier, ask: Callable):
        self.verifier = verifier
        self.ask = ask
        self.jump = None
        self.sessions: dict[str, Session] = {}
        self.route = None
        self.username = None
        self.lock = threading.Lock()
        self.stopping = threading.Event()
        self.opening = set()

    def _open(self, host, username, password, sock=None):
        sock = sock or socket.create_connection((host, 22), timeout=15)
        transport = paramiko.Transport(sock)
        self.opening.add(transport)
        transport.auth_timeout = 180
        transport.banner_timeout = 30
        setattr(transport, "channel_timeout", 20)
        try:
            transport.start_client(timeout=30)
            if self.stopping.is_set():
                raise Cancelled("App is closing.")
            self.verifier.verify(host, transport.get_remote_server_key())
            authenticate(transport, host, username, password, self.ask)
            if self.stopping.is_set():
                raise Cancelled("App is closing.")
            transport.set_keepalive(30)
            return transport
        except Exception:
            transport.close()
            raise
        finally:
            self.opening.discard(transport)

    def stop(self):
        self.stopping.set()
        for transport in list(self.opening):
            transport.close()
        for session in list(self.sessions.values()):
            session.close()
        if self.jump:
            self.jump.close()

    def connect(self, profile, username, password, route):
        username = validate_username(username)
        with self.lock:
            if self.stopping.is_set():
                raise Cancelled("App is closing.")
            if self.username not in (None, username) or self.route not in (None, route):
                raise ValueError("Disconnect before changing your account or route.")
            self.username, self.route = username, route
            current = self.sessions.get(profile.id)
            if current and current.connected:
                return current
            if current:
                current.close()
            sock = None
            if route == "jump":
                if not self.jump or not self.jump.is_active() or not self.jump.is_authenticated():
                    if self.jump:
                        self.jump.close()
                    self.jump = self._open(JUMP_HOST, username, password)
                sock = self.jump.open_channel(
                    "direct-tcpip", (profile.host, 22), ("127.0.0.1", 0), timeout=20
                )
            transport = self._open(profile.host, username, password, sock)
            session = Session(profile, transport)
            self.sessions[profile.id] = session
            return session

    def disconnect(self):
        with self.lock:
            for session in self.sessions.values():
                session.close()
            self.sessions.clear()
            if self.jump:
                self.jump.close()
            self.jump = None
            self.username = self.route = None
