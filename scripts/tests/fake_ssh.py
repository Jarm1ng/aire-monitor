#!/usr/bin/env python3
"""A deterministic stand-in for the OpenSSH `ssh` client, used only by the
login-script test harness (scripts/tests/test_login_flow.py).

It is copied to <workdir>/bin/ssh and placed first on PATH, so the REAL
hpc_* scripts call it by name exactly as they would call OpenSSH. It never
touches the network and never touches ~/.ssh: every control socket, state
file and log lives under the harness work directory handed to it through
$HPC_FAKE_HOME.

It emulates just enough OpenSSH behaviour for the multi-cluster login flow:

  * `-O check` / `-O exit` against a control path, printing
    "Master running (pid=N)" to stderr like OpenSSH.
  * Interactive ControlMaster creation (ControlMaster=yes, -f, optional -N):
    prompts the real keyboard-interactive "(user@host) Password: " and then
    the real multi-line Duo menu ("Duo two-factor login for ..." ...
    "Passcode or option (1-2): "), on the tty (expect leg) or through
    $SSH_ASKPASS when SSH_ASKPASS_REQUIRE=force (zsh/askpass leg). A wrong
    password is rejected with "Permission denied"; the daemonized master's
    process title starts with "ssh " and its FIRST ControlPath= option is its
    own socket, so the scripts' verified-kill / pgrep logic works on it.
  * A tunnelled master keeps a `-W` proxy child alive (its ProxyCommand, run
    for real through this fake), exactly as OpenSSH does; the child names the
    jump control path in its argv, which is how hpc_stop_master.zsh sees that
    the jump master is still in use. The child exits with its master.
  * A target master whose ProxyCommand references a jump control path refuses
    to start when that jump master is dead. It records the PID of the jump
    master it rode in on (--jump-pid=) and EXITS when that very process dies —
    just as a real tunnelled master does, because its ProxyCommand is a mux
    client bound to that one master process. A replacement jump master that
    reappears at the same socket path does NOT revive it.
  * Mux clients (BatchMode + ControlPath=X + a remote command) run the remote
    command locally via /bin/sh -c when X is alive, and fail with
    "Permission denied" when it is not.
  * `-W host:port` through a live jump socket prints "SSH-2.0-OpenSSH_9.9" and
    blocks until the jump master dies (or it is killed); through a dead or
    wedged jump socket it fails or hangs, as a real proxy channel would.

Per-target channel behaviour (what rash meets when it opens host:22) is set
by writing one word to <HPC_FAKE_HOME>/w_mode/<host>:

  refused    rash refuses the channel. A `-W` mux client prints the real
             OpenSSH mux wording "Stdio forwarding request failed: Session
             open refused by peer" and exits 255; a tunnelled master fails
             with "kex_exchange_identification: Connection closed ...".
  penalized  the far sshd's drop_connection() (MaxStartups /
             PerSourcePenalties): "Not allowed at this time" then a close, so
             a `-W` mux client exits 0; a tunnelled master fails as above.
  silent     the channel opens but the far end never sends a banner.
  kill-jump  one-shot: the jump master dies mid-probe (SIGKILL, stale socket
             left behind) and the `-W` mux client exits 0 with no output —
             the shape that must not be mistaken for a relayed refusal.

A Duo push that takes a while to approve is simulated by writing a number of
seconds to <HPC_FAKE_HOME>/duo_delay/<host>: the fake then waits that long
after answering the Duo prompt (the prompt is recorded before the wait).

Other per-host knobs (one word or number in <HPC_FAKE_HOME>/<knob>/<host>):

  duo_mode     how the push ends, like pam_duo:
                 deny     "Login request denied." then the menu AGAIN (up to
                          duo_prompts times), then "Permission denied"
                 timeout  waits duo_delay, "Login timed out." then the menu
                          again, as above
                 grace    waits duo_delay, then the server closes the
                          connection (sshd LoginGraceTime): no Permission
                          denied, just "Connection closed by ..."
                 hang     the push is never answered (until killed)
  duo_prompts  pam_duo's `prompts` option (default 3)
  pw_change    the password is expired: "after" (pam_sss after Duo:
               "Password expired. Change your password now." + "Current
               Password: "), "before" (the same, before Duo), or "rhel7"
               (pam_unix: "(current) UNIX password: ")
  password_delay  seconds before the server asks for the password (a slow
               or silent server)
  duo_warning  any value: a PAM message warning that the password expires
               soon ("Your password will expire in 5 day(s).") comes in
               front of every Duo menu, as OpenSSH delivers it: on its own
               line before the prompt's text

pam_duo is free to treat an EMPTY answer to its menu as "use the default
factor"; the fake assumes the worst and sends another push for it, so a
script that merely refuses a repeated Duo prompt (instead of ending ssh)
shows up as an extra push. Every answer to a password-change prompt is
recorded in <HPC_FAKE_HOME>/logs/pw_change/<host>.log as "refused" (empty)
or "answered" — never the text itself.

Every invocation's argv is appended to <HPC_FAKE_HOME>/logs/invocations.log,
and every answered Duo prompt is appended to
<HPC_FAKE_HOME>/logs/duo/<host>.log so the harness can count prompts per
cluster. The daemonized master records its own environment to
<socket>.environ so the harness can prove the password never reached it.
"""

import json
import os
import signal
import sys
import time


def exec_interpreter():
    """The interpreter binary to exec with a chosen argv[0] ("ssh", or
    "ssh: <socket> [mux]"). A macOS framework build (Apple's Command Line
    Tools Python on recent macOS, Homebrew's) starts through a launcher that
    re-executes Resources/Python.app/Contents/MacOS/Python and puts its own
    path in argv[0], so ps would show "…/Python …" instead of ssh. Exec'ing
    that inner binary directly keeps argv[0]."""
    inner = os.path.join(sys.base_prefix, "Resources", "Python.app", "Contents", "MacOS", "Python")
    if sys.platform == "darwin" and os.access(inner, os.X_OK):
        return inner
    return sys.executable

HOME = os.environ.get("HPC_FAKE_HOME", "")
BANNER = "SSH-2.0-OpenSSH_9.9"


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------
def _logs_dir():
    d = os.path.join(HOME, "logs")
    os.makedirs(d, exist_ok=True)
    return d


def log_invocation(argv):
    if not HOME:
        return
    rec = {"pid": os.getpid(), "ts": time.time(), "argv": argv}
    try:
        with open(os.path.join(_logs_dir(), "invocations.log"), "a") as fh:
            fh.write(json.dumps(rec) + "\n")
    except OSError:
        pass


def record_duo(host):
    if not HOME:
        return
    d = os.path.join(_logs_dir(), "duo")
    os.makedirs(d, exist_ok=True)
    safe = host.replace("/", "_")
    try:
        with open(os.path.join(d, safe + ".log"), "a") as fh:
            fh.write("%f %d\n" % (time.time(), os.getpid()))
    except OSError:
        pass


def expected_password():
    # Read from a file, never the environment: the fake must not hold the
    # password anywhere a daemonized master would inherit it, or the S7
    # "password never leaks" assertions would trip on the test oracle itself.
    try:
        with open(os.path.join(HOME, "expected_password")) as fh:
            return fh.read().rstrip("\n")
    except OSError:
        return "correct horse"


def state_path(control_path):
    return control_path + ".state"


def read_state(control_path):
    try:
        with open(state_path(control_path)) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def write_state(control_path, data):
    tmp = state_path(control_path) + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh)
    os.replace(tmp, state_path(control_path))


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def master_alive(control_path):
    """A master is alive only when both its control socket file and its state
    exist and its recorded pid is still running — the same two facts OpenSSH's
    own `-O check` reflects."""
    if not control_path or not os.path.exists(control_path):
        return False
    st = read_state(control_path)
    if not st:
        return False
    return pid_alive(int(st.get("pid", -1)))


def master_wedged(control_path):
    st = read_state(control_path)
    return bool(st and st.get("wedged"))


def master_pid(control_path):
    st = read_state(control_path)
    try:
        return int(st["pid"]) if st else None
    except (KeyError, TypeError, ValueError):
        return None


def w_mode(host):
    """How the far end behaves when rash opens a channel to `host` (see the
    module docstring). Empty string = a healthy sshd that sends its banner."""
    if not HOME or not host:
        return ""
    try:
        with open(os.path.join(HOME, "w_mode", host.replace("/", "_"))) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def _delay_setting(kind, host):
    if not HOME or not host:
        return 0.0
    try:
        with open(os.path.join(HOME, kind, host.replace("/", "_"))) as fh:
            return float(fh.read().strip() or 0)
    except (OSError, ValueError):
        return 0.0


def knob(kind, host):
    """One-word per-host test knob (see the module docstring)."""
    if not HOME or not host:
        return ""
    try:
        with open(os.path.join(HOME, kind, host.replace("/", "_"))) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def record_line(kind, host, line):
    if not HOME:
        return
    d = os.path.join(_logs_dir(), kind)
    os.makedirs(d, exist_ok=True)
    try:
        with open(os.path.join(d, host.replace("/", "_") + ".log"), "a") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def duo_delay(host):
    """Seconds the simulated user takes to approve the Duo push."""
    return _delay_setting("duo_delay", host)


def password_delay(host):
    """Seconds before the server asks for the password (slow banner)."""
    return _delay_setting("password_delay", host)


def consume_w_mode(host):
    try:
        os.remove(os.path.join(HOME, "w_mode", host.replace("/", "_")))
    except OSError:
        pass


def split_host_port(target):
    host, _sep, _port = (target or "").rpartition(":")
    return host or target


# --------------------------------------------------------------------------
# Argv parsing (only the option shapes the hpc_* scripts actually produce)
# --------------------------------------------------------------------------
class Args:
    def __init__(self):
        self.options = {}        # -o KEY=VALUE  (last wins, like OpenSSH)
        self.control_cmd = None  # -O check/exit/stop
        self.w_target = None     # -W host:port
        self.want_N = False
        self.want_f = False
        self.host = None
        self.command = []        # trailing remote command
        self.master_mode = False # internal re-exec marker
        self.argv = []           # the argv exactly as received

    @property
    def control_path(self):
        return self.options.get("ControlPath")

    @property
    def control_master(self):
        return self.options.get("ControlMaster", "")

    @property
    def batch_mode(self):
        return self.options.get("BatchMode", "").lower() == "yes"


def parse_args(argv):
    a = Args()
    a.argv = list(argv)
    i = 0
    takes_value = set("bcDEeFIiLlmOopQRSWw")  # OpenSSH flags that take an argument
    while i < len(argv):
        tok = argv[i]
        if tok == "--__master__":
            a.master_mode = True
            i += 1
            continue
        if tok == "-o":
            kv = argv[i + 1]
            i += 2
            if "=" in kv:
                k, v = kv.split("=", 1)
                a.options[k] = v
            continue
        if tok == "-O":
            a.control_cmd = argv[i + 1]
            i += 2
            continue
        if tok == "-W":
            a.w_target = argv[i + 1]
            i += 2
            continue
        if tok == "-N":
            a.want_N = True
            i += 1
            continue
        if tok == "-f":
            a.want_f = True
            i += 1
            continue
        if tok == "-S":
            a.options["ControlPath"] = argv[i + 1]
            i += 2
            continue
        if tok.startswith("-") and len(tok) >= 2:
            flag = tok[1]
            # Combined value like -W%h:%p is not produced by the scripts, so
            # handle only the "-x value" and bare-flag forms.
            if flag in takes_value and len(tok) == 2:
                if flag == "W":
                    a.w_target = argv[i + 1]
                    i += 2
                    continue
                i += 2
                continue
            i += 1
            continue
        # First bare word is the host; everything after is the remote command.
        a.host = tok
        a.command = argv[i + 1:]
        break
    return a


def proxy_jump_control_path(options):
    """Pull the jump ControlPath out of a ProxyCommand string, which is how a
    tunnelled target master names the shared jump master it rides on."""
    pc = options.get("ProxyCommand", "")
    marker = "ControlPath="
    idx = pc.find(marker)
    if idx < 0:
        return None
    rest = pc[idx + len(marker):]
    # The value may be shell-quoted ('...') by the zsh starter.
    if rest and rest[0] in "'\"":
        quote = rest[0]
        end = rest.find(quote, 1)
        return rest[1:end] if end > 0 else rest[1:]
    return rest.split()[0]


# --------------------------------------------------------------------------
# Authentication prompts
# --------------------------------------------------------------------------
def ask_via_askpass(prompt):
    helper = os.environ.get("SSH_ASKPASS")
    if not helper:
        return None
    import subprocess
    try:
        out = subprocess.run(
            [helper, prompt],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.decode("utf-8", "replace").rstrip("\n")


def use_askpass():
    return (
        os.environ.get("SSH_ASKPASS_REQUIRE") == "force"
        and os.environ.get("SSH_ASKPASS")
    )


def prompt_tty(text):
    try:
        tty = open("/dev/tty", "r+")
    except OSError:
        tty = None
    if tty is not None:
        tty.write(text)
        tty.flush()
        line = tty.readline()
        tty.close()
        return line.rstrip("\n")
    # Fall back to stderr/stdin when the caller did not give us a tty.
    sys.stderr.write(text)
    sys.stderr.flush()
    line = sys.stdin.readline()
    return line.rstrip("\n")


def duo_menu(user, host):
    """The real pam_duo menu as ONE keyboard-interactive prompt (digits are
    made up), exactly what askpass receives as its argument and what the tty
    leg sees printed."""
    u = user or "user"
    return (
        "(%s@%s) Duo two-factor login for %s@leeds.ac.uk\n"
        "\n"
        "Enter a passcode or select one of the following options:\n"
        "\n"
        "1. Duo Push to +XX XXXX XX1234\n"
        "2. SMS passcodes to +XX XXXX XX1234 (next code starts with: 1)\n"
        "\n"
        "Passcode or option (1-2): " % (u, host, u)
    )


def ask(prompt, via_askpass):
    """One keyboard-interactive prompt. None means askpass refused (ssh then
    sends the server an empty answer)."""
    if via_askpass:
        return ask_via_askpass(prompt)
    return prompt_tty(prompt)


def password_change(host, user, via_askpass, variant):
    """chauthtok inside keyboard-interactive. Our scripts must never answer
    it; whatever arrives is recorded (as a kind, never the text)."""
    if variant == "rhel7":
        text = ("You are required to change your password immediately "
                "(administrator enforced)\nChanging password for user %s.\n"
                "(current) UNIX password: " % (user or "user"))
    else:
        text = "Password expired. Change your password now.\nCurrent Password: "
    answer = ask(text, via_askpass)
    record_line("pw_change", host, "answered" if answer else "refused")
    sys.stderr.write("%s@%s: Permission denied (keyboard-interactive).\n"
                     % (user or "user", host))
    sys.stderr.flush()
    return False


def authenticate(host, user):
    """Run the password + Duo exchange on whichever channel the caller set up.
    Returns True on success; prints OpenSSH-shaped failure text and returns
    False otherwise."""
    pw_prompt = "(%s@%s) Password: " % (user or "user", host)
    via_askpass = use_askpass()

    delay = password_delay(host)
    if delay > 0:
        time.sleep(delay)
    answer = ask(pw_prompt, via_askpass)

    if answer != expected_password():
        # NumberOfPasswordPrompts=1 on the askpass leg: fail immediately.
        # On the tty leg, re-emit the prompt so the expect helper's
        # "second password prompt == rejection" rule fires, then fail —
        # unless <HPC_FAKE_HOME>/kbdint_only/<host> exists: like the real
        # AIRE and Calder (keyboard-interactive only), the server then just
        # answers "Permission denied" without asking again.
        kbdint_only = bool(HOME) and os.path.exists(
            os.path.join(HOME, "kbdint_only", host.replace("/", "_")))
        if not kbdint_only:
            sys.stderr.write("\nPermission denied, please try again.\n")
            sys.stderr.flush()
        if not via_askpass and not kbdint_only:
            prompt_tty(pw_prompt)
        sys.stderr.write(
            "%s@%s: Permission denied (keyboard-interactive,password).\n"
            % (user or "user", host)
        )
        sys.stderr.flush()
        return False

    change = knob("pw_change", host)
    if change in ("before", "rhel7"):
        return password_change(host, user, via_askpass, change)

    # Correct password -> Duo, the way pam_duo runs it: one menu prompt per
    # attempt, each answer (even an empty one, see the docstring) is a push,
    # and a failed push re-prompts with the reason prefixed, up to
    # `duo_prompts` times.
    mode = knob("duo_mode", host)
    try:
        prompts = max(1, int(knob("duo_prompts", host) or 3))
    except ValueError:
        prompts = 3
    reason = ""
    warning = "Your password will expire in 5 day(s).\n" if knob("duo_warning", host) else ""
    for _attempt in range(prompts):
        ask(reason + warning + duo_menu(user, host), via_askpass)
        record_duo(host)
        delay = duo_delay(host)
        if mode == "deny":
            reason = "Login request denied.\n\n"
            continue
        if mode == "timeout":
            time.sleep(delay)
            reason = "Login timed out.\n\n"
            continue
        if mode == "grace":
            time.sleep(delay or 0.5)
            sys.stderr.write("Connection closed by 10.0.0.1 port 22\n")
            sys.stderr.flush()
            return False
        if mode == "hang":
            time.sleep(600)
            return False
        if delay > 0:
            # The user has not approved the push yet.
            time.sleep(delay)
        sys.stderr.write("Success. Logging you in...\n")
        sys.stderr.flush()
        if change == "after":
            return password_change(host, user, via_askpass, change)
        return True
    sys.stderr.write("%s@%s: Permission denied (keyboard-interactive).\n"
                     % (user or "user", host))
    sys.stderr.flush()
    return False


# --------------------------------------------------------------------------
# Modes
# --------------------------------------------------------------------------
def do_control_command(a):
    cp = a.control_path
    cmd = a.control_cmd
    if cmd == "check":
        if master_alive(cp):
            st = read_state(cp)
            sys.stderr.write("Master running (pid=%d)\r\n" % int(st["pid"]))
            return 0
        if cp and os.path.exists(cp):
            # Socket file left behind by a master that died without cleanup.
            sys.stderr.write("Control socket connect(%s): Connection refused\r\n" % cp)
        else:
            sys.stderr.write("Control socket connect(%s): No such file or directory\r\n" % cp)
        return 255
    if cmd in ("exit", "stop"):
        st = read_state(cp)
        if st and pid_alive(int(st.get("pid", -1))):
            try:
                os.kill(int(st["pid"]), signal.SIGTERM)
            except OSError:
                pass
            for _ in range(40):
                if not pid_alive(int(st["pid"])):
                    break
                time.sleep(0.05)
            sys.stderr.write("Exit request sent.\r\n")
            # The master removes its own socket/state on exit; make sure.
            _remove_master_files(cp)
            return 0
        _remove_master_files(cp)
        sys.stderr.write("Control socket connect(%s): No such file or directory\r\n" % cp)
        return 255
    sys.stderr.write("Invalid -O command: %s\r\n" % cmd)
    return 255


def _remove_master_files(cp):
    for path in (cp, state_path(cp), cp + ".environ"):
        try:
            os.remove(path)
        except OSError:
            pass


def do_proxy_W(a):
    """`-W host:port`: carry a channel through the jump master named by
    ControlPath. This is both the expect health probe and (as a ProxyCommand)
    a tunnelled master's transport."""
    jump_cp = a.control_path
    if not master_alive(jump_cp):
        sys.stderr.write(
            "mux_client_request_session: session request failed\r\n"
            "%s: Permission denied.\r\n" % (a.host or "jump")
        )
        return 255
    jump_pid = master_pid(jump_cp)
    if master_wedged(jump_cp):
        # A wedged master answers its local socket but carries no traffic:
        # block without ever emitting a banner, exactly what makes the
        # expect probe time out. Exit if the master dies meanwhile.
        while pid_alive(jump_pid) and master_wedged(jump_cp):
            time.sleep(0.2)
        return 255

    target_host = split_host_port(a.w_target)
    mode = w_mode(target_host)
    if mode == "refused":
        # rash answered CHANNEL_OPEN with a failure; the local master turns
        # that into MUX_S_FAILURE and the mux client fatal()s (mux.c).
        sys.stderr.write(
            "Stdio forwarding request failed: Session open refused by peer\r\n")
        sys.stderr.flush()
        return 255
    if mode == "penalized":
        # sshd drop_connection(): raw write before any banner, then close.
        # The master then closes the mux session and the client exits 0.
        sys.stdout.write("Not allowed at this time\r\n")
        sys.stdout.flush()
        return 0
    if mode == "silent":
        while pid_alive(jump_pid):
            time.sleep(0.3)
        return 255
    if mode == "kill-jump":
        # The jump master dies while the probe is in flight (SIGKILL: no
        # cleanup, so its socket file is left behind as a stale socket).
        # The mux client sees its session closed and exits 0, silently.
        consume_w_mode(target_host)
        if jump_pid:
            try:
                os.kill(jump_pid, signal.SIGKILL)
            except OSError:
                pass
            for _ in range(40):
                if not pid_alive(jump_pid):
                    break
                time.sleep(0.05)
        return 0

    # Healthy: emit the far sshd's identification banner and relay until the
    # jump master process we connected through goes away or we are killed
    # (the probe kills us after the banner; a real tunnel lives exactly as
    # long as that one master process does).
    sys.stdout.write(BANNER + "\r\n")
    sys.stdout.flush()
    parent = os.getppid()
    try:
        # A real ProxyCommand child also ends when the master it serves goes
        # away (its stdin pipe closes), even if that master was SIGKILLed.
        while pid_alive(jump_pid) and os.getppid() == parent:
            time.sleep(0.3)
    except KeyboardInterrupt:
        pass
    return 0


def do_mux_client(a):
    """BatchMode mux client: run the remote command locally when the master
    is alive, else refuse exactly as OpenSSH does for a dead socket."""
    cp = a.control_path
    if not master_alive(cp) or master_wedged(cp):
        sys.stderr.write("%s: Permission denied.\r\n" % (a.host or "host"))
        return 255
    command = " ".join(a.command)
    if not command:
        return 0
    import subprocess
    try:
        proc = subprocess.run(["/bin/sh", "-c", command])
        return proc.returncode
    except OSError as exc:
        sys.stderr.write("fake-ssh: could not run remote command: %s\r\n" % exc)
        return 255


def do_master_create(a):
    """ControlMaster=yes creation leg: authenticate, then daemonize a master
    whose process title starts with 'ssh ' and whose first ControlPath= is its
    own socket."""
    cp = a.control_path
    user = a.options.get("User", "")
    jump_cp = proxy_jump_control_path(a.options)

    # A tunnelled target master cannot come up over a dead jump master.
    jump_pid = None
    if jump_cp is not None:
        if not master_alive(jump_cp):
            sys.stderr.write(
                "mux_client_request_session: session request failed\r\n"
                "%s: Permission denied.\r\n" % (a.host or "host")
            )
            return 255
        jump_pid = master_pid(jump_cp)
        # ...nor when the far end will not talk to rash. These are the
        # messages real OpenSSH leaves in the master log; none of them is a
        # "Permission denied", so the starter must not report exit 13.
        mode = w_mode(a.host)
        closed = ("kex_exchange_identification: Connection closed by remote host\r\n"
                  "Connection closed by UNKNOWN port 65535\r\n")
        if mode == "refused":
            sys.stderr.write(
                "Stdio forwarding request failed: Session open refused by peer\r\n"
                + closed)
            return 255
        if mode == "penalized":
            sys.stderr.write(closed)
            return 255
        if mode == "silent":
            sys.stderr.write(
                "Connection timed out during banner exchange\r\n"
                "Connection to UNKNOWN port 65535 timed out\r\n")
            return 255

    if not authenticate(a.host, user):
        return 255

    # Daemonize. The parent blocks until the child has written its state, so
    # the caller's immediate `-O check` cannot race the master into existence.
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid > 0:
        os.close(write_fd)
        try:
            os.read(read_fd, 1)
        except OSError:
            pass
        os.close(read_fd)
        return 0

    # Child: become a session leader, detach std fds, re-exec as the master
    # loop with an argv OpenSSH's own masters resemble closely enough for the
    # scripts' ps/pgrep verification.
    os.close(read_fd)
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 0)
    os.dup2(devnull, 1)
    os.dup2(devnull, 2)

    # A tunnelled master keeps its ProxyCommand child (a `-W` client of the
    # jump master) for its whole life, as OpenSSH does.
    proxy_pid = None
    if jump_cp is not None:
        proxy_pid = spawn_proxy_child(a.options.get("ProxyCommand", ""), a.host)
    write_state(cp, {
        "pid": os.getpid(),
        "kind": "tunnelled" if jump_cp else "direct",
        "control_path": cp,
        "jump_control_path": jump_cp,
        "host": a.host,
        "user": user,
        "no_command": a.want_N,
        "command": a.command,
        "control_persist": a.options.get("ControlPersist", ""),
        "proxy_pid": proxy_pid,
        "wedged": False,
    })
    # Marker socket file so `-O check` and `[ -e ]`/`file exists` see a master.
    try:
        with open(cp, "w") as fh:
            fh.write("mux\n")
    except OSError:
        pass
    # Record the master's environment so the harness can prove the password
    # never reached it (S7). argv[0] is 'ssh' and the real environ is here.
    try:
        with open(cp + ".environ", "w") as fh:
            for k, v in sorted(os.environ.items()):
                fh.write("%s=%s\n" % (k, v))
    except OSError:
        pass

    os.write(write_fd, b"x")
    os.close(write_fd)

    # Close every other inherited descriptor before re-exec, the way a real
    # daemonizing `ssh -f` does. Without this the master would keep the
    # caller's stdout/stderr pipes open (expect passes them to spawned
    # children), and a parent reading our output — the Swift app, or the test
    # harness's subprocess.communicate() — would never see EOF.
    try:
        maxfd = os.sysconf("SC_OPEN_MAX")
    except (AttributeError, ValueError):
        maxfd = 1024
    maxfd = min(max(maxfd, 1024), 8192)
    os.closerange(3, maxfd)

    # Re-exec through the interpreter as the master loop, titled the way a
    # real detached OpenSSH master is, so the scripts' verified-kill and
    # jump-rider rules meet the shape they meet in real life:
    #   * -N (every master the hpc_* scripts start): with ControlPersist and
    #     no session or stdio forward to hand over, OpenSSH daemonizes
    #     WITHOUT control_persist_detach() and never retitles itself, so ps
    #     shows the master's original argv. That argv names its own socket
    #     (first ControlPath=), carries ControlMaster=yes and, for a
    #     tunnelled master, the jump socket inside its ProxyCommand — the
    #     same shape as a master still authenticating.
    #   * with a remote command: control_persist_detach() forks the master
    #     away from the session client and retitles it "ssh: <socket> [mux]".
    # The loop's own markers (--state= and friends) come first and never
    # spell "ControlPath=", so the first ControlPath= ps shows is the
    # master's real one.
    self_path = os.path.realpath(__file__)
    markers = ["--state=" + cp]
    if jump_pid:
        markers.append("--jump-pid=%d" % jump_pid)
    if proxy_pid:
        markers.append("--proxy-pid=%d" % proxy_pid)
    if a.want_N and not a.command:
        os.execv(exec_interpreter(),
                 ["ssh", self_path, "--__master__"] + markers + ["--"] + a.argv)
    os.execv(exec_interpreter(),
             ["ssh: %s [mux]" % cp, self_path, "--__master__"] + markers
             + ["-o", "ControlMaster=yes", "-o", "ControlPath=" + cp, a.host or "host"])
    # execv replaces this process; control never returns here.


def spawn_proxy_child(proxy_command, host):
    """Run the master's ProxyCommand (with %h/%p expanded) through this fake,
    detached from our stdio. Returns its pid, or None."""
    import shlex
    import subprocess
    if not proxy_command:
        return None
    try:
        argv = shlex.split(proxy_command.replace("%h", host or "host").replace("%p", "22"))
    except ValueError:
        return None
    if not argv or argv[0] != "ssh":
        return None
    try:
        proc = subprocess.Popen(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, close_fds=True)
    except OSError:
        return None
    return proc.pid


def run_master_loop(argv):
    """Internal: the daemonized master. Lives until its socket disappears, its
    state is removed, or — for a tunnelled target master — the very jump
    master PROCESS it rode in on dies. Binding to the pid (not to "some
    master answers at the jump socket path") matters: a jump master that is
    torn down and re-authenticated at the same path within one poll interval
    would otherwise look continuous, hiding exactly the regression the
    harness exists to catch."""
    cp = None
    jump_pid = None
    proxy_pid = None
    for tok in argv:
        if tok.startswith("--state="):
            cp = tok.split("=", 1)[1]
        elif tok.startswith("--jump-pid="):
            try:
                jump_pid = int(tok.split("=", 1)[1])
            except ValueError:
                jump_pid = -1
        elif tok.startswith("--proxy-pid="):
            try:
                proxy_pid = int(tok.split("=", 1)[1])
            except ValueError:
                proxy_pid = None

    running = {"go": True}

    def _term(signum, frame):
        running["go"] = False
    signal.signal(signal.SIGTERM, _term)
    signal.signal(signal.SIGINT, _term)

    try:
        while running["go"]:
            if not cp or not os.path.exists(cp):
                break
            st = read_state(cp)
            if not st or int(st.get("pid", -1)) != os.getpid():
                break
            if jump_pid is not None and not pid_alive(jump_pid):
                break
            time.sleep(0.2)
    finally:
        _remove_master_files(cp)
        if proxy_pid:
            try:
                os.kill(proxy_pid, signal.SIGTERM)
                os.waitpid(proxy_pid, 0)
            except OSError:
                pass
    return 0


# --------------------------------------------------------------------------
REEXEC_MARK = "--__as_ssh__"


def main(argv):
    if argv and argv[0] == REEXEC_MARK:
        argv = argv[1:]
    else:
        a = parse_args(argv)
        if a.control_master == "yes" and not a.master_mode and not a.control_cmd:
            # An authenticating master must look like `ssh ... ControlPath=<own>
            # ... ControlMaster=yes ...` in ps, as a real one does (the
            # scripts may have to kill one abandoned at a Duo prompt), not
            # like `python3 .../bin/ssh ...`.
            sys.stdout.flush()
            sys.stderr.flush()
            os.execv(exec_interpreter(),
                     ["ssh", os.path.realpath(__file__), REEXEC_MARK] + argv)
    log_invocation(argv)
    a = parse_args(argv)

    if a.master_mode:
        return run_master_loop(argv)
    if a.control_cmd:
        return do_control_command(a)
    if a.w_target is not None:
        return do_proxy_W(a)
    if a.control_master == "yes":
        return do_master_create(a)
    if a.command and a.control_path:
        return do_mux_client(a)
    # Anything else (a bare BatchMode connection with no live master) is a
    # refusal, matching OpenSSH falling through to a failed auth.
    sys.stderr.write("%s: Permission denied.\r\n" % (a.host or "host"))
    return 255


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
