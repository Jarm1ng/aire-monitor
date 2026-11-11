#!/usr/bin/env python3
"""Multi-cluster login-flow tests for the REAL hpc_* login scripts.

A fake `ssh` (fake_ssh.py) is placed first on PATH and the genuine
scripts/hpc_* helpers are driven exactly the way Sources/.../MonitorService.swift
drives them:

  * rash route: hpc_ssh_login.expect with HPC_SKIP_TARGET=1 (jump leg only),
    then hpc_start_target_master.zsh for the target;
  * direct route: hpc_start_target_master.zsh only;
  * sign-out: hpc_stop_master.zsh.

The password is always handed over on the first line of stdin. Logins are
forced (HPC_FORCE_RELOGIN=1, a replacement) unless a scenario says
otherwise. As in the app, each cluster has one control socket PER ROUTE
(<id>-direct.sock / <id>-jump.sock) and one runtime directory, and every
cluster on the rash route shares one jump socket.

Scenarios (see the PASS/FAIL table at the end):
  S1  direct login "AIRE": a -N master (no remote command), per-path pid
      file, and no keepalive of any kind
  S2  direct login "Calder" while AIRE is alive
  S3  rash route: AIRE via jump, then Calder via jump (jump master reused)
  S4  forced re-login of AIRE via jump while Calder is alive
  S5  wedged jump master, and a jump master that dies mid-probe, are
      re-authenticated (and the tunnels that rode on them die with them)
  S6  wrong password -> exit 13 from the leg that rejected it; a stale
      exported HPC_PASSWORD never overrides the password on stdin
  S7  no password ever appears in any argv, runtime file, or master environ
      (runs LAST so its scan covers every login the suite performed)
  S8  Calder refusing rash's channel, the sshd "Not allowed at this time"
      drop, and a silent Calder all keep the shared jump master and AIRE's
      tunnel, and the Calder leg never claims to wait for Duo
  S9  the password is served once: no writer/FIFO survives into the Duo
      wait, and killing ONLY the starter's pid leaves no writer or FIFO
  S10 a declined / timed-out / abandoned Duo push -> exit 15 (not 13) on
      both legs, with exactly ONE push
  S11 an expired password -> exit 14 on both legs (pam_sss before and after
      Duo, RHEL 7 pam_unix), and the password-change prompt is never answered
  S12 a non-forced login reuses a healthy master (no Duo, even while the
      login node refuses new connections), leaves one that answers its
      socket but runs no command untouched (exit 5; only a forced login
      replaces it), ends the permanent session of an old-release master,
      adopts a session without a password (HPC_REUSE_ONLY), and reports
      progress in the order the server asks
  S13 HPC_TIMEOUT: a silent server -> 124 on both legs; a push never
      answered -> 15; nothing is left running
  S14 a password with quotes, spaces, backslashes, $, backticks and UTF-8
  S15 hpc_stop_master.zsh: stops exactly one route's master and its pid
      file, keeps the other route's record (route switching), kills an
      old-release keepalive of that path only, refuses the jump socket, and
      stops the shared jump master only once nothing rides on it — with the
      masters titled as real -N masters are (their own argv, never
      "[mux]"), so the jump master's argv never counts as its own rider
  S16 ssh option sets: masters run no remote command, the ProxyCommand is
      hardened, nothing uses ControlMaster=auto, the collector stays a
      client

Nothing here touches ~/.ssh or the user's real sessions: every control
socket, runtime directory and log lives under a private temp work dir, and
`launchctl` is a no-op stub. Each script leg runs in its own process group,
which is killed on timeout, and teardown only kills processes whose argv or
launch environment mentions that work dir (every process the harness starts
inherits HPC_FAKE_HOME).

Run:  scripts/tests/test_login_flow.py        (from anywhere)
      python3 scripts/tests/test_login_flow.py
"""

import contextlib
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True   # never litter scripts/tests/__pycache__
import fake_ssh  # noqa: E402 - exec_interpreter() and the fake's argv parser
PROJECT_ROOT = os.path.dirname(os.path.dirname(HERE))
SCRIPTS = os.path.join(PROJECT_ROOT, "scripts")

USERNAME = "abcd1234"
RASH = "rash.leeds.ac.uk"
PASSWORD = "Tr0ub4dour-SECRET-pw-9271"
WRONG_PASSWORD = "definitely-not-it"
STALE_ENV_PASSWORD = "Stale-EXPORTED-pw-5519"
TRICKY_PASSWORD = " p a\"s's\\w$HOME`id`;é !\t* "
# Every fake `ssh` is a Python process, and on a heavily loaded machine
# (parallel builds) merely starting Python can take seconds.
# HPC_LOGIN_TEST_SLOWDOWN=<factor> stretches the harness's own default waits
# — the per-leg limit, HPC_TIMEOUT and the jump-probe timeout — by that
# factor. Limits a scenario passes explicitly (S13's) are left alone.
SLOWDOWN = max(1.0, float(os.environ.get("HPC_LOGIN_TEST_SLOWDOWN", "") or 1))


def scaled(seconds):
    return int(round(seconds * SLOWDOWN))


PROBE_TIMEOUT = str(scaled(2))  # seconds the jump probe waits (keep tests quick)

CLUSTERS = {
    "aire": ("AIRE", "aire.leeds.ac.uk"),
    "calder": ("Calder", "calder.leeds.ac.uk"),
}


class Harness:
    def __init__(self):
        self.work = tempfile.mkdtemp(prefix="hpc-login-test.")
        self.bin = os.path.join(self.work, "bin")
        self.ctl = os.path.join(self.work, "ctl")
        self.logs = os.path.join(self.work, "logs")
        for d in (self.bin, self.ctl, self.logs):
            os.makedirs(d, exist_ok=True)
        shutil.copy2(os.path.join(HERE, "fake_ssh.py"), os.path.join(self.bin, "ssh"))
        os.chmod(os.path.join(self.bin, "ssh"), 0o755)
        # The scripts remove a legacy launchd job by label; the harness must
        # never reach the user's real launchd.
        launchctl = os.path.join(self.bin, "launchctl")
        with open(launchctl, "w") as fh:
            fh.write("#!/bin/sh\nexit 0\n")
        os.chmod(launchctl, 0o755)
        # Every secret any scenario uses; S7 proves none of them leaked.
        self.secrets = [PASSWORD, STALE_ENV_PASSWORD]
        self.set_expected_password(PASSWORD)

    def set_expected_password(self, password):
        # The fake's expected ("correct") password lives in a file, never an
        # env var, so it never lands in a daemonized master's environment.
        with open(os.path.join(self.work, "expected_password"), "w") as fh:
            fh.write(password + "\n")

    # -- paths ------------------------------------------------------------
    def control_path(self, cluster_id, route):
        return os.path.join(self.ctl, "%s-%s.sock" % (cluster_id, route))

    def jump_control_path(self):
        return os.path.join(self.ctl, "jump.sock")

    def runtime_dir(self, cluster_id):
        return os.path.join(self.work, "runtime", "clusters", cluster_id)

    def pid_file(self, cluster_id, route):
        return os.path.join(self.runtime_dir(cluster_id),
                            "master-%s-%s.pid" % (cluster_id, route))

    # -- environment ------------------------------------------------------
    def base_env(self):
        env = dict(os.environ)
        env["PATH"] = self.bin + os.pathsep + env.get("PATH", "")
        env["HPC_FAKE_HOME"] = self.work
        env["HPC_PROJECT_ROOT"] = PROJECT_ROOT
        env["HPC_JUMP_PROBE_TIMEOUT"] = PROBE_TIMEOUT
        # Make sure no inherited DISPLAY/askpass/password leaks in from the
        # real shell.
        for name in ("SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "HPC_PASSWORD",
                     "HPC_ASKPASS_PASSWORD", "AIRE_PASSWORD", "AIRE_ASKPASS_PASSWORD"):
            env.pop(name, None)
        return env

    def cluster_env(self, cluster_id, route, force=True, jump_control_path=None, extra=None):
        label, host = CLUSTERS[cluster_id]
        env = self.base_env()
        env["HPC_USERNAME"] = USERNAME
        env["HPC_HOSTNAME"] = host
        env["HPC_TARGET_LABEL"] = label
        env["HPC_DUO_OPTION"] = "1"
        env["HPC_TIMEOUT"] = str(scaled(30))
        env["HPC_CONTROL_PATH"] = self.control_path(cluster_id, route)
        env["HPC_RUNTIME_DIR"] = self.runtime_dir(cluster_id)
        env["HPC_LOGIN_DEBUG_LOG"] = os.path.join(self.runtime_dir(cluster_id), "login_debug.log")
        env["HPC_FORCE_RELOGIN"] = "1" if force else "0"
        if route == "jump":
            env["HPC_USE_JUMP_HOST"] = "1"
            env["HPC_JUMP_HOSTNAME"] = RASH
            env["HPC_JUMP_CONTROL_PATH"] = jump_control_path or self.jump_control_path()
        else:
            env["HPC_USE_JUMP_HOST"] = "0"
        env.update(extra or {})
        os.makedirs(self.runtime_dir(cluster_id), exist_ok=True)
        return env

    # -- running the real scripts ----------------------------------------
    def run_expect_jump(self, cluster_id, password=PASSWORD, jump_control_path=None,
                        extra=None, timeout=None):
        env = self.cluster_env(cluster_id, "jump", jump_control_path=jump_control_path,
                               extra=extra)
        env["HPC_SKIP_TARGET"] = "1"
        helper = os.path.join(SCRIPTS, "hpc_ssh_login.expect")
        return self._run(["/usr/bin/expect", helper], env, password + "\n", timeout)

    def run_target_starter(self, cluster_id, route, password=PASSWORD, force=True,
                           jump_control_path=None, extra=None, timeout=None):
        env = self.cluster_env(cluster_id, route, force=force,
                               jump_control_path=jump_control_path, extra=extra)
        starter = os.path.join(SCRIPTS, "hpc_start_target_master.zsh")
        return self._run(["/bin/zsh", starter], env, password + "\n", timeout)

    def run_stop(self, cluster_id, route, extra=None, timeout=None):
        env = self.cluster_env(cluster_id, route, extra=extra)
        stopper = os.path.join(SCRIPTS, "hpc_stop_master.zsh")
        return self._run(["/bin/zsh", stopper], env, "", timeout)

    def app_login(self, cluster_id, route, password=PASSWORD, force=True):
        """Mirror MonitorService.login: jump leg (rash only) then target."""
        legs = {}
        if route == "jump":
            legs["jump"] = self.run_expect_jump(cluster_id, password)
            if legs["jump"].returncode != 0:
                return legs
        legs["target"] = self.run_target_starter(cluster_id, route, password, force=force)
        return legs

    def ensure_live(self, cluster_id, route):
        """Precondition helper: a live master for (cluster, route), reusing
        one that is already healthy."""
        if self.master_alive(cluster_id, route):
            return True
        legs = self.app_login(cluster_id, route, force=False)
        return all(p.returncode == 0 for p in legs.values()) and \
            self.master_alive(cluster_id, route)

    def _run(self, argv, env, stdin_text, timeout=None):
        timeout = timeout or scaled(30)
        # Each leg gets its own session/process group (as Foundation's
        # Process gives the app's children their own group), so a hung leg
        # can be killed together with every helper it forked — including the
        # starter's password-writer subshell — rather than just its top pid.
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            cwd=PROJECT_ROOT,
            start_new_session=True,
        )
        try:
            out, err = proc.communicate(stdin_text.encode(), timeout=timeout)
        except subprocess.TimeoutExpired:
            # Signal the group while its leader is still unreaped, so the
            # pgid cannot have been recycled by an unrelated process.
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
            proc.communicate()
            raise RuntimeError("%s timed out after %ss" % (os.path.basename(argv[-1]), timeout))
        return subprocess.CompletedProcess(argv, proc.returncode, out, err)

    # -- helper processes that impersonate older releases -------------------
    def spawn_impersonator(self, argv0, args):
        """A process whose `ps` argv is `argv0 -c <sleep code> args...`, used
        to impersonate leftovers of older releases. Double-forked, so (like a
        real leftover) it is reparented to launchd, which reaps it the moment
        it dies — a child of this harness would linger as a zombie that
        `kill -0` still reports alive. It inherits HPC_FAKE_HOME, and its argv
        names a control path under the work dir, so teardown always finds it.
        Returns its pid."""
        argv = [argv0, "-c", "import time; time.sleep(300)"] + list(args)
        env = self.base_env()
        read_fd, write_fd = os.pipe()
        child = os.fork()
        if child == 0:
            try:
                os.close(read_fd)
                os.setsid()
                grandchild = os.fork()
                if grandchild > 0:
                    os.write(write_fd, str(grandchild).encode())
                    os._exit(0)
                os.close(write_fd)
                devnull = os.open(os.devnull, os.O_RDWR)
                for fd in (0, 1, 2):
                    os.dup2(devnull, fd)
                os.execve(fake_ssh.exec_interpreter(), argv, env)
            finally:
                os._exit(127)
        os.close(write_fd)
        data = os.read(read_fd, 32)
        os.close(read_fd)
        os.waitpid(child, 0)
        pid = int(data)
        # Wait until ps shows the impersonated argv.
        end = time.time() + scaled(5)
        while time.time() < end and argv0 not in _ps_command(pid):
            time.sleep(0.05)
        return pid

    def spawn_legacy_keepalive(self, control_path, host):
        """What older releases left running: hpc_target_keepalive.zsh with
        the control path as its first argument."""
        return self.spawn_impersonator(
            "/bin/zsh", ["hpc_target_keepalive.zsh", control_path, USERNAME, host,
                         "0", RASH, ""])

    def spawn_legacy_session_client(self, control_path, host):
        """The permanent `ssh -f ... host sleep 2147483647` session client of
        an older release's master."""
        return self.spawn_impersonator(
            "ssh", ["-f", "-o", "ControlMaster=yes", "-o", "ControlPersist=24h",
                    "-o", "ControlPath=" + control_path, "-o", "User=" + USERNAME,
                    host, "sleep", "2147483647"])

    # -- inspection -------------------------------------------------------
    def master_state(self, cluster_id, route):
        return _read_state(self.control_path(cluster_id, route) + ".state")

    def jump_state(self, path=None):
        return _read_state((path or self.jump_control_path()) + ".state")

    def master_pid(self, cluster_id, route):
        st = self.master_state(cluster_id, route)
        return st.get("pid") if st else None

    def jump_pid(self, path=None):
        st = self.jump_state(path)
        return st.get("pid") if st else None

    def master_alive(self, cluster_id, route):
        pid = self.master_pid(cluster_id, route)
        return pid is not None and _pid_alive(pid) and \
            os.path.exists(self.control_path(cluster_id, route))

    def jump_alive(self, path=None):
        pid = self.jump_pid(path)
        return pid is not None and _pid_alive(pid) and \
            os.path.exists(path or self.jump_control_path())

    def duo_count(self, host):
        return len(_read_lines(os.path.join(self.logs, "duo", host.replace("/", "_") + ".log")))

    def pw_change_answers(self, host):
        return _read_lines(os.path.join(self.logs, "pw_change", host.replace("/", "_") + ".log"))

    def set_knob(self, kind, host, value):
        """Per-host fake behaviour (see fake_ssh.py's docstring)."""
        d = os.path.join(self.work, kind)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, host), "w") as fh:
            fh.write("%s\n" % value)

    def clear_knob(self, kind, host):
        try:
            os.remove(os.path.join(self.work, kind, host))
        except OSError:
            pass

    @contextlib.contextmanager
    def knobs(self, host, **settings):
        for kind, value in settings.items():
            self.set_knob(kind, host, value)
        try:
            yield
        finally:
            for kind in settings:
                self.clear_knob(kind, host)

    def set_w_mode(self, host, mode):
        """Tell the fake how the far end answers when rash opens host:22."""
        self.set_knob("w_mode", host, mode)

    def clear_w_mode(self, host):
        self.clear_knob("w_mode", host)

    def debug_log(self, cluster_id):
        try:
            with open(os.path.join(self.runtime_dir(cluster_id), "login_debug.log")) as fh:
                return fh.read()
        except OSError:
            return ""

    def wedge(self, control_path):
        """A wedged master: pid alive and -O check passes, but every session
        or -W channel through it fails or hangs."""
        state_path = control_path + ".state"
        st = _read_state(state_path)
        st["wedged"] = True
        with open(state_path, "w") as fh:
            json.dump(st, fh)

    def all_runtime_files(self):
        """Regular files only. Never open() anything else here: a leftover
        askpass FIFO would block a reader forever (see special_runtime_files,
        which S7 reports instead)."""
        out = []
        for root, _dirs, files in os.walk(os.path.join(self.work, "runtime")):
            for name in files:
                path = os.path.join(root, name)
                try:
                    if stat.S_ISREG(os.lstat(path).st_mode):
                        out.append(path)
                except OSError:
                    pass
        return out

    def special_runtime_files(self):
        """FIFOs, sockets, symlinks... left under the runtime dirs."""
        out = []
        for root, _dirs, files in os.walk(os.path.join(self.work, "runtime")):
            for name in files:
                path = os.path.join(root, name)
                try:
                    if not stat.S_ISREG(os.lstat(path).st_mode):
                        out.append(path)
                except OSError:
                    pass
        return out

    def environ_files(self):
        return [os.path.join(self.ctl, name) for name in os.listdir(self.ctl)
                if name.endswith(".environ")]

    def invocations(self):
        out = []
        for line in _read_lines(os.path.join(self.logs, "invocations.log")):
            try:
                out.append(json.loads(line)["argv"])
            except (ValueError, KeyError):
                pass
        return out

    def live_processes_mentioning(self, needle):
        """Live pids started under this harness whose argv contains needle."""
        return [pid for pid in _pids_mentioning(self.work)
                if needle in _ps_command(pid)]

    # -- teardown ---------------------------------------------------------
    def teardown(self):
        # Kill only processes whose argv or launch environment mentions our
        # work dir — never the user's real ssh sessions, which reference
        # ~/.ssh and the real project path, not this temp dir. The
        # environment match is what catches helpers whose argv names only the
        # real script (e.g. the starter's forked password writer).
        for _ in range(3):
            victims = _pids_mentioning(self.work)
            if not victims:
                break
            for pid in victims:
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError:
                    pass
            time.sleep(0.3)
        for pid in _pids_mentioning(self.work):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        shutil.rmtree(self.work, ignore_errors=True)


# --------------------------------------------------------------------------
# process helpers
# --------------------------------------------------------------------------
def _read_state(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _read_lines(path):
    try:
        with open(path) as fh:
            return [ln.rstrip("\n") for ln in fh if ln.strip()]
    except OSError:
        return []


def _read_text(path):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return None


def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def _wait_dead(pid, seconds=None):
    end = time.time() + (seconds or scaled(3))
    while time.time() < end and _pid_alive(pid):
        time.sleep(0.05)
    return not _pid_alive(pid)


def _ps_command(pid):
    try:
        out = subprocess.run(
            ["ps", "-p", str(pid), "-o", "command="],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return out.stdout.decode("utf-8", "replace").strip()
    except OSError:
        return ""


def _ps_environ(pid):
    try:
        out = subprocess.run(
            ["ps", "-p", str(pid), "-E", "-o", "command="],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return out.stdout.decode("utf-8", "replace")
    except OSError:
        return ""


def _children_running(ppid, needle):
    try:
        out = subprocess.run(
            ["ps", "-ax", "-o", "pid=,ppid=,command="],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return []
    pids = []
    for line in out.stdout.decode("utf-8", "replace").splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[1] == str(ppid) and needle in parts[2]:
            try:
                pids.append(int(parts[0]))
            except ValueError:
                pass
    return pids


def _pids_mentioning(needle):
    """Pids whose argv, or (same-user processes only) launch environment as
    shown by `ps -E`, contains `needle`."""
    pids = []
    try:
        out = subprocess.run(
            ["ps", "-ax", "-E", "-o", "pid=,command="],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return pids
    me = os.getpid()
    for line in out.stdout.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        pid_s, cmd = parts
        if needle in cmd:
            try:
                pid = int(pid_s)
            except ValueError:
                continue
            if pid != me:
                pids.append(pid)
    return pids


@contextlib.contextmanager
def throwaway(cluster_id, label):
    """A scratch cluster whose failures cannot disturb the live masters the
    other scenarios built."""
    CLUSTERS[cluster_id] = (label, "%s.leeds.ac.uk" % cluster_id)
    try:
        yield CLUSTERS[cluster_id][1]
    finally:
        CLUSTERS.pop(cluster_id, None)


# --------------------------------------------------------------------------
# scenarios
# --------------------------------------------------------------------------
class Check:
    def __init__(self):
        self.failures = []

    def ok(self, cond, msg):
        if not cond:
            self.failures.append(msg)

    def passed(self):
        return not self.failures


def status_lines(proc):
    text = proc.stdout.decode("utf-8", "replace")
    return [ln[len("HPC-STATUS: "):] for ln in text.splitlines()
            if ln.startswith("HPC-STATUS: ")]


def err(proc, n=240):
    return proc.stderr.decode("utf-8", "replace")[:n]


def no_keepalive_anywhere(h, c, cluster_id):
    rt = h.runtime_dir(cluster_id)
    for name in ("keepalive.pid", "keepalive.log", "keepalive_starter.log"):
        c.ok(not os.path.exists(os.path.join(rt, name)),
             "%s was created in %s's runtime dir" % (name, cluster_id))
    c.ok(not h.live_processes_mentioning("hpc_target_keepalive"),
         "a keepalive process is running")


def s1_direct_aire(h):
    c = Check()
    legs = h.app_login("aire", "direct")
    target = legs["target"]
    c.ok(target.returncode == 0, "exit %d != 0 (%s)" % (target.returncode, err(target)))
    names = status_lines(target)
    c.ok(any("AIRE" in n for n in names), "no HPC-STATUS line named AIRE: %r" % names)
    c.ok(h.master_alive("aire", "direct"), "AIRE master not alive")
    st = h.master_state("aire", "direct") or {}
    # ControlPersist is an IDLE timer: a master that runs a remote command
    # (older releases: `sleep 2147483647`) never idles and never expires.
    c.ok(st.get("no_command") is True and not st.get("command"),
         "master was started with a remote command / without -N: %r" % st.get("command"))
    c.ok(st.get("control_persist") == "24h", "ControlPersist=%r" % st.get("control_persist"))
    # The pid record is per control path, and names the live master.
    c.ok(_read_text(h.pid_file("aire", "direct")) == str(h.master_pid("aire", "direct")),
         "per-path pid file missing or wrong (%r vs %r)" % (
             _read_text(h.pid_file("aire", "direct")), h.master_pid("aire", "direct")))
    c.ok(not os.path.exists(os.path.join(h.runtime_dir("aire"), "master_ssh.pid")),
         "the old shared master_ssh.pid is still written")
    no_keepalive_anywhere(h, c, "aire")
    c.ok(not os.path.isdir(h.runtime_dir("calder")) or not os.listdir(h.runtime_dir("calder")),
         "Calder runtime dir unexpectedly populated")
    return c


def s2_direct_calder_while_aire(h):
    c = Check()
    aire_pid = h.master_pid("aire", "direct")
    legs = h.app_login("calder", "direct")
    target = legs["target"]
    c.ok(target.returncode == 0, "Calder exit %d != 0 (%s)" % (target.returncode, err(target)))
    c.ok(h.master_alive("calder", "direct"), "Calder master not alive")
    c.ok(h.master_alive("aire", "direct"), "AIRE master died during Calder login")
    c.ok(h.master_pid("aire", "direct") == aire_pid, "AIRE master pid changed (%s -> %s)" % (
        aire_pid, h.master_pid("aire", "direct")))
    c.ok(_read_text(h.pid_file("aire", "direct")) == str(aire_pid),
         "AIRE's pid file was disturbed by the Calder login")
    names = status_lines(target)
    c.ok(any("Calder" in n for n in names), "no HPC-STATUS line named Calder: %r" % names)
    return c


def s3_rash_reuses_jump(h):
    c = Check()
    # Duo prompts accumulate across the whole run, so every assertion here is
    # on the DELTA caused by this scenario's logins, not the running totals.
    rash0 = h.duo_count(RASH)
    aire0 = h.duo_count(CLUSTERS["aire"][1])
    calder0 = h.duo_count(CLUSTERS["calder"][1])

    # AIRE via jump: fresh jump master (1 rash Duo) + AIRE target (1 AIRE Duo).
    legs = h.app_login("aire", "jump")
    c.ok(legs["jump"].returncode == 0, "AIRE jump leg exit %d" % legs["jump"].returncode)
    c.ok(legs.get("target") is not None and legs["target"].returncode == 0,
         "AIRE target failed (%s)" % (err(legs["target"]) if "target" in legs else "no leg"))
    c.ok(h.jump_alive(), "jump master not alive after AIRE")
    c.ok(h.master_alive("aire", "jump"), "AIRE master not alive (jump route)")
    jump_pid = h.jump_pid()
    rash_d = h.duo_count(RASH) - rash0
    aire_d = h.duo_count(CLUSTERS["aire"][1]) - aire0
    c.ok(rash_d == 1, "rash Duo prompts for AIRE-via-jump = %d, want 1" % rash_d)
    c.ok(aire_d == 1, "AIRE Duo prompts = %d, want 1" % aire_d)
    # Each leg that authenticated says so: the app saves a typed password
    # only on this evidence (see MonitorService.passwordWasVerified).
    c.ok("password sent (jump host)" in status_lines(legs["jump"]),
         "a fresh jump login did not say it sent the password: %r" % status_lines(legs["jump"]))
    # The tunnelled master keeps a -W proxy child that names the jump socket
    # (this is what tells hpc_stop_master.zsh the jump master is in use).
    proxy = (h.master_state("aire", "jump") or {}).get("proxy_pid")
    c.ok(proxy and _pid_alive(proxy) and h.jump_control_path() in _ps_command(proxy),
         "AIRE's -W proxy child is missing (pid %r)" % proxy)

    # Calder via jump: jump must be REUSED (same pid, no new rash Duo).
    rash1 = h.duo_count(RASH)
    legs = h.app_login("calder", "jump")
    jump_names = status_lines(legs["jump"])
    c.ok(legs["jump"].returncode == 0, "Calder jump leg exit %d" % legs["jump"].returncode)
    c.ok(legs.get("target") is not None and legs["target"].returncode == 0,
         "Calder target failed (%s)" % (err(legs["target"]) if "target" in legs else "no leg"))
    c.ok(h.jump_pid() == jump_pid, "jump master pid changed (%s -> %s): not reused" % (
        jump_pid, h.jump_pid()))
    c.ok(any("reus" in n.lower() for n in jump_names),
         "jump leg did not report reuse: %r" % jump_names)
    c.ok(not any("password sent" in n for n in jump_names),
         "a reused jump master announced a password it never sent: %r" % jump_names)
    c.ok(h.duo_count(RASH) - rash1 == 0,
         "reusing the jump master cost %d new rash Duo, want 0" % (h.duo_count(RASH) - rash1))
    calder_d = h.duo_count(CLUSTERS["calder"][1]) - calder0
    c.ok(calder_d == 1, "Calder Duo prompts = %d, want exactly 1 new" % calder_d)
    c.ok(h.master_alive("aire", "jump"), "AIRE target died when Calder logged in via jump")
    c.ok(h.master_alive("calder", "jump"), "Calder master not alive (jump route)")
    # Route switching: both of AIRE's records survive side by side.
    c.ok(h.master_alive("aire", "direct"), "AIRE's direct-route master died on the route switch")
    c.ok(_read_text(h.pid_file("aire", "direct")) == str(h.master_pid("aire", "direct")),
         "the direct route's pid record was lost when AIRE switched to the jump route")
    c.ok(_read_text(h.pid_file("aire", "jump")) == str(h.master_pid("aire", "jump")),
         "the jump route's pid record is missing")
    return c


def s4_force_relogin_keeps_jump_and_calder(h):
    c = Check()
    jump_pid = h.jump_pid()
    calder_pid = h.master_pid("calder", "jump")
    aire_pid_before = h.master_pid("aire", "jump")
    rash_duo_before = h.duo_count(RASH)

    legs = h.app_login("aire", "jump")  # force=1 (default)
    c.ok(legs["jump"].returncode == 0, "forced AIRE jump leg exit %d" % legs["jump"].returncode)
    c.ok(legs.get("target") is not None and legs["target"].returncode == 0,
         "forced AIRE target failed")
    c.ok(h.jump_pid() == jump_pid, "jump master torn down by forced relogin (%s -> %s)" % (
        jump_pid, h.jump_pid()))
    c.ok(h.duo_count(RASH) == rash_duo_before, "forced relogin triggered a new rash Duo")
    c.ok(h.master_alive("aire", "jump"), "AIRE master not alive after forced relogin")
    c.ok(h.master_pid("aire", "jump") != aire_pid_before,
         "AIRE master pid unchanged by forced relogin (%s)" % aire_pid_before)
    c.ok(not _pid_alive(aire_pid_before), "the replaced AIRE master is still running")
    c.ok(h.master_alive("calder", "jump") and h.master_pid("calder", "jump") == calder_pid,
         "Calder master disturbed by AIRE forced relogin")
    return c


def s18_renew_replaces_healthy_jump(h):
    """The app's confirmed "Renew all": HPC_RENEW_JUMP_HOST=1 on the first
    cluster replaces a HEALTHY jump master (one rash Duo), and every cluster
    is then signed in again through the new one."""
    c = Check()
    for cid in ("aire", "calder"):
        c.ok(h.ensure_live(cid, "jump"), "precondition: %s live on the rash route" % cid)
    old_jump = h.jump_pid()
    rash0 = h.duo_count(RASH)
    aire0 = h.duo_count(CLUSTERS["aire"][1])
    calder0 = h.duo_count(CLUSTERS["calder"][1])

    jump = h.run_expect_jump("aire", extra={"HPC_RENEW_JUMP_HOST": "1"})
    names = status_lines(jump)
    c.ok(jump.returncode == 0, "renewing jump leg exit %d: %s" % (jump.returncode, err(jump)))
    c.ok(any("replacing the shared jump-host session" in n for n in names),
         "the renewal did not say it replaces the jump session: %r" % names)
    c.ok("password sent (jump host)" in names, "a renewed jump login must send the password: %r" % names)
    c.ok(h.jump_alive() and h.jump_pid() != old_jump,
         "jump master not replaced (%s -> %s)" % (old_jump, h.jump_pid()))
    c.ok(old_jump is None or _wait_dead(old_jump), "the old jump master is still running")
    c.ok(h.duo_count(RASH) - rash0 == 1, "renewal cost %d rash Duo, want 1" % (h.duo_count(RASH) - rash0))

    for cid in ("aire", "calder"):
        target = h.run_target_starter(cid, "jump", force=True)
        c.ok(target.returncode == 0, "%s forced target after renewal exit %d: %s" % (cid, target.returncode, err(target)))
        c.ok(h.master_alive(cid, "jump"), "%s not live after the renewal" % cid)
    c.ok(h.duo_count(RASH) - rash0 == 1, "the clusters' sign-ins re-authenticated rash again")
    c.ok(h.duo_count(CLUSTERS["aire"][1]) - aire0 == 1, "AIRE Duo prompts != 1")
    c.ok(h.duo_count(CLUSTERS["calder"][1]) - calder0 == 1, "Calder Duo prompts != 1")

    # Without the flag a healthy jump master is still reused.
    plain = h.run_expect_jump("calder")
    c.ok(plain.returncode == 0 and h.duo_count(RASH) - rash0 == 1,
         "a plain jump leg after the renewal did not reuse the new master")
    return c


def s5_dead_jump_reauth(h):
    c = Check()
    calder_host = CLUSTERS["calder"][1]

    # (a) Wedge the shared jump master: -O check still passes, but every -W
    # channel through it hangs (target probe AND the 127.0.0.1 self-probe).
    c.ok(h.jump_alive(), "precondition: jump master should be alive")
    c.ok(h.master_alive("aire", "jump"), "precondition: AIRE should be alive via the jump")
    old_jump_pid = h.jump_pid()
    h.wedge(h.jump_control_path())
    rash_duo_before = h.duo_count(RASH)

    # A fresh cluster login over the wedged jump must detect it and re-auth.
    legs = h.app_login("calder", "jump")
    c.ok(legs["jump"].returncode == 0, "jump leg over wedged master exit %d (%s)" % (
        legs["jump"].returncode, err(legs["jump"])))
    c.ok("target" in legs and legs["target"].returncode == 0,
         "target over re-authed jump failed")
    c.ok(h.jump_alive(), "jump master not alive after re-auth")
    c.ok(h.jump_pid() != old_jump_pid, "wedged jump master was not replaced (%s)" % old_jump_pid)
    c.ok(not _pid_alive(old_jump_pid), "the wedged jump master process is still running")
    c.ok(h.duo_count(RASH) == rash_duo_before + 1,
         "re-auth should cost exactly one rash Duo (before=%d, now=%d)" % (
             rash_duo_before, h.duo_count(RASH)))
    # Replacing a jump master kills every tunnel that rode on it, exactly as
    # with real OpenSSH. This proves the fake models that (so the jump-pid
    # assertions elsewhere are not the only guard against a jump teardown).
    c.ok(not h.master_alive("aire", "jump"),
         "AIRE's tunnel survived the replacement of the jump master it rode on "
         "(the fake no longer binds tunnels to their jump master process)")

    # (b) The jump master dies WHILE the probe is in flight: the mux client
    # then exits 0 with no output, the same shape as a relayed clean close.
    # The follow-up `ssh -O check` must catch it and re-authenticate.
    old_jump_pid = h.jump_pid()
    rash_duo_before = h.duo_count(RASH)
    h.set_w_mode(calder_host, "kill-jump")
    try:
        jump = h.run_expect_jump("calder")
    finally:
        h.clear_w_mode(calder_host)
    c.ok(jump.returncode == 0, "jump leg after mid-probe death exit %d (%s)" % (
        jump.returncode, err(jump)))
    c.ok(h.jump_alive() and h.jump_pid() != old_jump_pid,
         "jump master that died mid-probe was not re-authenticated (%s -> %s)" % (
             old_jump_pid, h.jump_pid()))
    c.ok(h.duo_count(RASH) == rash_duo_before + 1,
         "mid-probe re-auth should cost exactly one rash Duo (before=%d, now=%d)" % (
             rash_duo_before, h.duo_count(RASH)))
    c.ok("stopped answering during the probe" in h.debug_log("calder"),
         "post-probe -O check did not fire (login_debug.log lacks the re-check event)")
    target = h.run_target_starter("calder", "jump")
    c.ok(target.returncode == 0, "Calder target after mid-probe re-auth exit %d (%s)" % (
        target.returncode, err(target)))
    c.ok(h.master_alive("calder", "jump"), "Calder master not alive after mid-probe re-auth")
    return c


def s6_wrong_password(h):
    c = Check()
    with throwaway("wrongpw", "WrongPW") as host:
        # Direct route: the target starter is the leg that authenticates, so
        # it is the leg that must reject with exit 13.
        target = h.run_target_starter("wrongpw", "direct", password=WRONG_PASSWORD)
        c.ok(target.returncode == 13, "wrong password (target leg) exit %d, want 13 (%s)" % (
            target.returncode, err(target)))
        c.ok(not h.master_alive("wrongpw", "direct"), "a master came up despite wrong password")
        c.ok(h.duo_count(host) == 0, "a Duo push was sent for a wrong password")

        # Rash route with no jump master yet: the expect jump leg is the one
        # that meets the password prompt, so it must reject with exit 13.
        spare_jump = os.path.join(h.ctl, "jump-wrongpw.sock")
        shared_jump_pid = h.jump_pid()
        jump = h.run_expect_jump("wrongpw", password=WRONG_PASSWORD,
                                 jump_control_path=spare_jump)
        c.ok(jump.returncode == 13, "wrong password (jump leg) exit %d, want 13 (%s)" % (
            jump.returncode, err(jump)))

        # Same, against a keyboard-interactive-only jump host (what AIRE,
        # Calder and rash actually are): no re-prompt, just "Permission
        # denied" — the jump leg must still report exit 13.
        with h.knobs(RASH, kbdint_only=""):
            spare_jump2 = os.path.join(h.ctl, "jump-wrongpw-kbd.sock")
            jump2 = h.run_expect_jump("wrongpw", password=WRONG_PASSWORD,
                                      jump_control_path=spare_jump2)
            c.ok(jump2.returncode == 13,
                 "wrong password (kbd-interactive-only jump leg) exit %d, want 13" % jump2.returncode)
        c.ok(not os.path.exists(spare_jump + ".state"),
             "a jump master came up despite wrong password")
        c.ok(h.jump_pid() == shared_jump_pid and h.jump_alive(),
             "the shared jump master was disturbed by a wrong-password login")

        # A stale exported HPC_PASSWORD (e.g. the app started from a shell
        # that once followed the manual instructions) must never override
        # the password on stdin — on either leg.
        stale = {"HPC_PASSWORD": STALE_ENV_PASSWORD}
        spare_jump3 = os.path.join(h.ctl, "jump-stale.sock")
        jump3 = h.run_expect_jump("wrongpw", jump_control_path=spare_jump3, extra=stale)
        c.ok(jump3.returncode == 0,
             "stale HPC_PASSWORD overrode stdin on the jump leg: exit %d (%s)" % (
                 jump3.returncode, err(jump3)))
        target3 = h.run_target_starter("wrongpw", "direct", extra=stale)
        c.ok(target3.returncode == 0,
             "stale HPC_PASSWORD overrode stdin on the target leg: exit %d (%s)" % (
                 target3.returncode, err(target3)))
        for path in (spare_jump3, h.control_path("wrongpw", "direct")):
            environ = _read_text(path + ".environ") or ""
            c.ok("HPC_PASSWORD" not in environ,
                 "HPC_PASSWORD reached the master environment at %s" % os.path.basename(path))
        h.run_stop("wrongpw", "direct")
    return c


def s7_password_never_leaks(h):
    c = Check()
    secrets = [s for s in h.secrets if s]
    # Scan every logged argv.
    leaked_argv = None
    for argv in h.invocations():
        joined = "\x00".join(argv)
        for secret in secrets:
            if secret in joined:
                leaked_argv = argv[:4]
    c.ok(leaked_argv is None, "a password was found in a logged ssh argv: %r" % leaked_argv)

    # Scan every runtime file (logs, pid files, events, debug logs).
    leaked_file = None
    for path in h.all_runtime_files():
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError:
            continue
        if any(secret.encode() in data for secret in secrets):
            leaked_file = path
            break
    c.ok(leaked_file is None, "a password was found in runtime file: %s" % leaked_file)
    leftovers = h.special_runtime_files()
    c.ok(not leftovers, "non-regular files (e.g. an askpass FIFO) left behind: %r" % leftovers)

    # Scan the daemonized masters' recorded environments...
    leaked_env = None
    for path in h.environ_files():
        try:
            with open(path) as fh:
                text = fh.read()
        except OSError:
            continue
        if any(secret in text for secret in secrets):
            leaked_env = path
            break
    c.ok(leaked_env is None, "a password was found in a master's environ file: %s" % leaked_env)

    # ...and cross-check every live master via `ps eww`.
    ps_leak = None
    for name in os.listdir(h.ctl):
        if not name.endswith(".state"):
            continue
        st = _read_state(os.path.join(h.ctl, name)) or {}
        pid = st.get("pid")
        if pid and _pid_alive(pid):
            environ = _ps_environ(pid)
            if any(secret in environ for secret in secrets):
                ps_leak = name
                break
    c.ok(ps_leak is None, "a password is visible in `ps eww` of master %s" % ps_leak)
    return c


def s8_target_refusal_keeps_jump(h):
    """The review regression: a target-side failure seen through a live jump
    master must never tear the shared jump master down."""
    c = Check()
    calder_host = CLUSTERS["calder"][1]

    # Precondition: AIRE tunnelled through a live jump master. (S5 replaced
    # the jump master, which took AIRE's old tunnel with it.)
    rash0 = h.duo_count(RASH)
    legs = h.app_login("aire", "jump")
    c.ok(all(p.returncode == 0 for p in legs.values()) and "target" in legs,
         "precondition: AIRE via jump failed")
    c.ok(h.duo_count(RASH) == rash0, "precondition: AIRE login re-authenticated the jump master")
    c.ok(h.master_alive("aire", "jump") and h.jump_alive(), "precondition: AIRE/jump not alive")

    for mode in ("refused", "penalized", "silent"):
        jump_pid = h.jump_pid()
        aire_pid = h.master_pid("aire", "jump")
        rash_before = h.duo_count(RASH)
        calder_before = h.duo_count(calder_host)
        h.set_w_mode(calder_host, mode)
        try:
            jump = h.run_expect_jump("calder")
            names = status_lines(jump)
            c.ok(jump.returncode == 0, "[%s] Calder jump leg exit %d (%s)" % (
                mode, jump.returncode, err(jump)))
            c.ok(h.jump_pid() == jump_pid and h.jump_alive(),
                 "[%s] shared jump master torn down (%s -> %s)" % (mode, jump_pid, h.jump_pid()))
            c.ok(h.duo_count(RASH) == rash_before,
                 "[%s] %d new rash Duo, want 0" % (mode, h.duo_count(RASH) - rash_before))
            c.ok(h.master_alive("aire", "jump") and h.master_pid("aire", "jump") == aire_pid,
                 "[%s] AIRE tunnel died (pid %s -> %s)" % (mode, aire_pid, h.master_pid("aire", "jump")))
            c.ok(any("jump host is up" in n for n in names),
                 "[%s] jump leg did not explain the target problem: %r" % (mode, names))
            if mode != "silent":
                # The target leg then meets the real error. It must fail, and
                # must not be misreported as a wrong password (exit 13), nor
                # tell the user to approve a push that is not coming.
                target = h.run_target_starter("calder", "jump")
                c.ok(target.returncode not in (0, 13, 15),
                     "[%s] Calder target exit %d, want a non-13/15 failure (%s)" % (
                         mode, target.returncode, err(target)))
                tnames = status_lines(target)
                c.ok(not any("duo" in n.lower() or "password sent" in n for n in tnames),
                     "[%s] the Calder leg claimed progress it never made: %r" % (mode, tnames))
                c.ok(h.duo_count(calder_host) == calder_before,
                     "[%s] a Calder Duo was requested despite the refusal" % mode)
                c.ok(h.jump_pid() == jump_pid and h.duo_count(RASH) == rash_before,
                     "[%s] Calder target leg disturbed the shared jump master" % mode)
                c.ok(h.master_alive("aire", "jump") and h.master_pid("aire", "jump") == aire_pid,
                     "[%s] AIRE tunnel died during the Calder target leg" % mode)
        finally:
            h.clear_w_mode(calder_host)
    return c


def _start_orphan_login(h, cid, host, delay_kind, seconds):
    h.set_knob(delay_kind, host, seconds)
    env = h.cluster_env(cid, "direct")
    starter = os.path.join(SCRIPTS, "hpc_start_target_master.zsh")
    proc = subprocess.Popen(
        ["/bin/zsh", starter], stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        env=env, cwd=PROJECT_ROOT, start_new_session=True)
    proc.stdin.write((PASSWORD + "\n").encode())
    proc.stdin.close()
    return proc, (delay_kind, host)


def _reap_orphan_login(h, proc, knob):
    if proc is not None:
        # The starter's pid is still unreaped here, so its pgid cannot have
        # been recycled: clear the fake ssh still sleeping in its delay.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.wait()
    if knob:
        h.clear_knob(*knob)


def s9_killed_starter_leaves_no_writer(h):
    """hpc_start_target_master.zsh serves the password ONCE from a forked
    writer subshell. (a) During the Duo wait the secret is already gone: no
    writer process, no FIFO. (b) If only the starter's pid is killed before
    ssh has asked for the password (not its process group, as the app would
    do), the writer must notice and exit — taking the FIFO with it — instead
    of lingering under launchd with the secret."""
    c = Check()
    with throwaway("orphan", "Orphan") as host:
        fifo = os.path.join(h.runtime_dir("orphan"), "askpass.fifo")
        proc = knob = None
        try:
            # (a) secret consumed before the Duo wait
            proc, knob = _start_orphan_login(h, "orphan", host, "duo_delay", 20)
            end = time.time() + scaled(10)
            while time.time() < end and h.duo_count(host) < 1:
                time.sleep(0.1)
            c.ok(h.duo_count(host) == 1, "precondition: the login never reached Duo")
            time.sleep(0.5)
            writers = _children_running(proc.pid, "hpc_start_target_master.zsh")
            c.ok(not writers, "password writer still alive during the Duo wait: %r" % writers)
            c.ok(not os.path.exists(fifo), "askpass FIFO still present during the Duo wait")
            _reap_orphan_login(h, proc, knob)
            proc = knob = None

            # (b) starter killed while the writer still holds the password
            proc, knob = _start_orphan_login(h, "orphan", host, "password_delay", 20)
            end = time.time() + scaled(10)
            writers = []
            while time.time() < end and not (writers and os.path.exists(fifo)):
                writers = _children_running(proc.pid, "hpc_start_target_master.zsh")
                time.sleep(0.1)
            c.ok(len(writers) == 1, "precondition: expected one password writer, found %r" % writers)
            c.ok(os.path.exists(fifo), "precondition: askpass FIFO missing before the password prompt")

            os.kill(proc.pid, signal.SIGKILL)   # the starter only, not its group
            end = time.time() + scaled(3)
            while time.time() < end and (any(_pid_alive(w) for w in writers) or os.path.exists(fifo)):
                time.sleep(0.1)
            survivors = [w for w in writers if _pid_alive(w)]
            c.ok(not survivors, "password writer outlived the killed starter: %r" % survivors)
            c.ok(not os.path.exists(fifo), "askpass FIFO left behind by the killed starter")
        finally:
            _reap_orphan_login(h, proc, knob)
    return c


def s10_duo_not_approved(h):
    """A push the user declines (or lets expire) means the PASSWORD WAS
    ACCEPTED. It must never surface as exit 13 — the app would warn about an
    account lockout and suggest changing a correct password — and pam_duo's
    re-prompt must never be answered with a second push."""
    c = Check()
    cases = [
        # mode, pam_duo prompts, push delay, words the message must contain
        ("deny", 3, 0, "declined"),
        ("deny", 1, 0, "accepted"),
        ("timeout", 3, 1, "in time"),
        ("grace", 3, 0.5, "accepted"),
    ]
    with throwaway("duo", "DuoTest") as host:
        shared_jump = h.jump_pid()
        for i, (mode, prompts, delay, words) in enumerate(cases):
            tag = "%s/prompts=%d" % (mode, prompts)
            settings = {"duo_mode": mode, "duo_prompts": prompts, "duo_delay": delay}
            with h.knobs(host, **settings):
                before = h.duo_count(host)
                target = h.run_target_starter("duo", "direct")
                c.ok(target.returncode == 15, "[%s] target leg exit %d, want 15 (%s)" % (
                    tag, target.returncode, err(target)))
                c.ok(h.duo_count(host) - before == 1, "[%s] target leg sent %d pushes, want 1" % (
                    tag, h.duo_count(host) - before))
                c.ok(words in target.stderr.decode("utf-8", "replace"),
                     "[%s] target message lacks %r: %s" % (tag, words, err(target)))
                c.ok(not h.master_alive("duo", "direct"), "[%s] a master came up" % tag)
            with h.knobs(RASH, **settings):
                spare = os.path.join(h.ctl, "jump-duo-%d.sock" % i)
                before = h.duo_count(RASH)
                jump = h.run_expect_jump("duo", jump_control_path=spare)
                c.ok(jump.returncode == 15, "[%s] jump leg exit %d, want 15 (%s)" % (
                    tag, jump.returncode, err(jump)))
                c.ok(h.duo_count(RASH) - before == 1, "[%s] jump leg sent %d pushes, want 1" % (
                    tag, h.duo_count(RASH) - before))
                c.ok(not h.jump_alive(spare), "[%s] a jump master came up" % tag)
        c.ok(h.jump_pid() == shared_jump and h.jump_alive(),
             "the shared jump master was disturbed by the Duo tests")
        c.ok(not h.live_processes_mentioning("duo.leeds.ac.uk"),
             "an ssh for the declined login is still running")
    return c


def s11_password_expired(h):
    c = Check()
    with throwaway("expired", "Expired") as host:
        for i, variant in enumerate(("after", "before", "rhel7")):
            with h.knobs(host, pw_change=variant):
                target = h.run_target_starter("expired", "direct")
                c.ok(target.returncode == 14, "[%s] target leg exit %d, want 14 (%s)" % (
                    variant, target.returncode, err(target)))
            with h.knobs(RASH, pw_change=variant):
                spare = os.path.join(h.ctl, "jump-expired-%d.sock" % i)
                jump = h.run_expect_jump("expired", jump_control_path=spare)
                c.ok(jump.returncode == 14, "[%s] jump leg exit %d, want 14 (%s)" % (
                    variant, jump.returncode, err(jump)))
        for name in (host, RASH):
            answered = [a for a in h.pw_change_answers(name) if a != "refused"]
            c.ok(not answered, "a password-change prompt on %s was answered: %r" % (name, answered))
    return c


def s12_reuse_instead_of_replace(h):
    c = Check()
    aire_host = CLUSTERS["aire"][1]
    calder_host = CLUSTERS["calder"][1]

    # (a) Connect on a live cluster: reuse, no Duo.
    c.ok(h.ensure_live("aire", "direct"), "precondition: AIRE direct not live")
    pid0 = h.master_pid("aire", "direct")
    duo0 = h.duo_count(aire_host)
    legs = h.app_login("aire", "direct", force=False)
    target = legs["target"]
    c.ok(target.returncode == 0, "non-forced login on a live master exit %d (%s)" % (
        target.returncode, err(target)))
    c.ok(h.master_pid("aire", "direct") == pid0, "the healthy master was replaced")
    c.ok(h.duo_count(aire_host) == duo0, "reusing a healthy master cost a Duo push")
    c.ok(any("reusing" in n for n in status_lines(target)), "no 'reusing' status line")
    c.ok("auth_ok|" in target.stdout.decode("utf-8", "replace"), "reuse did not print auth_ok")
    # The app saves a typed password only when a leg says it sent one; a
    # reused master never had it checked.
    c.ok(not any("password sent" in n for n in status_lines(target)),
         "a reused master announced a password it never sent: %r" % status_lines(target))

    # (b) The real loss case: Calder's round-robin lands on a node that
    # refuses new connections. A non-forced Connect keeps the healthy
    # session instead of tearing it down for a login that cannot succeed.
    legs = h.app_login("calder", "jump")
    c.ok(all(p.returncode == 0 for p in legs.values()) and "target" in legs,
         "precondition: Calder via jump failed")
    calder_pid = h.master_pid("calder", "jump")
    duo_c, duo_r = h.duo_count(calder_host), h.duo_count(RASH)
    h.set_w_mode(calder_host, "penalized")
    try:
        legs = h.app_login("calder", "jump", force=False)
    finally:
        h.clear_w_mode(calder_host)
    c.ok(all(p.returncode == 0 for p in legs.values()) and "target" in legs,
         "non-forced Calder login while the node refuses failed: %r" % {
             k: (p.returncode, err(p, 120)) for k, p in legs.items()})
    c.ok(h.master_alive("calder", "jump") and h.master_pid("calder", "jump") == calder_pid,
         "the healthy Calder session was lost to a refusing login node")
    c.ok(h.duo_count(calder_host) == duo_c and h.duo_count(RASH) == duo_r,
         "the non-forced Calder login cost a Duo push")
    c.ok(not any("password sent" in n for p in legs.values() for n in status_lines(p)),
         "a sign-in that reused both masters announced a password it never sent")

    # (c) A master whose socket answers but which runs no command (a dead
    # link, or a login node too slow to answer within 15 s — the two look
    # the same) is never torn down by a plain sign-in: it may still carry
    # the user's terminals. Exit 5, no password, no Duo, master untouched.
    # The confirmed Reconnect (a forced login) replaces it: one Duo.
    h.wedge(h.control_path("aire", "direct"))
    wedged_pid = h.master_pid("aire", "direct")
    duo0 = h.duo_count(aire_host)
    legs = h.app_login("aire", "direct", force=False)
    target = legs["target"]
    c.ok(target.returncode == 5, "a plain sign-in over an unanswering master exit %d, want 5 (%s)" % (
        target.returncode, err(target)))
    c.ok(h.master_pid("aire", "direct") == wedged_pid and _pid_alive(wedged_pid),
         "a plain sign-in tore down a master that still answers its socket")
    c.ok(h.duo_count(aire_host) == duo0, "the plain sign-in over an unanswering master cost a Duo push")
    c.ok(not any("password sent" in n or "starting" in n for n in status_lines(target)),
         "a plain sign-in started authenticating over an unanswering master: %r" % status_lines(target))
    c.ok("Reconnect" in err(target, 2000), "exit 5 does not point to Reconnect: %s" % err(target, 2000))
    legs = h.app_login("aire", "direct", force=True)
    c.ok(legs["target"].returncode == 0, "the forced replace of an unanswering master exit %d (%s)" % (
        legs["target"].returncode, err(legs["target"])))
    c.ok("password sent (AIRE)" in status_lines(legs["target"]),
         "a fresh login did not say it sent the password: %r" % status_lines(legs["target"]))
    c.ok(h.master_alive("aire", "direct") and h.master_pid("aire", "direct") != wedged_pid,
         "the forced login did not replace the unanswering master")
    c.ok(_wait_dead(wedged_pid), "the replaced master process is still running")
    c.ok(h.duo_count(aire_host) == duo0 + 1, "replacing the unanswering master cost %d Duo, want 1" % (
        h.duo_count(aire_host) - duo0))

    # (d) A master from an older release still carries its permanent
    # `sleep 2147483647` session (so it never idles out). Reusing it ends
    # that session client and keeps the master.
    cp = h.control_path("aire", "direct")
    legacy = h.spawn_legacy_session_client(cp, aire_host)
    pid0 = h.master_pid("aire", "direct")
    legs = h.app_login("aire", "direct", force=False)
    c.ok(legs["target"].returncode == 0, "reuse with a legacy session client exit %d" %
         legs["target"].returncode)
    c.ok(_wait_dead(legacy), "the old release's permanent session client is still running")
    c.ok(h.master_alive("aire", "direct") and h.master_pid("aire", "direct") == pid0,
         "ending the legacy session client took the master with it")

    # (f) HPC_REUSE_ONLY=1 (the app adopting, at startup, a session an older
    # release left running): no password, no Duo, no teardown; retires that
    # release's keepalive and permanent session client; exit 4 when there is
    # nothing to adopt.
    keepalive = h.spawn_legacy_keepalive(cp, aire_host)
    legacy = h.spawn_legacy_session_client(cp, aire_host)
    pid0 = h.master_pid("aire", "direct")
    duo0 = h.duo_count(aire_host)
    adopt = h.run_target_starter("aire", "direct", password="", extra={"HPC_REUSE_ONLY": "1"})
    c.ok(adopt.returncode == 0, "reuse-only adopt exit %d (%s)" % (adopt.returncode, err(adopt)))
    c.ok(h.master_pid("aire", "direct") == pid0 and h.duo_count(aire_host) == duo0,
         "reuse-only replaced the master or sent a push")
    c.ok(_wait_dead(keepalive) and _wait_dead(legacy),
         "reuse-only left an old release's keepalive or session client running")
    with throwaway("noadopt", "NoAdopt") as host:
        miss = h.run_target_starter("noadopt", "direct", password="",
                                    extra={"HPC_REUSE_ONLY": "1"})
        c.ok(miss.returncode == 4, "reuse-only without a master exit %d, want 4" % miss.returncode)
        c.ok(h.duo_count(host) == 0, "reuse-only started a login")

    # (e) Progress is reported in the order the server asks for it: never
    # "waiting for Duo approval" before the Duo prompt exists.
    with throwaway("slowduo", "SlowDuo") as host:
        with h.knobs(host, duo_delay=1.5):
            target = h.run_target_starter("slowduo", "direct")
        names = status_lines(target)
        c.ok(target.returncode == 0, "slow-Duo login exit %d (%s)" % (target.returncode, err(target)))

        def index(fragment):
            for i, n in enumerate(names):
                if fragment in n:
                    return i
            return -1
        order = [index("starting SlowDuo authentication"), index("password sent (SlowDuo)"),
                 index("waiting for Duo approval on your phone (SlowDuo)"),
                 index("connected to SlowDuo")]
        c.ok(all(i >= 0 for i in order) and order == sorted(order),
             "status lines out of order or missing: %r" % names)
        h.run_stop("slowduo", "direct")
    return c


def s13_timeouts(h):
    c = Check()
    with throwaway("slow", "Slow") as host:
        # (a) A server that never asks for the password: 124, quickly.
        with h.knobs(host, password_delay=20):
            t0 = time.time()
            target = h.run_target_starter("slow", "direct", extra={"HPC_TIMEOUT": "2"})
            took = time.time() - t0
        c.ok(target.returncode == 124, "silent server (target leg) exit %d, want 124 (%s)" % (
            target.returncode, err(target)))
        c.ok(took < 10, "the target leg took %.1fs to give up (HPC_TIMEOUT=2)" % took)
        c.ok(not os.path.exists(os.path.join(h.runtime_dir("slow"), "askpass.fifo")),
             "askpass FIFO left behind after the timeout")
        # (b) A push that is never answered: the password WAS accepted -> 15.
        with h.knobs(host, duo_mode="hang"):
            target = h.run_target_starter("slow", "direct", extra={"HPC_TIMEOUT": "3"})
        c.ok(target.returncode == 15, "unanswered push (target leg) exit %d, want 15 (%s)" % (
            target.returncode, err(target)))
        # (c)/(d) the same on the expect jump leg.
        with h.knobs(RASH, password_delay=20):
            jump = h.run_expect_jump("slow", jump_control_path=os.path.join(h.ctl, "jump-slow1.sock"),
                                     extra={"HPC_TIMEOUT": "2"})
        c.ok(jump.returncode == 124, "silent server (jump leg) exit %d, want 124 (%s)" % (
            jump.returncode, err(jump)))
        with h.knobs(RASH, duo_mode="hang"):
            jump = h.run_expect_jump("slow", jump_control_path=os.path.join(h.ctl, "jump-slow2.sock"),
                                     extra={"HPC_TIMEOUT": "3"})
        c.ok(jump.returncode == 15, "unanswered push (jump leg) exit %d, want 15 (%s)" % (
            jump.returncode, err(jump)))
        time.sleep(0.5)
        c.ok(not h.live_processes_mentioning("slow.leeds.ac.uk"),
             "an ssh for a timed-out login is still running: %r" %
             h.live_processes_mentioning("slow.leeds.ac.uk"))
        c.ok(not h.live_processes_mentioning("jump-slow"),
             "a jump ssh for a timed-out login is still running")
    return c


def s14_special_character_password(h):
    c = Check()
    h.secrets.append(TRICKY_PASSWORD)
    h.set_expected_password(TRICKY_PASSWORD)
    try:
        with throwaway("special", "Special"):
            target = h.run_target_starter("special", "direct", password=TRICKY_PASSWORD)
            c.ok(target.returncode == 0, "tricky password (target leg) exit %d (%s)" % (
                target.returncode, err(target)))
            spare = os.path.join(h.ctl, "jump-special.sock")
            jump = h.run_expect_jump("special", password=TRICKY_PASSWORD, jump_control_path=spare)
            c.ok(jump.returncode == 0, "tricky password (jump leg) exit %d (%s)" % (
                jump.returncode, err(jump)))
            h.run_stop("special", "direct")
    finally:
        h.set_expected_password(PASSWORD)
    return c


def s15_stop_master(h):
    c = Check()
    aire_host = CLUSTERS["aire"][1]
    for cid, route in (("aire", "direct"), ("aire", "jump"), ("calder", "jump")):
        c.ok(h.ensure_live(cid, route), "precondition: %s/%s not live" % (cid, route))
    direct_pid = h.master_pid("aire", "direct")
    jump_route_pid = h.master_pid("aire", "jump")
    calder_pid = h.master_pid("calder", "jump")
    shared_jump = h.jump_pid()
    cp_direct = h.control_path("aire", "direct")
    cp_jump = h.control_path("aire", "jump")

    # Every master the scripts start runs -N, so — as with real OpenSSH,
    # which retitles a master "ssh: <socket> [mux]" only when it detaches
    # from a session — it keeps its argv as its process title. The jump
    # master's own argv names the jump socket and carries ControlMaster=yes,
    # the shape that once made it count as its own rider; a tunnelled
    # cluster master names the jump socket inside its ProxyCommand.
    jump_title = _ps_command(shared_jump)
    c.ok(jump_title.startswith("ssh ") and "[mux]" not in jump_title
         and ("ControlPath=" + h.jump_control_path()) in jump_title
         and "ControlMaster=yes" in jump_title,
         "the jump master is not titled like a real -N master: %r" % jump_title[:200])
    calder_title = _ps_command(calder_pid)
    c.ok(calder_title.startswith("ssh ") and "[mux]" not in calder_title
         and ("ControlPath=" + h.control_path("calder", "jump")) in calder_title
         and h.jump_control_path() in calder_title,
         "Calder's tunnelled master is not titled like a real -N master: %r" % calder_title[:200])

    # Leftovers of an older release: a keepalive per route, the shared
    # keepalive.pid naming the direct one.
    keep_direct = h.spawn_legacy_keepalive(cp_direct, aire_host)
    keep_jump = h.spawn_legacy_keepalive(cp_jump, aire_host)
    with open(os.path.join(h.runtime_dir("aire"), "keepalive.pid"), "w") as fh:
        fh.write("%d\n" % keep_direct)

    # Stop AIRE's direct-route identity (what the app does on a route or
    # username change, and on Disconnect).
    stop = h.run_stop("aire", "direct")
    c.ok(stop.returncode == 0, "stop exit %d (%s)" % (stop.returncode, err(stop)))
    c.ok(any("stopped the AIRE session" in n for n in status_lines(stop)),
         "stop did not report stopping: %r" % status_lines(stop))
    c.ok(_wait_dead(direct_pid), "AIRE's direct master is still running")
    c.ok(not os.path.exists(cp_direct), "AIRE's direct socket was left behind")
    c.ok(not os.path.exists(h.pid_file("aire", "direct")), "the direct pid file was left behind")
    c.ok(_wait_dead(keep_direct), "the direct route's legacy keepalive survived")
    c.ok(not os.path.exists(os.path.join(h.runtime_dir("aire"), "keepalive.pid")),
         "the legacy keepalive.pid naming the stopped keepalive was left behind")
    # ...and nothing else.
    c.ok(h.master_alive("aire", "jump") and h.master_pid("aire", "jump") == jump_route_pid,
         "stopping the direct route took AIRE's jump-route master too")
    c.ok(_read_text(h.pid_file("aire", "jump")) == str(jump_route_pid),
         "stopping the direct route erased the jump route's pid record")
    c.ok(_pid_alive(keep_jump), "stopping the direct route killed the jump route's keepalive")
    c.ok(h.master_alive("calder", "jump") and h.master_pid("calder", "jump") == calder_pid,
         "stopping AIRE disturbed Calder")
    c.ok(h.jump_alive() and h.jump_pid() == shared_jump, "stopping AIRE disturbed the jump master")

    again = h.run_stop("aire", "direct")
    c.ok(again.returncode == 0 and any("no AIRE session was running" in n
                                       for n in status_lines(again)),
         "a second stop did not report 'nothing running' with exit 0: %d %r" % (
             again.returncode, status_lines(again)))

    # Refuse to stop the shared jump master as if it were a cluster's.
    bad = h.run_stop("aire", "jump", extra={"HPC_CONTROL_PATH": h.jump_control_path()})
    c.ok(bad.returncode == 2, "stopping the jump socket as a cluster exit %d, want 2" % bad.returncode)
    c.ok(h.jump_alive() and h.jump_pid() == shared_jump, "the refused stop hurt the jump master")

    # A login on the jump route ends the legacy keepalive of ITS path.
    legs = h.app_login("aire", "jump", force=False)
    c.ok(legs.get("target") is not None and legs["target"].returncode == 0,
         "non-forced AIRE jump login failed")
    c.ok(_wait_dead(keep_jump), "a login did not stop its own path's legacy keepalive")

    # The jump master is stopped on request only once nothing rides on it.
    flag = {"HPC_STOP_JUMP_IF_UNUSED": "1"}
    first = h.run_stop("aire", "jump", extra=flag)
    c.ok(first.returncode == 0, "stop AIRE (jump) exit %d (%s)" % (first.returncode, err(first)))
    c.ok(not h.master_alive("aire", "jump"), "AIRE's jump-route master survived its stop")
    c.ok(h.jump_alive() and h.jump_pid() == shared_jump,
         "the jump master was stopped while Calder still rode on it")
    c.ok(h.master_alive("calder", "jump"), "Calder's tunnel died when AIRE signed out")
    c.ok(any("kept the shared jump-host session" in n for n in status_lines(first)),
         "the kept jump master was not reported: %r" % status_lines(first))
    second = h.run_stop("calder", "jump", extra=flag)
    c.ok(second.returncode == 0, "stop Calder (jump) exit %d (%s)" % (second.returncode, err(second)))
    c.ok(not h.master_alive("calder", "jump"), "Calder's master survived its stop")
    # Nothing rides on it now; its own argv (which names the jump socket)
    # must not count as a rider.
    c.ok(any("stopped the shared jump-host session" in n for n in status_lines(second)),
         "the unused jump master was not reported stopped: %r" % status_lines(second))
    c.ok(_wait_dead(shared_jump), "the unused jump master was not stopped")
    c.ok(not os.path.exists(h.jump_control_path()), "the jump socket was left behind")
    no_keepalive_anywhere(h, c, "calder")

    # Disconnect while a sign-in is still waiting for Duo: the authenticating
    # ssh (argv shape, not yet a detached master) is stopped too.
    with throwaway("pending", "Pending") as host:
        proc = knob = None
        try:
            proc, knob = _start_orphan_login(h, "pending", host, "duo_delay", 20)
            end = time.time() + scaled(10)
            while time.time() < end and h.duo_count(host) < 1:
                time.sleep(0.1)
            cp = h.control_path("pending", "direct")
            pending = [pid for pid in h.live_processes_mentioning("ControlPath=" + cp)
                       if "ControlMaster=yes" in _ps_command(pid)]
            c.ok(pending, "precondition: no authenticating ssh found for the pending login")
            stop = h.run_stop("pending", "direct")
            c.ok(stop.returncode == 0, "stop during sign-in exit %d (%s)" % (
                stop.returncode, err(stop)))
            c.ok(all(_wait_dead(pid) for pid in pending),
                 "the authenticating ssh survived the stop")
            try:
                code = proc.wait(timeout=scaled(10))
            except subprocess.TimeoutExpired:
                code = None
            c.ok(code not in (None, 0), "the interrupted sign-in reported %r" % code)
            c.ok(not h.master_alive("pending", "direct"), "a master came up after the stop")
        finally:
            _reap_orphan_login(h, proc, knob)
    return c


def s16_option_sets(h):
    """Static facts about every ssh the scripts ran during the suite."""
    c = Check()
    sys.path.insert(0, HERE)
    sys.dont_write_bytecode = True   # never litter scripts/tests/__pycache__
    try:
        import fake_ssh  # noqa: E402 - the fake's own argv parser
    finally:
        sys.path.pop(0)
    argvs = h.invocations()
    c.ok(argvs, "no ssh invocations were logged")
    for argv in argvs:
        if "ControlMaster=auto" in argv:
            c.ok(False, "an ssh ran with ControlMaster=auto: %r" % argv[:8])
            break
    creations = [a for a in argvs if "ControlMaster=yes" in a and "--__master__" not in a]
    c.ok(creations, "no master creations were logged")
    problems = set()
    for argv in creations:
        parsed = fake_ssh.parse_args(argv)
        if not parsed.want_N or parsed.command:
            problems.add("a master was started with a remote command / without -N "
                         "(e.g. %s: %r)" % (parsed.host, parsed.command))
        proxy = parsed.options.get("ProxyCommand", "")
        if proxy and proxy != "none":
            for needed in ("BatchMode=yes", "PubkeyAuthentication=no", "GSSAPIAuthentication=no",
                           "PasswordAuthentication=no", "KbdInteractiveAuthentication=no",
                           "ConnectTimeout=", "ControlMaster=no", "-W %h:%p"):
                if needed not in proxy:
                    problems.add("the ProxyCommand lacks %s" % needed)
    for problem in sorted(problems):
        c.ok(False, problem)
    with open(os.path.join(SCRIPTS, "hpc_snapshot.py")) as fh:
        collector = fh.read()
    for needed in ("ControlMaster=no", "BatchMode=yes"):
        c.ok(needed in collector, "the collector no longer sets %s" % needed)
    return c


# S7 deliberately runs last so its leak scan covers every login performed by
# the suite; the table is printed in ID order.
SCENARIOS = [
    ("S1", "direct login AIRE (-N master, no keepalive)", s1_direct_aire),
    ("S2", "direct Calder while AIRE alive", s2_direct_calder_while_aire),
    ("S3", "rash route reuses jump master", s3_rash_reuses_jump),
    ("S4", "forced AIRE relogin keeps jump+Calder", s4_force_relogin_keeps_jump_and_calder),
    ("S5", "wedged / mid-probe-dead jump re-authenticated", s5_dead_jump_reauth),
    ("S6", "wrong password -> 13; stale env never wins", s6_wrong_password),
    ("S8", "Calder refusal keeps shared jump + AIRE", s8_target_refusal_keeps_jump),
    ("S9", "killed starter leaves no password writer", s9_killed_starter_leaves_no_writer),
    ("S10", "Duo declined/timed out -> 15, one push", s10_duo_not_approved),
    ("S11", "expired password -> 14, never answered", s11_password_expired),
    ("S12", "non-forced login reuses a healthy master", s12_reuse_instead_of_replace),
    ("S13", "HPC_TIMEOUT -> 124 / 15, nothing left", s13_timeouts),
    ("S14", "special-character password", s14_special_character_password),
    ("S15", "stop helper: one route, jump only if unused", s15_stop_master),
    ("S16", "ssh option sets", s16_option_sets),
    ("S18", "Renew all replaces a healthy jump master", s18_renew_replaces_healthy_jump),
    ("S7", "password never leaks", s7_password_never_leaks),
]


def interpreter_keeps_argv0():
    """The fake ssh and the impersonators exec the interpreter with argv[0]
    = "ssh" so ps shows them the way the scripts' kill rules expect (see
    fake_ssh.exec_interpreter). Checked once the probe's interpreter is up
    and printing, after any launcher has re-executed: a replaced argv[0]
    would make every title-based scenario fail for reasons that have
    nothing to do with the scripts."""
    probe = subprocess.Popen(["ssh-argv0-probe", "-c",
                              "import sys, time; print('ready', flush=True); time.sleep(10)"],
                             executable=fake_ssh.exec_interpreter(),
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        probe.stdout.readline()
        title = subprocess.run(["ps", "-o", "command=", "-p", str(probe.pid)],
                               capture_output=True, text=True).stdout.strip()
        return title.startswith("ssh-argv0-probe"), title
    finally:
        probe.kill()
        probe.wait()


def main():
    only = set(sys.argv[1:])
    keeps, title = interpreter_keeps_argv0()
    if not keeps:
        print("error: %s replaces argv[0] when it starts (ps shows %r), so the fake ssh cannot "
              "look like ssh to the scripts." % (fake_ssh.exec_interpreter(), title), file=sys.stderr)
        return 2
    h = Harness()
    results = []
    try:
        for sid, desc, fn in SCENARIOS:
            if only and sid not in only:
                continue
            started = time.time()
            try:
                check = fn(h)
                results.append((sid, desc, check.passed(), check.failures, time.time() - started))
            except Exception as exc:  # noqa: BLE001 - report, keep going
                import traceback
                results.append((sid, desc, False,
                                [traceback.format_exc().strip().splitlines()[-1]
                                 + " :: " + str(exc)], time.time() - started))
    finally:
        h.teardown()

    results.sort(key=lambda r: int(r[0][1:]))
    width = max(len(d) for _, d, _, _, _ in results)
    print("\n%-4s %-*s  %-6s %s" % ("ID", width, "scenario", "result", "time"))
    print("-" * (4 + width + 18))
    all_ok = True
    for sid, desc, ok, failures, took in results:
        print("%-4s %-*s  %-6s %4.1fs" % (sid, width, desc, "PASS" if ok else "FAIL", took))
        if not ok:
            all_ok = False
            for f in failures:
                print("       - %s" % f)
    print()
    print("OVERALL:", "PASS" if all_ok else "FAIL")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
