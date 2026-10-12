#!/usr/bin/env python3
"""Multi-cluster login-flow tests for the REAL hpc_* login scripts.

A fake `ssh` (fake_ssh.py) is placed first on PATH and the genuine
scripts/hpc_* helpers are driven exactly the way Sources/.../MonitorService.swift
drives them:

  * rash route: hpc_ssh_login.expect with HPC_SKIP_TARGET=1 (jump leg only),
    then hpc_start_target_master.zsh for the target;
  * direct route: hpc_start_target_master.zsh only.

The password is always handed over on the first line of stdin, and
HPC_FORCE_RELOGIN=1 is always set, as the app does.

Scenarios (see the PASS/FAIL table at the end):
  S1  direct login "AIRE"
  S2  direct login "Calder" while AIRE is alive
  S3  rash route: AIRE via jump, then Calder via jump (jump master reused)
  S4  forced re-login of AIRE via jump while Calder is alive
  S5  wedged jump master, and a jump master that dies mid-probe, are
      re-authenticated (and the tunnels that rode on them die with them)
  S6  wrong password -> exit 13 from the leg that rejected it (target leg on
      the direct route, jump leg on the rash route)
  S7  the password never appears in any argv, runtime file, or master environ
      (runs LAST so its scan covers every login the suite performed)
  S8  Calder refusing rash's channel ("Session open refused by peer"), the
      sshd "Not allowed at this time" drop, and a silent Calder all keep the
      shared jump master (same pid, no rash Duo) and AIRE's tunnel alive
  S9  the password is served once: no writer/FIFO survives into the Duo
      wait, and killing ONLY the starter's pid before the password prompt
      leaves no password-writer process and no askpass FIFO behind

Nothing here touches ~/.ssh or the user's real sessions: every control
socket, runtime directory and log lives under a private temp work dir. Each
script leg runs in its own process group, which is killed on timeout, and
teardown only kills processes whose argv or launch environment mentions
that work dir (every process the harness starts inherits HPC_FAKE_HOME).

Run:  scripts/tests/test_login_flow.py        (from anywhere)
      python3 scripts/tests/test_login_flow.py
"""

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
PROJECT_ROOT = os.path.dirname(os.path.dirname(HERE))
SCRIPTS = os.path.join(PROJECT_ROOT, "scripts")

USERNAME = "abcd1234"
RASH = "rash.leeds.ac.uk"
PASSWORD = "Tr0ub4dour-SECRET-pw-9271"
WRONG_PASSWORD = "definitely-not-it"
PROBE_TIMEOUT = "2"          # seconds the jump probe waits (keep tests quick)

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
        # The fake's expected ("correct") password lives in a file, never an
        # env var, so it never lands in a daemonized master's environment.
        with open(os.path.join(self.work, "expected_password"), "w") as fh:
            fh.write(PASSWORD + "\n")

    # -- paths ------------------------------------------------------------
    def control_path(self, cluster_id):
        return os.path.join(self.ctl, "%s.sock" % cluster_id)

    def jump_control_path(self):
        return os.path.join(self.ctl, "jump.sock")

    def runtime_dir(self, cluster_id):
        return os.path.join(self.work, "runtime", "clusters", cluster_id)

    # -- environment ------------------------------------------------------
    def base_env(self):
        env = dict(os.environ)
        env["PATH"] = self.bin + os.pathsep + env.get("PATH", "")
        env["HPC_FAKE_HOME"] = self.work
        env["HPC_PROJECT_ROOT"] = PROJECT_ROOT
        env["HPC_JUMP_PROBE_TIMEOUT"] = PROBE_TIMEOUT
        # Make sure no inherited DISPLAY/askpass leaks in from the real shell.
        env.pop("SSH_ASKPASS", None)
        env.pop("SSH_ASKPASS_REQUIRE", None)
        return env

    def cluster_env(self, cluster_id, route, force=True):
        label, host = CLUSTERS[cluster_id]
        env = self.base_env()
        env["HPC_USERNAME"] = USERNAME
        env["HPC_HOSTNAME"] = host
        env["HPC_TARGET_LABEL"] = label
        env["HPC_DUO_OPTION"] = "1"
        env["HPC_TIMEOUT"] = "30"
        env["HPC_CONTROL_PATH"] = self.control_path(cluster_id)
        env["HPC_RUNTIME_DIR"] = self.runtime_dir(cluster_id)
        env["HPC_LOGIN_DEBUG_LOG"] = os.path.join(self.runtime_dir(cluster_id), "login_debug.log")
        env["HPC_FORCE_RELOGIN"] = "1" if force else "0"
        if route == "jump":
            env["HPC_USE_JUMP_HOST"] = "1"
            env["HPC_JUMP_HOSTNAME"] = RASH
            env["HPC_JUMP_CONTROL_PATH"] = self.jump_control_path()
        else:
            env["HPC_USE_JUMP_HOST"] = "0"
        os.makedirs(self.runtime_dir(cluster_id), exist_ok=True)
        return env

    # -- running the real scripts ----------------------------------------
    def run_expect_jump(self, cluster_id, route, password=PASSWORD, jump_control_path=None):
        env = self.cluster_env(cluster_id, route)
        env["HPC_SKIP_TARGET"] = "1"
        if jump_control_path:
            env["HPC_JUMP_CONTROL_PATH"] = jump_control_path
        helper = os.path.join(SCRIPTS, "hpc_ssh_login.expect")
        return self._run(["/usr/bin/expect", helper], env, password)

    def run_target_starter(self, cluster_id, route, password=PASSWORD):
        env = self.cluster_env(cluster_id, route)
        starter = os.path.join(SCRIPTS, "hpc_start_target_master.zsh")
        return self._run(["/bin/zsh", starter], env, password)

    def app_login(self, cluster_id, route, password=PASSWORD):
        """Mirror MonitorService.login: jump leg (rash only) then target."""
        legs = {}
        if route == "jump":
            legs["jump"] = self.run_expect_jump(cluster_id, route, password)
            if legs["jump"].returncode != 0:
                return legs
        legs["target"] = self.run_target_starter(cluster_id, route, password)
        return legs

    def _run(self, argv, env, password, timeout=30):
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
            out, err = proc.communicate((password + "\n").encode(), timeout=timeout)
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

    # -- inspection -------------------------------------------------------
    def master_state(self, cluster_id):
        return _read_state(self.control_path(cluster_id) + ".state")

    def jump_state(self):
        return _read_state(self.jump_control_path() + ".state")

    def master_pid(self, cluster_id):
        st = self.master_state(cluster_id)
        return st.get("pid") if st else None

    def jump_pid(self):
        st = self.jump_state()
        return st.get("pid") if st else None

    def master_alive(self, cluster_id):
        pid = self.master_pid(cluster_id)
        return pid is not None and _pid_alive(pid) and os.path.exists(self.control_path(cluster_id))

    def jump_alive(self):
        pid = self.jump_pid()
        return pid is not None and _pid_alive(pid) and os.path.exists(self.jump_control_path())

    def duo_count(self, host):
        path = os.path.join(self.logs, "duo", host.replace("/", "_") + ".log")
        try:
            with open(path) as fh:
                return sum(1 for _ in fh)
        except OSError:
            return 0

    def wait_keepalive_pid(self, cluster_id, deadline=6.0):
        path = os.path.join(self.runtime_dir(cluster_id), "keepalive.pid")
        end = time.time() + deadline
        while time.time() < end:
            try:
                with open(path) as fh:
                    pid = int(fh.read().strip())
                if _pid_alive(pid):
                    return pid
            except (OSError, ValueError):
                pass
            time.sleep(0.1)
        return None

    def keepalive_argv(self, pid):
        return _ps_command(pid)

    def set_w_mode(self, host, mode):
        """Tell the fake how the far end answers when rash opens host:22."""
        d = os.path.join(self.work, "w_mode")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, host), "w") as fh:
            fh.write(mode + "\n")

    def clear_w_mode(self, host):
        try:
            os.remove(os.path.join(self.work, "w_mode", host))
        except OSError:
            pass

    def debug_log(self, cluster_id):
        try:
            with open(os.path.join(self.runtime_dir(cluster_id), "login_debug.log")) as fh:
                return fh.read()
        except OSError:
            return ""

    def wedge_jump(self):
        """Simulate a wedged jump master: pid still alive and -O check still
        passes, but every -W channel through it hangs."""
        st = self.jump_state()
        st["wedged"] = True
        with open(self.jump_control_path() + ".state", "w") as fh:
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
        out = []
        for name in os.listdir(self.ctl):
            if name.endswith(".environ"):
                out.append(os.path.join(self.ctl, name))
        return out

    # -- teardown ---------------------------------------------------------
    def teardown(self):
        # Kill only processes whose argv or launch environment mentions our
        # work dir — never the user's real ssh/keepalive, which reference
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


def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False


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


def s1_direct_aire(h):
    c = Check()
    legs = h.app_login("aire", "direct")
    target = legs["target"]
    c.ok(target.returncode == 0, "exit %d != 0 (%s)" % (
        target.returncode, target.stderr.decode('utf-8', 'replace')[:200]))
    names = status_lines(target)
    c.ok(any("AIRE" in n for n in names), "no HPC-STATUS line named AIRE: %r" % names)
    c.ok(h.master_alive("aire"), "AIRE master not alive")
    kp = h.wait_keepalive_pid("aire")
    c.ok(kp is not None, "AIRE keepalive did not start")
    if kp:
        argv = h.keepalive_argv(kp)
        c.ok("hpc_target_keepalive.zsh" in argv and h.control_path("aire") in argv,
             "keepalive argv wrong: %s" % argv)
    # pid/log files only under AIRE's runtime dir
    c.ok(os.path.exists(os.path.join(h.runtime_dir("aire"), "master_ssh.pid")),
         "AIRE master_ssh.pid missing")
    c.ok(not os.path.isdir(h.runtime_dir("calder")) or not os.listdir(h.runtime_dir("calder")),
         "Calder runtime dir unexpectedly populated")
    return c


def s2_direct_calder_while_aire(h):
    c = Check()
    aire_pid = h.master_pid("aire")
    aire_kp = h.wait_keepalive_pid("aire")
    legs = h.app_login("calder", "direct")
    target = legs["target"]
    c.ok(target.returncode == 0, "Calder exit %d != 0 (%s)" % (
        target.returncode, target.stderr.decode('utf-8', 'replace')[:200]))
    c.ok(h.master_alive("calder"), "Calder master not alive")
    c.ok(h.master_alive("aire"), "AIRE master died during Calder login")
    c.ok(h.master_pid("aire") == aire_pid, "AIRE master pid changed (%s -> %s)" % (
        aire_pid, h.master_pid("aire")))
    c.ok(aire_kp is not None and _pid_alive(aire_kp),
         "AIRE keepalive died during Calder login")
    names = status_lines(target)
    c.ok(any("Calder" in n for n in names), "no HPC-STATUS line named Calder: %r" % names)
    return c


def s3_rash_reuses_jump(h):
    c = Check()
    # Duo prompts accumulate across the whole run (S1 already logged into AIRE
    # directly, etc.), so every assertion here is on the DELTA caused by this
    # scenario's logins, not the running totals.
    rash0 = h.duo_count(RASH)
    aire0 = h.duo_count(CLUSTERS["aire"][1])
    calder0 = h.duo_count(CLUSTERS["calder"][1])

    # AIRE via jump: fresh jump master (1 rash Duo) + AIRE target (1 AIRE Duo).
    legs = h.app_login("aire", "jump")
    c.ok(legs["jump"].returncode == 0, "AIRE jump leg exit %d" % legs["jump"].returncode)
    c.ok(legs["target"].returncode == 0, "AIRE target exit %d (%s)" % (
        legs["target"].returncode, legs["target"].stderr.decode('utf-8', 'replace')[:200]))
    c.ok(h.jump_alive(), "jump master not alive after AIRE")
    c.ok(h.master_alive("aire"), "AIRE master not alive (jump route)")
    jump_pid = h.jump_pid()
    rash_d = h.duo_count(RASH) - rash0
    aire_d = h.duo_count(CLUSTERS["aire"][1]) - aire0
    c.ok(rash_d == 1, "rash Duo prompts for AIRE-via-jump = %d, want 1" % rash_d)
    c.ok(aire_d == 1, "AIRE Duo prompts = %d, want 1" % aire_d)
    c.ok(rash_d + aire_d == 2, "AIRE-via-jump total Duo = %d, want 2" % (rash_d + aire_d))

    # Calder via jump: jump must be REUSED (same pid, no new rash Duo).
    rash1 = h.duo_count(RASH)
    legs = h.app_login("calder", "jump")
    jump_names = status_lines(legs["jump"])
    c.ok(legs["jump"].returncode == 0, "Calder jump leg exit %d" % legs["jump"].returncode)
    c.ok(legs["target"].returncode == 0, "Calder target exit %d (%s)" % (
        legs["target"].returncode, legs["target"].stderr.decode('utf-8', 'replace')[:200]))
    c.ok(h.jump_pid() == jump_pid, "jump master pid changed (%s -> %s): not reused" % (
        jump_pid, h.jump_pid()))
    c.ok(any("reus" in n.lower() for n in jump_names),
         "jump leg did not report reuse: %r" % jump_names)
    c.ok(h.duo_count(RASH) - rash1 == 0,
         "reusing the jump master cost %d new rash Duo, want 0" % (h.duo_count(RASH) - rash1))
    calder_d = h.duo_count(CLUSTERS["calder"][1]) - calder0
    c.ok(calder_d == 1, "Calder Duo prompts = %d, want exactly 1 new" % calder_d)
    c.ok(h.master_alive("aire"), "AIRE target died when Calder logged in via jump")
    c.ok(h.master_alive("calder"), "Calder master not alive (jump route)")
    return c


def s4_force_relogin_keeps_jump_and_calder(h):
    c = Check()
    jump_pid = h.jump_pid()
    calder_pid = h.master_pid("calder")
    aire_pid_before = h.master_pid("aire")
    rash_duo_before = h.duo_count(RASH)

    legs = h.app_login("aire", "jump")  # force=1 (default)
    c.ok(legs["jump"].returncode == 0, "forced AIRE jump leg exit %d" % legs["jump"].returncode)
    c.ok(legs["target"].returncode == 0, "forced AIRE target exit %d (%s)" % (
        legs["target"].returncode, legs["target"].stderr.decode('utf-8', 'replace')[:200]))
    c.ok(h.jump_pid() == jump_pid, "jump master torn down by forced relogin (%s -> %s)" % (
        jump_pid, h.jump_pid()))
    c.ok(h.duo_count(RASH) == rash_duo_before, "forced relogin triggered a new rash Duo")
    c.ok(h.master_alive("aire"), "AIRE master not alive after forced relogin")
    c.ok(h.master_pid("aire") != aire_pid_before,
         "AIRE master pid unchanged by forced relogin (%s)" % aire_pid_before)
    c.ok(h.master_alive("calder") and h.master_pid("calder") == calder_pid,
         "Calder master disturbed by AIRE forced relogin")
    return c


def s5_dead_jump_reauth(h):
    c = Check()
    calder_host = CLUSTERS["calder"][1]

    # (a) Wedge the shared jump master: -O check still passes, but every -W
    # channel through it hangs (target probe AND the 127.0.0.1 self-probe).
    c.ok(h.jump_alive(), "precondition: jump master should be alive")
    c.ok(h.master_alive("aire"), "precondition: AIRE should be alive via the jump")
    old_jump_pid = h.jump_pid()
    h.wedge_jump()
    rash_duo_before = h.duo_count(RASH)

    # A fresh cluster login over the wedged jump must detect it and re-auth.
    legs = h.app_login("calder", "jump")
    c.ok(legs["jump"].returncode == 0, "jump leg over wedged master exit %d (%s)" % (
        legs["jump"].returncode, legs["jump"].stderr.decode('utf-8', 'replace')[:200]))
    c.ok("target" in legs and legs["target"].returncode == 0,
         "target over re-authed jump failed")
    c.ok(h.jump_alive(), "jump master not alive after re-auth")
    c.ok(h.jump_pid() != old_jump_pid, "wedged jump master was not replaced (%s)" % old_jump_pid)
    c.ok(h.duo_count(RASH) == rash_duo_before + 1,
         "re-auth should cost exactly one rash Duo (before=%d, now=%d)" % (
             rash_duo_before, h.duo_count(RASH)))
    # Replacing a jump master kills every tunnel that rode on it, exactly as
    # with real OpenSSH. This proves the fake models that (so the jump-pid
    # assertions elsewhere are not the only guard against a jump teardown).
    c.ok(not h.master_alive("aire"),
         "AIRE's tunnel survived the replacement of the jump master it rode on "
         "(the fake no longer binds tunnels to their jump master process)")

    # (b) The jump master dies WHILE the probe is in flight: the mux client
    # then exits 0 with no output, the same shape as a relayed clean close.
    # The follow-up `ssh -O check` must catch it and re-authenticate.
    old_jump_pid = h.jump_pid()
    rash_duo_before = h.duo_count(RASH)
    h.set_w_mode(calder_host, "kill-jump")
    try:
        jump = h.run_expect_jump("calder", "jump")
    finally:
        h.clear_w_mode(calder_host)
    c.ok(jump.returncode == 0, "jump leg after mid-probe death exit %d (%s)" % (
        jump.returncode, jump.stderr.decode('utf-8', 'replace')[:200]))
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
        target.returncode, target.stderr.decode('utf-8', 'replace')[:200]))
    c.ok(h.master_alive("calder"), "Calder master not alive after mid-probe re-auth")
    return c


def s6_wrong_password(h):
    c = Check()
    # Use a throwaway cluster id (and, for the jump leg, a throwaway jump
    # socket) so we never disturb the live masters set up by earlier
    # scenarios.
    h_env_id = "wrongpw"
    CLUSTERS[h_env_id] = ("WrongPW", "wrongpw.leeds.ac.uk")
    try:
        # Direct route: the target starter is the leg that authenticates, so
        # it is the leg that must reject with exit 13.
        target = h.run_target_starter(h_env_id, "direct",
                                      password=WRONG_PASSWORD)
        c.ok(target.returncode == 13, "wrong password (target leg) exit %d, want 13 (%s)" % (
            target.returncode, target.stderr.decode('utf-8', 'replace')[:200]))
        c.ok(not h.master_alive(h_env_id), "a master came up despite wrong password")

        # Rash route with no jump master yet: the expect jump leg is the one
        # that meets the password prompt, so it must reject with exit 13.
        spare_jump = os.path.join(h.ctl, "jump-wrongpw.sock")
        shared_jump_pid = h.jump_pid()
        jump = h.run_expect_jump(h_env_id, "jump", password=WRONG_PASSWORD,
                                 jump_control_path=spare_jump)
        c.ok(jump.returncode == 13, "wrong password (jump leg) exit %d, want 13 (%s)" % (
            jump.returncode, jump.stderr.decode('utf-8', 'replace')[:200]))

        # Same, against a keyboard-interactive-only jump host (what AIRE,
        # Calder and rash actually are): no re-prompt, just "Permission
        # denied" — the jump leg must still report exit 13.
        kbd_dir = os.path.join(h.work, "kbdint_only")
        os.makedirs(kbd_dir, exist_ok=True)
        kbd_flag = os.path.join(kbd_dir, RASH)
        open(kbd_flag, "w").close()
        try:
            spare_jump2 = os.path.join(h.ctl, "jump-wrongpw-kbd.sock")
            jump2 = h.run_expect_jump(h_env_id, "jump", password=WRONG_PASSWORD,
                                      jump_control_path=spare_jump2)
            c.ok(jump2.returncode == 13,
                 "wrong password (kbd-interactive-only jump leg) exit %d, want 13" % jump2.returncode)
        finally:
            os.remove(kbd_flag)
        c.ok(not os.path.exists(spare_jump + ".state"),
             "a jump master came up despite wrong password")
        c.ok(h.jump_pid() == shared_jump_pid and h.jump_alive(),
             "the shared jump master was disturbed by a wrong-password login")
    finally:
        CLUSTERS.pop(h_env_id, None)
    return c


def s7_password_never_leaks(h):
    c = Check()
    # Scan every logged argv.
    inv = os.path.join(h.logs, "invocations.log")
    leaked_argv = False
    try:
        with open(inv) as fh:
            for line in fh:
                if PASSWORD in line:
                    leaked_argv = True
                    break
    except OSError:
        pass
    c.ok(not leaked_argv, "password found in a logged ssh argv")

    # Scan every runtime file (logs, pid files, debug logs).
    leaked_file = None
    for path in h.all_runtime_files():
        try:
            with open(path, "rb") as fh:
                if PASSWORD.encode() in fh.read():
                    leaked_file = path
                    break
        except OSError:
            continue
    c.ok(leaked_file is None, "password found in runtime file: %s" % leaked_file)
    leftovers = h.special_runtime_files()
    c.ok(not leftovers, "non-regular files (e.g. an askpass FIFO) left behind: %r" % leftovers)

    # Scan the daemonized masters' recorded environments...
    leaked_env = None
    for path in h.environ_files():
        try:
            with open(path) as fh:
                if PASSWORD in fh.read():
                    leaked_env = path
                    break
        except OSError:
            continue
    c.ok(leaked_env is None, "password found in a master's environ file: %s" % leaked_env)

    # ...and cross-check the live masters via `ps eww`.
    ps_leak = None
    for cid in ("aire", "calder"):
        pid = h.master_pid(cid)
        if pid and _pid_alive(pid):
            if PASSWORD in _ps_environ(pid):
                ps_leak = cid
                break
    c.ok(ps_leak is None, "password visible in `ps eww` of %s master" % ps_leak)
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
    c.ok(h.master_alive("aire") and h.jump_alive(), "precondition: AIRE/jump not alive")

    for mode in ("refused", "penalized", "silent"):
        jump_pid = h.jump_pid()
        aire_pid = h.master_pid("aire")
        rash_before = h.duo_count(RASH)
        calder_before = h.duo_count(calder_host)
        h.set_w_mode(calder_host, mode)
        try:
            jump = h.run_expect_jump("calder", "jump")
            names = status_lines(jump)
            c.ok(jump.returncode == 0, "[%s] Calder jump leg exit %d (%s)" % (
                mode, jump.returncode, jump.stderr.decode('utf-8', 'replace')[:200]))
            c.ok(h.jump_pid() == jump_pid and h.jump_alive(),
                 "[%s] shared jump master torn down (%s -> %s)" % (mode, jump_pid, h.jump_pid()))
            c.ok(h.duo_count(RASH) == rash_before,
                 "[%s] %d new rash Duo, want 0" % (mode, h.duo_count(RASH) - rash_before))
            c.ok(h.master_alive("aire") and h.master_pid("aire") == aire_pid,
                 "[%s] AIRE tunnel died (pid %s -> %s)" % (mode, aire_pid, h.master_pid("aire")))
            c.ok(any("jump host is up" in n for n in names),
                 "[%s] jump leg did not explain the target problem: %r" % (mode, names))
            if mode != "silent":
                # The target leg then meets the real error. It must fail, and
                # must not be misreported as a wrong password (exit 13).
                target = h.run_target_starter("calder", "jump")
                c.ok(target.returncode not in (0, 13),
                     "[%s] Calder target exit %d, want a non-13 failure (%s)" % (
                         mode, target.returncode,
                         target.stderr.decode('utf-8', 'replace')[:200]))
                c.ok(h.duo_count(calder_host) == calder_before,
                     "[%s] a Calder Duo was requested despite the refusal" % mode)
                c.ok(h.jump_pid() == jump_pid and h.duo_count(RASH) == rash_before,
                     "[%s] Calder target leg disturbed the shared jump master" % mode)
                c.ok(h.master_alive("aire") and h.master_pid("aire") == aire_pid,
                     "[%s] AIRE tunnel died during the Calder target leg" % mode)
        finally:
            h.clear_w_mode(calder_host)
    return c


def _start_orphan_login(h, cid, host, delay_kind, seconds):
    delay_dir = os.path.join(h.work, delay_kind)
    os.makedirs(delay_dir, exist_ok=True)
    with open(os.path.join(delay_dir, host), "w") as fh:
        fh.write("%d\n" % seconds)
    env = h.cluster_env(cid, "direct")
    starter = os.path.join(SCRIPTS, "hpc_start_target_master.zsh")
    proc = subprocess.Popen(
        ["/bin/zsh", starter], stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        env=env, cwd=PROJECT_ROOT, start_new_session=True)
    proc.stdin.write((PASSWORD + "\n").encode())
    proc.stdin.close()
    return proc, os.path.join(delay_dir, host)


def _reap_orphan_login(proc, delay_file):
    if proc is not None:
        # The starter's pid is still unreaped here, so its pgid cannot have
        # been recycled: clear the fake ssh still sleeping in its delay.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.wait()
    try:
        os.remove(delay_file)
    except OSError:
        pass


def s9_killed_starter_leaves_no_writer(h):
    """hpc_start_target_master.zsh serves the password ONCE from a forked
    writer subshell. (a) During the Duo wait the secret is already gone: no
    writer process, no FIFO. (b) If only the starter's pid is killed before
    ssh has asked for the password (not its process group, as the app would
    do), the writer must notice and exit — taking the FIFO with it — instead
    of lingering under launchd with the secret."""
    c = Check()
    cid = "orphan"
    CLUSTERS[cid] = ("Orphan", "orphan.leeds.ac.uk")
    host = CLUSTERS[cid][1]
    fifo = os.path.join(h.runtime_dir(cid), "askpass.fifo")
    proc = delay_file = None
    try:
        # (a) secret consumed before the Duo wait
        proc, delay_file = _start_orphan_login(h, cid, host, "duo_delay", 20)
        end = time.time() + 10
        while time.time() < end and h.duo_count(host) < 1:
            time.sleep(0.1)
        c.ok(h.duo_count(host) == 1, "precondition: the login never reached Duo")
        time.sleep(0.5)
        writers = _children_running(proc.pid, "hpc_start_target_master.zsh")
        c.ok(not writers, "password writer still alive during the Duo wait: %r" % writers)
        c.ok(not os.path.exists(fifo), "askpass FIFO still present during the Duo wait")
        _reap_orphan_login(proc, delay_file)
        proc = delay_file = None

        # (b) starter killed while the writer still holds the password
        proc, delay_file = _start_orphan_login(h, cid, host, "password_delay", 20)
        end = time.time() + 10
        writers = []
        while time.time() < end and not (writers and os.path.exists(fifo)):
            writers = _children_running(proc.pid, "hpc_start_target_master.zsh")
            time.sleep(0.1)
        c.ok(len(writers) == 1, "precondition: expected one password writer, found %r" % writers)
        c.ok(os.path.exists(fifo), "precondition: askpass FIFO missing before the password prompt")

        os.kill(proc.pid, signal.SIGKILL)   # the starter only, not its group
        end = time.time() + 3
        while time.time() < end and (any(_pid_alive(w) for w in writers) or os.path.exists(fifo)):
            time.sleep(0.1)
        survivors = [w for w in writers if _pid_alive(w)]
        c.ok(not survivors, "password writer outlived the killed starter: %r" % survivors)
        c.ok(not os.path.exists(fifo), "askpass FIFO left behind by the killed starter")
    finally:
        _reap_orphan_login(proc, delay_file)
        CLUSTERS.pop(cid, None)
    return c


# S7 deliberately runs last so its leak scan covers every login performed by
# the suite (including S8's); the table is printed in ID order.
SCENARIOS = [
    ("S1", "direct login AIRE", s1_direct_aire),
    ("S2", "direct Calder while AIRE alive", s2_direct_calder_while_aire),
    ("S3", "rash route reuses jump master", s3_rash_reuses_jump),
    ("S4", "forced AIRE relogin keeps jump+Calder", s4_force_relogin_keeps_jump_and_calder),
    ("S5", "wedged / mid-probe-dead jump re-authenticated", s5_dead_jump_reauth),
    ("S6", "wrong password -> exit 13 (both legs)", s6_wrong_password),
    ("S8", "Calder refusal keeps shared jump + AIRE", s8_target_refusal_keeps_jump),
    ("S9", "killed starter leaves no password writer", s9_killed_starter_leaves_no_writer),
    ("S7", "password never leaks", s7_password_never_leaks),
]


def main():
    h = Harness()
    results = []
    try:
        for sid, desc, fn in SCENARIOS:
            try:
                check = fn(h)
                results.append((sid, desc, check.passed(), check.failures))
            except Exception as exc:  # noqa: BLE001 - report, keep going
                import traceback
                results.append((sid, desc, False,
                                [traceback.format_exc().strip().splitlines()[-1]
                                 + " :: " + str(exc)]))
    finally:
        h.teardown()

    results.sort(key=lambda r: r[0])
    width = max(len(d) for _, d, _, _ in results)
    print("\n%-4s %-*s  %s" % ("ID", width, "scenario", "result"))
    print("-" * (4 + width + 10))
    all_ok = True
    for sid, desc, ok, failures in results:
        print("%-4s %-*s  %s" % (sid, width, desc, "PASS" if ok else "FAIL"))
        if not ok:
            all_ok = False
            for f in failures:
                print("       - %s" % f)
    print()
    print("OVERALL:", "PASS" if all_ok else "FAIL")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
