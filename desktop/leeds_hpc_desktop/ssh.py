from __future__ import annotations

import base64
import hashlib
import socket
import stat
import threading
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable

import hpc_snapshot as collector
import paramiko
from paramiko.hostkeys import HostKeyEntry

from . import platform_support
from .core import Profile, validate_username
from .login import (
    AuthenticationRejected,
    Cancelled,
    DuoNotApproved,
    PasswordExpired,
    PasswordRejected,
    PromptResponder,
)

# The sign-in exceptions live in the stdlib-only login module (so its tests
# run anywhere); app.py and the tests import them from here as before.
__all__ = [
    "AuthenticationRejected",
    "Cancelled",
    "ConnectionManager",
    "DuoNotApproved",
    "HostVerifier",
    "PasswordExpired",
    "PasswordRejected",
    "Session",
    "authenticate",
    "fingerprint",
    "responsive",
]

MAX_OUTPUT = 32 * 1024 * 1024
PREVIEW_LIMIT = 128 * 1024
JUMP_HOST = "rash.leeds.ac.uk"
# The whole collection's budget in seconds (both round trips), the same as
# the CLI collector's default and the macOS app's --timeout.
COLLECT_BUDGET = collector.DEFAULT_TIMEOUT
# Upper bound for opening one exec channel on a live transport.
CHANNEL_OPEN_TIMEOUT = 10
# How long after its budget a round trip may still be stuck (in
# exec_command, which has no timeout of its own) before its channel is closed.
CHANNEL_GRACE = 5
# How long a liveness probe may wait for the server's reply.
PROBE_TIMEOUT = 10


def fingerprint(key: paramiko.PKey) -> str:
    digest = base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
    return f"SHA256:{digest}"


def default_user_known_hosts() -> Path | None:
    """The user's own OpenSSH known_hosts: ~/.ssh/known_hosts on Linux,
    %USERPROFILE%\\.ssh\\known_hosts on Windows (Path.home() is either)."""
    try:
        return Path.home() / ".ssh" / "known_hosts"
    except RuntimeError:
        return None


@dataclass
class KnownHosts:
    keys: paramiko.HostKeys = field(default_factory=paramiko.HostKeys)
    # The keys (their wire bytes, PKey.asbytes()) of every line the file
    # marks "@revoked": refused for any host, whatever else it says.
    revoked: set[bytes] = field(default_factory=set)


def load_known_hosts(path: Path | None) -> KnownHosts:
    """Read an OpenSSH known_hosts file, hashed and plain entries alike.

    Read only: this is the user's file, and the app never writes it. Parsed
    line by line instead of with HostKeys.load(), which gives up on the whole
    file at a "@revoked" or "@cert-authority" line or one malformed key (it
    raises InvalidHostKey). Lines that cannot be read are skipped; certificate
    authorities and wildcard patterns are not supported, so their hosts
    simply get the app's own first-use prompt.

    "@revoked" lines are the exception: their host field is ignored and the
    key is refused for every host. The usual form is "@revoked * <key>"
    (revocation is about the key, not a host), and paramiko's lookups match
    only literal or hashed names, so honouring the pattern would need
    OpenSSH's matching; refusing a revoked key everywhere is never less safe.
    """
    known = KnownHosts()
    if path is None:
        return known
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return known
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        revoked = line.startswith("@revoked")
        if revoked:
            line = line[len("@revoked") :].strip()
        if not line or line.startswith(("#", "@")):
            continue
        try:
            entry = HostKeyEntry.from_line(line, number)
        except Exception:
            continue
        if entry is None or entry.key is None:
            continue
        if revoked:
            known.revoked.add(entry.key.asbytes())
            continue
        for name in entry.hostnames:
            known.keys.add(name, entry.key.get_name(), entry.key)
    return known


def _conflicts(keys: paramiko.HostKeys, host: str, key: paramiko.PKey) -> bool:
    """keys lists another key of the same type for host."""
    known = keys.lookup(host)
    return known is not None and known.get(key.get_name()) is not None and not keys.check(host, key)


# A host key type as known_hosts names it, and the algorithm names a client
# asks for it by (an RSA key signs with SHA-2 under the newer names).
_KEY_ALGORITHMS = {"ssh-rsa": ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"]}


class HostVerifier:
    """Checks a server's host key before any credential is sent.

    A key is trusted when it matches the app's own known_hosts (keys the user
    approved in the app) or the user's OpenSSH known_hosts, which is read but
    never written. A different key of the same type in either file, or a key
    the user's file marks @revoked, blocks the connection. A host neither
    file knows gets the explicit first-use prompt, and an approved key is
    saved to the app's file only.
    """

    def __init__(self, path: Path, ask: Callable, user_known_hosts: Path | None = None):
        self.path = path
        self.ask = ask
        self.user_known_hosts = (
            user_known_hosts if user_known_hosts is not None else default_user_known_hosts()
        )
        self.lock = threading.Lock()

    def _app_keys(self) -> paramiko.HostKeys:
        keys = paramiko.HostKeys()
        if self.path.exists():
            keys.load(str(self.path))
        return keys

    def preferred_key_types(self, host: str) -> list[str]:
        """The host key algorithms to ask host for first: those of the keys
        already trusted for it, from the app's file if it knows the host,
        otherwise from the user's. Otherwise a server with several host keys
        could offer one neither file has, and a host the user's ssh already
        trusts would get a first-use prompt (or a "changed" block) for no
        reason."""
        with self.lock:
            for keys in (self._app_keys(), load_known_hosts(self.user_known_hosts).keys):
                known = keys.lookup(host)
                if known:
                    return [name for key_type in known for name in _KEY_ALGORITHMS.get(key_type, [key_type])]
        return []

    def verify(self, host: str, key: paramiko.PKey) -> None:
        with self.lock:
            keys = self._app_keys()
            user = load_known_hosts(self.user_known_hosts)
            # Before anything else, the app's own approval included: a key
            # the user revoked stays refused even if it was approved here.
            if key.asbytes() in user.revoked:
                raise paramiko.SSHException(
                    f"The host key of {host} is marked @revoked in {self.user_known_hosts}. "
                    "Connection blocked. No credentials were sent."
                )
            changed = None
            if keys.lookup(host) is not None and not keys.check(host, key):
                changed = "the app's known_hosts file"
            elif _conflicts(user.keys, host, key):
                changed = f"your own known_hosts file ({self.user_known_hosts})"
            if changed:
                raise paramiko.SSHException(
                    f"HOST KEY CHANGED for {host}: it does not match the key in {changed}. "
                    "Connection blocked. Verify the new key with Leeds IT before changing that file."
                )
            if keys.check(host, key) or user.keys.check(host, key):
                return
            details = f"{key.get_name()}\n{fingerprint(key)}"
            if user.keys.lookup(host) is not None:
                details += (
                    "\n\nYour own known_hosts file lists a different type of key for this host; "
                    "this one is new to it."
                )
            accepted = self.ask("host", host, details)
            if not accepted:
                raise Cancelled("Host key was not trusted. No credentials were sent.")
            keys.add(host, key.get_name(), key)
            keys.save(str(self.path))
            platform_support.make_private_file(self.path)


def prefer_key_types(transport: paramiko.Transport, wanted: list[str]) -> None:
    """Put the wanted host key algorithms first in what transport asks for
    (the server picks the first one in the client's list it supports)."""
    if not wanted:
        return
    options = transport.get_security_options()
    current = list(options.key_types)
    first = [name for name in dict.fromkeys(wanted) if name in current]
    if first:
        options.key_types = first + [name for name in current if name not in first]


def _forget_paramiko_password(transport) -> None:
    """auth_password leaves the password on paramiko's AuthHandler, which
    the transport keeps for its whole life (is_authenticated reads it)."""
    handler = getattr(transport, "auth_handler", None)
    if handler is not None and getattr(handler, "password", None) is not None:
        try:
            handler.password = None
        except AttributeError:
            pass


def authenticate(transport, host: str, username: str, password: str, ask: Callable) -> bool:
    """Sign in on a started transport, keyboard-interactive first.

    The prompts are answered by login.PromptResponder (the password at most
    once, never into a password change, Duo to the user). A refusal raises
    PasswordRejected, DuoNotApproved (the password was accepted) or
    PasswordExpired, never an automatic retry. Returns True when the password
    was sent and the server accepted it: only then may it replace the saved
    password or lift that one's "rejected" flag.
    """
    methods = []
    try:
        transport.auth_none(username)
    except paramiko.BadAuthenticationType as exc:
        methods = exc.allowed_types
    if transport.is_authenticated():
        return False

    responder = PromptResponder(host, password, ask)
    try:
        if "keyboard-interactive" in methods:
            remaining = transport.auth_interactive(username, responder)
        elif "password" in methods:
            remaining = transport.auth_password(username, responder.send_password(), fallback=False)
        else:
            raise AuthenticationRejected(
                "This server does not offer password or keyboard-interactive sign-in."
            )
        if not transport.is_authenticated() and remaining:
            # Partial success: what was sent so far, the password included,
            # was right; the server wants a further step (Duo, typically).
            responder.note_partial_success()
            if "keyboard-interactive" in remaining:
                remaining = transport.auth_interactive(username, responder)
        if transport.is_authenticated():
            return responder.password_sent
        if remaining:
            raise AuthenticationRejected(
                f"{host} also requires {', '.join(remaining)} sign-in, which this app does not offer. "
                "Remaining sign-ins cancelled."
            )
        raise responder.rejected()
    except (AuthenticationRejected, Cancelled):
        raise
    except Exception as exc:
        # The responder stopped the sign-in from paramiko's transport thread
        # (a change prompt, a second password request, a cancelled dialog):
        # however paramiko reports the ended connection, that is the reason.
        if responder.stopped_with is not None:
            raise responder.stopped_with from exc
        if isinstance(exc, paramiko.AuthenticationException):
            raise responder.rejected() from exc
        raise
    finally:
        # paramiko keeps the handler (and auth_password's copy) for the life
        # of the connection; neither may keep the password.
        responder.forget()
        _forget_paramiko_password(transport)


def responsive(transport, timeout: float | None = None) -> bool:
    """Whether the server still answers on this transport.

    paramiko's keepalives ask for no reply, so after a VPN expiry or a
    suspend that black-holes the link the transport stays "active" until TCP
    gives up (about 15 minutes on Linux). A global request that wants a reply
    proves the link: OpenSSH answers keepalive@openssh.com at once (with a
    failure, which is all ssh's own ServerAlive needs). global_request has no
    timeout, so it waits on a helper thread; when the caller then closes a
    silent transport, that thread ends too.
    """
    if not transport.is_active():
        return False
    timeout = PROBE_TIMEOUT if timeout is None else timeout
    answered = threading.Event()

    def probe():
        try:
            transport.global_request("keepalive@openssh.com", wait=True)
        except Exception:
            return
        if transport.is_active():
            answered.set()

    threading.Thread(target=probe, name="ssh-liveness-probe", daemon=True).start()
    return answered.wait(timeout)


def _alive(transport) -> bool:
    return transport is not None and transport.is_active() and transport.is_authenticated()


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

    def _open_channel(self, timeout: float) -> paramiko.Channel:
        """A new session channel, or ConnectionError when the link is dead.

        A server that refuses the channel (ChannelException: too many
        sessions, say) still answers, so the connection stays. No answer
        within the timeout, or a transport that already failed, means a dead
        link (a VPN expiry, a suspend): it is closed, so the cluster shows
        "connection lost" and Connect signs in afresh, instead of every
        refresh waiting on a link only TCP's own timeout (about 15 minutes)
        would end. Never closed for a slow command: a storage stall must not
        cost a new password and Duo sign-in.
        """
        try:
            return self.transport.open_session(timeout=timeout)
        except paramiko.ChannelException:
            raise
        except (paramiko.SSHException, EOFError, OSError) as exc:
            self.transport.close()
            raise ConnectionError(
                f"The connection to {self.profile.name} stopped responding ({exc}). "
                "It was closed; press Connect to sign in again."
            ) from exc

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
        channel = self._open_channel(min(CHANNEL_OPEN_TIMEOUT, timeout))
        # exec_command waits for the server's reply without a timeout; if the
        # link dies after the channel opened, closing the channel is what
        # ends that wait (and only this round trip, not the connection).
        watchdog = threading.Timer(timeout + CHANNEL_GRACE, channel.close)
        watchdog.daemon = True
        watchdog.start()
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
            watchdog.cancel()
            channel.close()
        return output.decode("utf-8", errors="replace"), error, timed_out

    def _sftp(self) -> paramiko.SFTPClient:
        sftp = paramiko.SFTPClient.from_transport(self.transport)
        if sftp is None:
            raise ValueError("Could not open an SFTP session.")
        channel = sftp.get_channel()
        if channel is not None:
            channel.settimeout(20)
        return sftp

    def files(self, path: str) -> tuple[str, list[dict]]:
        sftp = self._sftp()
        try:
            path = sftp.normalize(path or ".")
            entries = []
            for entry in sftp.listdir_iter(path):
                entries.append(
                    {
                        "name": entry.filename,
                        # From lstat (sftp-server's READDIR): a symlink to a
                        # folder is "symlink", not "directory"; is_directory
                        # resolves it when it is opened.
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

    def is_directory(self, path: str) -> bool:
        """Whether path is a folder, following symlinks (stat, where the
        listing has lstat), so ~/scratch -> /mnt/scratch/$USER opens as one."""
        sftp = self._sftp()
        try:
            return stat.S_ISDIR(sftp.stat(path).st_mode or 0)
        finally:
            sftp.close()

    def preview(self, path: str, tail: bool = False) -> str:
        sftp = self._sftp()
        try:
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
        self.jump: paramiko.Transport | None = None
        self.sessions: dict[str, Session] = {}
        self.route = None
        self.username = None
        # Serialises sign-ins: one Duo prompt at a time, and the shared rash
        # connection is opened once. Held for a whole sign-in (minutes, while
        # Duo waits), so nothing the UI thread calls may take it.
        self.lock = threading.Lock()
        # Guards the fields here, only ever briefly. disconnect() takes only
        # this one, so it never waits for a sign-in to finish.
        self.state_lock = threading.Lock()
        # Bumped by disconnect(): a sign-in that started before it keeps
        # nothing it opens afterwards.
        self.generation = 0
        self.stopping = threading.Event()
        self.opening: set[paramiko.Transport] = set()

    def _check_current(self, generation: int) -> None:
        if self.stopping.is_set():
            raise Cancelled("App is closing.")
        if generation != self.generation:
            raise Cancelled("Disconnected while signing in.")

    def _open(self, host, username, password, generation, sock=None) -> tuple[paramiko.Transport, bool]:
        """A signed-in transport to host, and whether the password was
        verified (authenticate's result)."""
        sock = sock or socket.create_connection((host, 22), timeout=15)
        transport = paramiko.Transport(sock)
        with self.state_lock:
            # Registered before the generation check, under the same lock as
            # disconnect(): either disconnect() sees and closes it, or the
            # check below sees the disconnect.
            self.opening.add(transport)
        try:
            self._check_current(generation)
            prefer_key_types(transport, self.verifier.preferred_key_types(host))
            transport.auth_timeout = 180
            transport.banner_timeout = 30
            setattr(transport, "channel_timeout", 20)
            transport.start_client(timeout=30)
            self._check_current(generation)
            self.verifier.verify(host, transport.get_remote_server_key())
            self._check_current(generation)
            try:
                verified = authenticate(transport, host, username, password, self.ask)
            except Exception:
                # Disconnect (or quitting) closes the transport under a
                # sign-in, which paramiko reports as a failed authentication:
                # that is a cancel, never a verdict on the password (it must
                # not mark a saved password as rejected).
                self._check_current(generation)
                raise
            self._check_current(generation)
            transport.set_keepalive(30)
            return transport, verified
        except Exception:
            transport.close()
            raise
        finally:
            with self.state_lock:
                self.opening.discard(transport)

    def signed_in(self) -> bool:
        """Whether any connection (a cluster's or the shared rash one) is
        still signed in. Only then are the account and route fixed."""
        return any(s.connected for s in list(self.sessions.values())) or _alive(self.jump)

    def _release_if_signed_out(self) -> list:
        """With nothing signed in any more (a failed or cancelled sign-in,
        or every link dropped), nothing ties the next sign-in to the old
        account or route: the off-VPN fix of switching to rash, or a
        corrected username, must just work. Call with state_lock held;
        returns the dead connections, to close outside it."""
        if self.signed_in():
            return []
        dead = [*self.sessions.values(), *([self.jump] if self.jump is not None else [])]
        self.sessions.clear()
        self.jump = None
        self.username = self.route = None
        return dead

    def connect(
        self, profile, username, password, route, generation: int | None = None
    ) -> tuple[Session, bool]:
        """Sign in to profile's cluster, or reuse its live session.

        Returns (session, verified): verified is True when this call sent
        the password and a server accepted it. Reusing a session sends
        nothing, so it proves nothing about the password.

        generation is self.generation as read when the user pressed Connect.
        One Connect signs in to several clusters one after another, each
        with its own call: a Disconnect after the first must cancel the rest
        too, so a call carrying an older generation raises Cancelled before
        anything is opened or sent. None means "as of this call".
        """
        username = validate_username(username)
        with self.lock:
            with self.state_lock:
                if self.stopping.is_set():
                    raise Cancelled("App is closing.")
                if generation is None:
                    generation = self.generation
                elif generation != self.generation:
                    raise Cancelled("Disconnected while signing in.")
                dead = self._release_if_signed_out()
                if self.username not in (None, username) or self.route not in (None, route):
                    raise ValueError("Disconnect before changing your account or route.")
                self.username, self.route = username, route
                current = self.sessions.get(profile.id)
                jump = self.jump
            for connection in dead:
                connection.close()
            if current is not None:
                # A session can look connected on a link that died silently;
                # reuse it only if the server still answers.
                if current.connected and responsive(current.transport):
                    return current, False
                current.close()
            verified = False
            sock = None
            if route == "jump":
                if not _alive(jump) or not responsive(jump):
                    if jump is not None:
                        jump.close()
                    jump, verified = self._open(JUMP_HOST, username, password, generation)
                    with self.state_lock:
                        if generation != self.generation:
                            jump.close()
                            raise Cancelled("Disconnected while signing in.")
                        self.jump = jump
                assert jump is not None
                sock = jump.open_channel("direct-tcpip", (profile.host, 22), ("127.0.0.1", 0), timeout=20)
            transport, target_verified = self._open(profile.host, username, password, generation, sock)
            with self.state_lock:
                if self.stopping.is_set() or generation != self.generation:
                    transport.close()
                    raise Cancelled("Disconnected while signing in.")
                session = Session(profile, transport)
                self.sessions[profile.id] = session
            return session, verified or target_verified

    def disconnect(self):
        """End every session, and any sign-in in progress, without waiting.

        Closing a transport is local and ends whatever waits on it (a
        refresh, a channel open, an authentication), so this works on a link
        that has stopped answering, and while a refresh runs.
        """
        with self.state_lock:
            self.generation += 1
            sessions = list(self.sessions.values())
            self.sessions.clear()
            jump, self.jump = self.jump, None
            opening = list(self.opening)
            self.username = self.route = None
        # rash first: once it is closed, the clusters' transports tunnelled
        # through it close without trying to send over a dead link.
        if jump is not None:
            jump.close()
        for transport in opening:
            transport.close()
        for session in sessions:
            session.close()

    def stop(self):
        self.stopping.set()
        self.disconnect()
