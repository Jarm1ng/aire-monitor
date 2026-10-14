// Keep each script's marker line ("# hpc-file-script: <name>"): the tests and
// their fake runner use it to tell the scripts apart. FileScriptTests runs
// every script against the local /usr/bin/python3 -I, so a syntax error or a
// Python-version slip fails the test suite rather than a user's delete.

/// The remote half of the file manager: small Python programs that run on
/// the login node as `python3 -I -c <script> <argv…>` (see
/// `RemoteFileService.pythonCommand`). Every path and option travels in
/// argv — never inside the script text — so no remote name can ever be
/// parsed as code, and each script prints JSON that the app decodes instead
/// of scraping `ls`/`stat` output.
///
/// Deliberately restricted to Python 3.6: no f-strings, walrus,
/// `removeprefix`, `match` or `X | Y` unions; `os.scandir` as a context
/// manager (3.6) is the newest construct. Calder's login nodes ship 3.9.
///
/// Shared rules every script follows:
/// - `load_args()` accepts a single `@<file>` argument for selections too
///   large for one command line: a NUL-separated list the app staged in
///   the login node's /tmp, which must be a regular file owned by the user
///   and is deleted as soon as it is read.
/// - `refusal()` is the server-side twin of
///   `RemoteFileService.validatedTargets`: it re-checks every destructive
///   target against `realpath` of the home directory and of each storage
///   root, on the login node itself, right before acting. The app's own
///   check uses the paths it knows; this one also catches aliases that only
///   resolve on the server (symlinked parents such as /home -> /users).
/// - Names that are not valid UTF-8 are shown with U+FFFD (`clean`) and
///   flagged `lossy`, so the app can refuse to act on a path it cannot
///   spell exactly.
/// - A trash run folder keeps its bookkeeping beside the items it holds:
///   `.manifest.json` and `write_json`'s `.manifest.json.tmp-<pid>`. Those
///   names are reserved (`is_bookkeeping`): an item the user trashes under
///   one of them is stored as `.manifest (2).json` instead, because the
///   manifest write would overwrite it, the listing would hide it, and
///   restoring its last sibling would unlink it with the manifest.
enum RemoteFileScripts {
    /// The run folder's reserved names and the naming loop that avoids
    /// them, shared verbatim by the prelude and the standalone job worker so
    /// the trash move, the quota copy and the listing can never disagree.
    ///
    /// Exactly the names `write_json` writes are reserved — `.manifest.json`
    /// and `.manifest.json.tmp-<digits>` — not every name with that prefix:
    /// with a prefix rule, `.manifest.json.tmp.bak` numbered as
    /// `.manifest.json.tmp (2).bak`, which kept the prefix, so the loop never
    /// ended (a hung Move to Trash that lost its manifest, and a copy worker
    /// spinning on the login node that Cancel could not stop). A numbered
    /// candidate always contains " (", which no reserved name does, so only
    /// names that already exist can extend the loop, and it always ends.
    static let reservedNames = #"""
    MANIFEST_NAME = ".manifest.json"
    MANIFEST_TEMPORARY_PREFIX = MANIFEST_NAME + ".tmp-"


    def is_bookkeeping(name):
        if name == MANIFEST_NAME:
            return True
        suffix = name[len(MANIFEST_TEMPORARY_PREFIX):]
        return name.startswith(MANIFEST_TEMPORARY_PREFIX) and suffix != "" and suffix.strip("0123456789") == ""


    def unique_destination(directory, name):
        stem, ext = os.path.splitext(name)
        candidate = os.path.join(directory, name)
        counter = 2
        while (is_bookkeeping(os.path.basename(candidate)) or os.path.lexists(candidate)
               or os.path.lexists(candidate + ".partial")):
            candidate = os.path.join(directory, "%s (%d)%s" % (stem, counter, ext))
            counter += 1
        return candidate
    """#

    /// Helpers shared by every script except the detached job worker.
    static let prelude = #"""
    # hpc-file-prelude
    import json, os, stat, sys


    def clean(value):
        if value is None:
            return None
        return os.fsencode(value).decode("utf-8", "replace")


    def emit(payload):
        sys.stdout.write(json.dumps(payload) + "\n")
        sys.stdout.flush()


    def fail(message):
        emit({"error": clean(message)})
        sys.exit(3)


    def describe(exc):
        if isinstance(exc, OSError) and exc.strerror:
            return clean(exc.strerror)
        return clean(str(exc))


    def load_args():
        args = sys.argv[1:]
        if len(args) == 1 and args[0].startswith("@"):
            path = args[0][1:]
            data = None
            try:
                info = os.lstat(path)
                if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid():
                    with open(path, "rb") as handle:
                        data = handle.read()
            except OSError as exc:
                fail("Could not read the staged argument list: " + describe(exc))
            finally:
                try:
                    os.unlink(path)
                except OSError:
                    pass
            if data is None:
                fail("Refusing a staged argument list that is not a private regular file.")
            args = [os.fsdecode(item) for item in data.split(b"\0")]
            if args and args[-1] == "":
                args.pop()
        return args


    def sections(args, markers):
        found = {}
        current = None
        for item in args:
            if item in markers:
                current = item
                found.setdefault(item, [])
            elif current is None:
                fail("Malformed arguments.")
            else:
                found[current].append(item)
        return found


    def first(found, marker, default=None):
        values = found.get(marker) or []
        return values[0] if values else default


    def strip_slashes(path):
        while len(path) > 1 and path.endswith("/"):
            path = path[:-1]
        return path


    def canonical(path):
        parent, name = os.path.split(path)
        return os.path.join(os.path.realpath(parent or "/"), name)


    def protected_roots(extra):
        home = os.path.realpath(os.path.expanduser("~"))
        roots = set()
        for root in [home] + list(extra):
            if root.startswith("/"):
                roots.add(strip_slashes(root))
                roots.add(strip_slashes(os.path.realpath(root)))
        return home, roots


    def refusal(target, roots):
        if not target.startswith("/"):
            return "not an absolute path"
        if any(part in ("", ".", "..") for part in target.split("/")[1:]):
            return "paths with '.', '..' or empty components are not allowed"
        for candidate in (target, canonical(target)):
            if len([part for part in candidate.split("/") if part]) < 2:
                return "it is a top-level folder"
            for root in roots:
                if candidate == root or root.startswith(candidate + "/"):
                    return "it contains your home or a storage root"
        return None


    def refusals(targets, roots):
        found = []
        for target in targets:
            reason = refusal(strip_slashes(target), roots)
            if reason:
                found.append({"path": clean(target), "reason": reason})
        return found
    """# + "\n\n" + reservedNames + "\n\n" + #"""
    def read_json(path):
        try:
            with open(path, "r") as handle:
                value = json.load(handle)
            return value if isinstance(value, dict) else None
        except (OSError, ValueError):
            return None


    def write_json(path, payload):
        temporary = path + ".tmp-%d" % os.getpid()
        with open(temporary, "w") as handle:
            json.dump(payload, handle)
        os.replace(temporary, path)


    def record_manifest(directory, moved, run, cluster, created):
        path = os.path.join(directory, ".manifest.json")
        manifest = read_json(path) or {}
        items = manifest.get("items") if isinstance(manifest.get("items"), list) else []
        items.extend(moved)
        manifest.update({"version": 1, "run": run, "cluster": cluster, "created": manifest.get("created") or created, "items": items})
        try:
            write_json(path, manifest)
        except OSError:
            pass
    """#

    /// Directory listing: `<path> <show-hidden 0|1> <cap> [filter]`. Collects only
    /// names and d_type for EVERY entry, applies the hidden and filter rules, sorts
    /// (folders first, then natural name order) and only then keeps the first
    /// `cap` — so a capped listing is the first N names, never an arbitrary
    /// readdir-order subset — and lstats just those. Reports `total`/`matched`.
    static let listing = prelude + "\n" + #"""
    # hpc-file-script: listing
    import heapq, pwd, re


    def natural_key(text):
        parts = re.split(r"(\d+)", text.casefold())
        return [int(part) if index % 2 else part for index, part in enumerate(parts)]


    args = load_args()
    if len(args) < 3:
        fail("Malformed listing request.")
    raw = args[0]
    show_hidden = args[1] == "1"
    cap = max(1, int(args[2]))
    needle_text = args[3] if len(args) > 3 else ""
    needle = needle_text.casefold()
    expanded = os.path.expanduser(raw)
    if not os.path.isabs(expanded):
        expanded = os.path.join(os.path.expanduser("~"), expanded)
    resolved = os.path.realpath(expanded)
    if not os.path.exists(resolved):
        fail("No such directory: " + clean(resolved))
    if not os.path.isdir(resolved):
        fail("Not a directory: " + clean(resolved))

    counts = {"total": 0, "matched": 0}


    def candidates(iterator):
        for entry in iterator:
            name = entry.name
            if not show_hidden and name.startswith("."):
                continue
            counts["total"] += 1
            shown = clean(name)
            if needle and needle not in shown.casefold():
                continue
            counts["matched"] += 1
            try:
                is_dir = entry.is_dir(follow_symlinks=False)
            except OSError:
                is_dir = False
            yield (not is_dir, natural_key(shown), shown, name)


    try:
        with os.scandir(resolved) as iterator:
            chosen = heapq.nsmallest(cap, candidates(iterator))
    except PermissionError:
        fail("Permission denied: " + clean(resolved))
    except OSError as exc:
        fail(describe(exc))

    entries = []
    owner_names = {}
    for _, _, shown, name in chosen:
        path = os.path.join(resolved, name)
        try:
            info = os.lstat(path)
        except OSError:
            continue
        mode = info.st_mode
        if stat.S_ISLNK(mode):
            kind = "symlink"
        elif stat.S_ISDIR(mode):
            kind = "directory"
        elif stat.S_ISREG(mode):
            kind = "file"
        else:
            kind = "other"
        link = None
        link_is_dir = None
        if kind == "symlink":
            try:
                link = clean(os.readlink(path))
            except OSError:
                link = None
            link_is_dir = os.path.isdir(path)
        owner = owner_names.get(info.st_uid)
        if owner is None:
            try:
                owner = pwd.getpwuid(info.st_uid).pw_name
            except (KeyError, OSError):
                owner = str(info.st_uid)
            owner_names[info.st_uid] = owner
        try:
            name.encode("utf-8")
            lossy = False
        except UnicodeEncodeError:
            lossy = True
        entries.append({
            "name": shown,
            "kind": kind,
            "size": info.st_size,
            "mtime": info.st_mtime,
            "owner": owner,
            "mode": stat.filemode(mode)[1:],
            "link": link,
            "link_is_dir": link_is_dir,
            "lossy": lossy,
        })

    emit({
        "requested": clean(raw),
        "resolved": clean(resolved),
        "truncated": counts["matched"] > cap,
        "total": counts["total"],
        "matched": counts["matched"],
        "filter": clean(needle_text),
        "entries": entries,
    })
    """#

    /// Preview: `<path> <cap> <head|tail>`. One round trip: `file -L --mime`
    /// (optional), size, and up to `cap` bytes from the start or the end (the tail
    /// drops its first, partial line). Refuses anything that is not a regular
    /// file, so a FIFO can never block the read.
    static let preview = prelude + "\n" + #"""
    # hpc-file-script: preview
    import base64, subprocess

    args = load_args()
    if len(args) < 3:
        fail("Malformed preview request.")
    path = args[0]
    cap = max(1, int(args[1]))
    from_end_requested = args[2] == "tail"

    try:
        info = os.stat(path)
    except FileNotFoundError:
        fail("No such file: " + clean(path) + " (a broken link, or it was moved).")
    except PermissionError:
        fail("Permission denied: " + clean(path))
    except OSError as exc:
        fail(describe(exc))
    if stat.S_ISDIR(info.st_mode):
        fail(clean(path) + " is a folder.")
    if not stat.S_ISREG(info.st_mode):
        fail(clean(path) + " is not a regular file (a pipe, socket or device), so it cannot be previewed.")

    mime = None
    charset = None
    has_file = True
    try:
        probe = subprocess.run(
            ["file", "-L", "-b", "--mime", "--", path],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
        )
        if probe.returncode == 0:
            text = probe.stdout.decode("utf-8", "replace").strip()
            pieces = [piece.strip() for piece in text.split(";")]
            mime = pieces[0] or None
            for piece in pieces[1:]:
                if piece.lower().startswith("charset="):
                    charset = piece.split("=", 1)[1].strip().lower() or None
    except FileNotFoundError:
        has_file = False
    except (OSError, subprocess.SubprocessError):
        mime = None

    size = info.st_size
    from_end = False
    try:
        with open(path, "rb") as handle:
            if from_end_requested and size > cap:
                handle.seek(size - cap)
                data = handle.read(cap)
                from_end = True
                newline = data.find(b"\n")
                if 0 <= newline < len(data) - 1:
                    data = data[newline + 1:]
                else:
                    skipped = 0
                    while data and skipped < 3 and (data[0] & 0xC0) == 0x80:
                        data = data[1:]
                        skipped += 1
            else:
                data = handle.read(cap)
    except PermissionError:
        fail("Permission denied: " + clean(path))
    except OSError as exc:
        fail(describe(exc))

    emit({
        "mime": mime,
        "charset": charset,
        "has_file": has_file,
        "size": size,
        "truncated": size > len(data),
        "from_end": from_end,
        "data": base64.b64encode(data).decode("ascii"),
    })
    """#

    /// `realpath` of the home directory and of each argument (storage roots).
    static let roots = prelude + "\n" + #"""
    # hpc-file-script: roots
    args = load_args()
    home = os.path.realpath(os.path.expanduser("~"))
    emit({"home": clean(home), "roots": [clean(os.path.realpath(path)) for path in args if path.startswith("/")]})
    """#

    /// Trash pre-flight: `--run R --trash-name N --roots … --targets …`. Re-checks
    /// the targets server-side, reports each target's device and whether its
    /// parent is writable, and creates the per-mount `<parent>/<N>/<R>` folders
    /// for items on another filesystem than home (left empty until the move).
    static let trashInspect = prelude + "\n" + #"""
    # hpc-file-script: trash-inspect
    found = sections(load_args(), ("--run", "--trash-name", "--roots", "--targets"))
    run = first(found, "--run")
    trash_name = first(found, "--trash-name")
    if not run or not trash_name or "/" in run or "/" in trash_name:
        fail("Malformed trash request.")
    targets = [strip_slashes(target) for target in found.get("--targets", [])]
    home, roots = protected_roots(found.get("--roots", []))
    refused = refusals(targets, roots)
    if refused:
        emit({"home": clean(home), "refused": refused})
        sys.exit(0)


    def device(path):
        try:
            return str(os.lstat(path).st_dev), None
        except OSError as exc:
            return None, describe(exc)


    home_device, home_error = device(home)
    probes = []
    for target in targets:
        target_device, error = device(target)
        parent = os.path.dirname(target) or "/"
        probes.append({
            "path": clean(target),
            "device": target_device,
            "error": error,
            "parent": clean(parent),
            "parent_writable": os.access(parent, os.W_OK | os.X_OK),
        })

    mount_trash = []
    seen = set()
    if home_device is not None:
        for target, probe in zip(targets, probes):
            parent = os.path.dirname(target) or "/"
            if probe["device"] is None or probe["device"] == home_device:
                continue
            if not probe["parent_writable"] or parent in seen:
                continue
            seen.add(parent)
            base = os.path.join(parent, trash_name)
            run_dir = os.path.join(base, run)
            base_existed = os.path.isdir(base)
            error = None
            try:
                if not base_existed:
                    os.mkdir(base)
                os.mkdir(run_dir)
            except OSError as exc:
                error = describe(exc)
            mount_trash.append({
                "parent": clean(parent),
                "directory": clean(run_dir),
                "created_base": not base_existed and error is None,
                "error": error,
            })

    emit({
        "home": clean(home),
        "home_device": home_device,
        "home_error": home_error,
        "refused": [],
        "targets": probes,
        "mount_trash": mount_trash,
    })
    """#

    /// Trash move: groups of `--group <dir> <home|mount> paths…` plus
    /// `--cleanup dirs…`. Moves with `os.rename` ONLY — it can never copy across
    /// filesystems (EXDEV is reported instead) — prints one JSON line per item,
    /// writes `.manifest.json` into each run folder and an index pointer in the
    /// home trash for every run folder beside scratch/flash items.
    static let trashExecute = prelude + "\n" + #"""
    # hpc-file-script: trash-execute
    import errno, hashlib

    items = load_args()
    options = {}
    groups = []
    cleanup = []
    index = 0
    while index < len(items):
        token = items[index]
        if token in ("--run", "--cluster", "--created", "--trash-name"):
            options[token] = items[index + 1] if index + 1 < len(items) else ""
            index += 2
        elif token == "--group":
            if index + 2 >= len(items):
                fail("Malformed trash group.")
            groups.append({"directory": items[index + 1], "kind": items[index + 2], "paths": []})
            index += 3
        elif token == "--cleanup":
            groups.append({"directory": None, "kind": "cleanup", "paths": []})
            index += 1
        elif groups:
            groups[-1]["paths"].append(token)
            index += 1
        else:
            fail("Malformed trash request.")

    run = options.get("--run", "")
    cluster = options.get("--cluster", "")
    created = options.get("--created", "")
    trash_name = options.get("--trash-name", "")
    home = os.path.realpath(os.path.expanduser("~"))


    def explain(exc):
        if isinstance(exc, OSError) and exc.errno == errno.EXDEV:
            return "it is on a different filesystem from its trash folder, so it could not be moved without copying"
        if isinstance(exc, OSError) and exc.errno == errno.ENOENT:
            return "it no longer exists"
        if isinstance(exc, OSError) and exc.errno in (errno.EACCES, errno.EPERM):
            return "permission denied"
        return describe(exc)


    def remove_if_empty(directory, kind):
        try:
            os.rmdir(directory)
        except OSError:
            return
        if kind == "mount":
            try:
                os.rmdir(os.path.dirname(directory))
            except OSError:
                pass


    def write_pointer(directory):
        index_dir = os.path.join(home, trash_name, ".index")
        try:
            if not os.path.isdir(index_dir):
                os.makedirs(index_dir)
            digest = hashlib.sha1(os.fsencode(directory)).hexdigest()[:12]
            write_json(os.path.join(index_dir, "%s-%s.json" % (run, digest)), {
                "version": 1, "run": run, "cluster": cluster, "created": created, "directory": clean(directory),
            })
        except OSError:
            pass


    for group in groups:
        if group["kind"] == "cleanup":
            for directory in group["paths"]:
                remove_if_empty(directory, "mount")
            continue
        directory = group["directory"]
        if os.path.basename(os.path.dirname(directory)) != trash_name or os.path.basename(directory) != run:
            for source in group["paths"]:
                emit({"failed": clean(source), "error": "refused an unexpected trash folder " + clean(directory)})
            continue
        try:
            base = os.path.dirname(directory)
            if not os.path.isdir(base):
                os.mkdir(base)
            if not os.path.isdir(directory):
                os.mkdir(directory)
        except OSError as exc:
            for source in group["paths"]:
                emit({"failed": clean(source), "error": "could not create the trash folder " + clean(directory) + ": " + explain(exc)})
            continue
        moved = []
        for source in group["paths"]:
            destination = unique_destination(directory, os.path.basename(strip_slashes(source)))
            try:
                os.rename(source, destination)
            except OSError as exc:
                emit({"failed": clean(source), "error": explain(exc)})
                continue
            moved.append({"name": clean(os.path.basename(destination)), "original": clean(source)})
            emit({"moved": clean(source), "to": clean(destination), "directory": clean(directory)})
        if moved:
            record_manifest(directory, moved, run, cluster, created)
            if group["kind"] == "mount":
                write_pointer(directory)
        else:
            remove_if_empty(directory, group["kind"])

    emit({"done": True})
    """#

    /// Starts a detached background job (`--mode delete|copy`) in its own session
    /// and returns `{job, pid}` at once. The job keeps running if the app quits
    /// or the connection drops; progress lives in a private `mkdtemp` folder.
    /// A delete also gets `--trash-name`, so the worker can drop the index
    /// pointer of a trash run folder it removed (see `jobWorker`).
    static let jobStart = prelude + "\n" + #"""
    # hpc-file-script: job-start
    import subprocess, tempfile

    found = sections(load_args(), ("--worker", "--mode", "--roots", "--targets", "--destination",
                                   "--run", "--cluster", "--created", "--trash-name"))
    mode = first(found, "--mode")
    worker = first(found, "--worker")
    targets = [strip_slashes(target) for target in found.get("--targets", [])]
    if mode not in ("delete", "copy") or not worker or not targets:
        fail("Malformed background request.")
    home, roots = protected_roots(found.get("--roots", []))
    refused = refusals(targets, roots)
    if refused:
        emit({"refused": refused})
        sys.exit(0)
    request = {"mode": mode, "targets": targets}
    trash_name = first(found, "--trash-name", "")
    if mode == "delete" and trash_name not in ("", ".", "..") and "/" not in trash_name:
        request["trash_name"] = trash_name
    if mode == "copy":
        destination = strip_slashes(first(found, "--destination", ""))
        trash_root = os.path.join(home, first(found, "--trash-name", ".aire-trash"))
        if os.path.realpath(os.path.dirname(destination)) != os.path.realpath(trash_root) or not os.path.basename(destination):
            fail("Refusing a copy destination outside the home trash: " + clean(destination))
        request.update({"destination": destination, "run": first(found, "--run"),
                        "cluster": first(found, "--cluster"), "created": first(found, "--created")})
    job = tempfile.mkdtemp(prefix="hpc-monitor-op-")
    write_json(os.path.join(job, "request.json"), request)
    with open(os.path.join(job, "worker.err"), "wb") as errors:
        process = subprocess.Popen(
            [sys.executable or "python3", "-I", "-c", worker, job],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=errors,
            start_new_session=True, close_fds=True, cwd="/",
        )
    emit({"job": clean(job), "pid": process.pid})
    """#

    /// `<job-dir> <pid> <poll|cancel>`: reads the job's status (removing its folder
    /// once it has finished), or sends SIGTERM to the job's process group.
    static let jobPoll = prelude + "\n" + #"""
    # hpc-file-script: job-poll
    import shutil

    args = load_args()
    if len(args) < 3:
        fail("Malformed status request.")
    job, pid, action = args[0], int(args[1]), args[2]


    def owned_job(path):
        if not os.path.basename(path).startswith("hpc-monitor-op-"):
            return False
        try:
            info = os.lstat(path)
        except OSError:
            return False
        return stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()


    def alive(process_id):
        try:
            os.kill(process_id, 0)
        except OSError:
            return False
        if os.path.isdir("/proc"):
            try:
                with open("/proc/%d/cmdline" % process_id, "rb") as handle:
                    return os.fsencode(job) in handle.read()
            except OSError:
                return False
        return True


    if not owned_job(job):
        emit({"state": "missing"})
        sys.exit(0)
    running = alive(pid)
    if action == "cancel":
        if running:
            try:
                os.killpg(pid, 15)
            except OSError:
                try:
                    os.kill(pid, 15)
                except OSError:
                    pass
        emit({"state": "signalled" if running else "not-running"})
        sys.exit(0)
    status = read_json(os.path.join(job, "status.json"))
    finished = bool(status and status.get("finished"))
    if finished or not running:
        detail = ""
        try:
            with open(os.path.join(job, "worker.err"), "rb") as handle:
                handle.seek(0, 2)
                handle.seek(max(0, handle.tell() - 2048))
                detail = handle.read().decode("utf-8", "replace").strip()
        except OSError:
            pass
        emit({"state": "finished" if finished else "crashed", "status": status, "detail": detail})
        shutil.rmtree(job, ignore_errors=True)
    else:
        emit({"state": "running", "status": status})
    """#

    /// Lists every trash run: the shared home trash plus the run folders beside
    /// scratch/flash items that the index records for this cluster.
    ///
    /// This listing never prunes an index entry on its own: a run folder
    /// that is absent is listed with `state` "missing", because its items
    /// may still be using quota somewhere, and renaming its folder back
    /// brings it back. Whether the folder that held its `.aire-trash` still
    /// exists proves nothing about the run — a user who renamed `results`
    /// to `results-v1` often creates a fresh `results` (Slurm scripts
    /// `mkdir -p` it), and renaming the run folder itself or its
    /// `.aire-trash` leaves the holder in place — so pruning on it orphaned
    /// runs for good. Entries are dropped only where the run is provably
    /// gone: by `trashRestore` after it emptied and removed the run folder
    /// itself, by the job worker after its own `rm -rf` removed that exact
    /// run folder (Empty, or a permanent delete in the browser), and here
    /// only for an entry named in `--forget` by the user and still missing
    /// now. A run that cannot be examined at all (an I/O error), or that lies
    /// under one of the `--roots` (storage roots) that is itself absent
    /// (that filesystem is not mounted on this login node), is listed as
    /// "unavailable" and cannot be forgotten.
    static let trashList = prelude + "\n" + #"""
    # hpc-file-script: trash-list
    import errno

    found = sections(load_args(), ("--cluster", "--trash-name", "--item-cap", "--roots", "--forget"))
    cluster = first(found, "--cluster", "")
    trash_name = first(found, "--trash-name", ".aire-trash")
    item_cap = int(first(found, "--item-cap", "300"))
    storage_roots = [strip_slashes(root) for root in found.get("--roots", []) if root.startswith("/") and len(root) > 1]
    forget = set(found.get("--forget", []))
    home = os.path.realpath(os.path.expanduser("~"))
    base = os.path.join(home, trash_name)


    def describe_run(directory, location, pointer):
        manifest = read_json(os.path.join(directory, ".manifest.json")) or {}
        originals = {}
        for item in manifest.get("items") or []:
            if isinstance(item, dict) and isinstance(item.get("name"), str):
                originals[item["name"]] = item.get("original")
        entries = []
        count = 0
        try:
            with os.scandir(directory) as iterator:
                for entry in iterator:
                    if is_bookkeeping(entry.name):
                        continue
                    count += 1
                    if len(entries) < item_cap:
                        shown = clean(entry.name)
                        try:
                            is_dir = entry.is_dir(follow_symlinks=False)
                        except OSError:
                            is_dir = False
                        try:
                            entry.name.encode("utf-8")
                            lossy = False
                        except UnicodeEncodeError:
                            lossy = True
                        entries.append({"name": shown, "is_dir": is_dir, "original": originals.get(shown), "lossy": lossy})
        except OSError as exc:
            return {"directory": clean(directory), "location": location, "error": describe(exc), "entries": [], "count": 0}
        try:
            modified = os.lstat(directory).st_mtime
        except OSError:
            modified = None
        entries.sort(key=lambda item: item["name"].casefold())
        return {
            "directory": clean(directory),
            "location": location,
            "cluster": manifest.get("cluster") or (pointer or {}).get("cluster"),
            "created": manifest.get("created") or (pointer or {}).get("created"),
            "modified": modified,
            "has_manifest": bool(manifest),
            "count": count,
            "entries": entries,
            "error": None,
        }


    def run_folder_state(directory):
        try:
            info = os.lstat(directory)
        except OSError as exc:
            if exc.errno not in (errno.ENOENT, errno.ENOTDIR):
                return "unavailable", describe(exc)
            for root in storage_roots:
                if directory.startswith(root + "/") and not os.path.isdir(root):
                    return "unavailable", clean(root) + " is not available on this login node"
            return "missing", None
        return ("present", None) if stat.S_ISDIR(info.st_mode) else ("missing", None)


    def detached_run(directory, pointer, name, state, reason):
        holder = os.path.dirname(os.path.dirname(directory))
        if state == "missing" and os.path.isdir(holder):
            error = ("This trash folder is no longer in " + clean(holder) + ": it, or the "
                     + clean(os.path.basename(os.path.dirname(directory))) + " folder holding it, was renamed, moved "
                     "or deleted outside this sheet. Rename it back to manage its items here, or Forget this entry.")
        elif state == "missing":
            error = ("Its folder " + clean(holder) + " is no longer there: it was renamed, moved or trashed, and "
                     "these items went with it. Rename it back to manage them here, or Forget this entry.")
        else:
            error = "Could not reach this trash folder (" + (reason or "unknown error") + "). Refresh later to try again."
        return {
            "directory": clean(directory),
            "location": "mount",
            "state": state,
            "pointer": clean(name) if state == "missing" else None,
            "cluster": pointer.get("cluster"),
            "created": pointer.get("created"),
            "modified": None,
            "has_manifest": False,
            "count": 0,
            "entries": [],
            "error": error,
        }


    runs = []
    if os.path.isdir(base):
        try:
            with os.scandir(base) as iterator:
                for entry in iterator:
                    if entry.name.startswith("."):
                        continue
                    try:
                        if entry.is_dir(follow_symlinks=False):
                            runs.append(describe_run(entry.path, "home", None))
                    except OSError:
                        continue
        except OSError as exc:
            fail("Could not read " + clean(base) + ": " + describe(exc))
    index_dir = os.path.join(base, ".index")
    if os.path.isdir(index_dir):
        for name in sorted(os.listdir(index_dir)):
            if not name.endswith(".json"):
                continue
            pointer_path = os.path.join(index_dir, name)
            pointer = read_json(pointer_path)
            if not pointer or pointer.get("cluster") != cluster:
                continue
            directory = pointer.get("directory")
            if not isinstance(directory, str) or not directory.startswith("/"):
                continue
            state, reason = run_folder_state(directory)
            if state == "present":
                runs.append(describe_run(directory, "mount", pointer))
                continue
            if state == "missing" and name in forget:
                try:
                    os.unlink(pointer_path)
                except OSError:
                    pass
                continue
            runs.append(detached_run(directory, pointer, name, state, reason))

    emit({"home_trash": clean(base), "runs": runs})
    """#

    /// Restores items of one run folder to their original paths with
    /// `os.rename`, never over an existing name; removes the run folder (and its
    /// index pointer) once it is empty.
    static let trashRestore = prelude + "\n" + #"""
    # hpc-file-script: trash-restore
    import errno

    found = sections(load_args(), ("--run", "--trash-name", "--pairs"))
    directory = strip_slashes(first(found, "--run", ""))
    trash_name = first(found, "--trash-name", ".aire-trash")
    pairs = found.get("--pairs", [])
    if not directory.startswith("/") or os.path.basename(os.path.dirname(directory)) != trash_name or len(pairs) % 2:
        fail("Malformed restore request.")
    home = os.path.realpath(os.path.expanduser("~"))
    restored_names = set()
    for index in range(0, len(pairs), 2):
        source, target = pairs[index], strip_slashes(pairs[index + 1])
        if os.path.dirname(source) != directory or not target.startswith("/"):
            emit({"failed": clean(source), "error": "refused: not an item of this trash folder"})
            continue
        if not os.path.lexists(source):
            emit({"failed": clean(source), "error": "it is no longer in the trash"})
            continue
        if os.path.lexists(target):
            emit({"failed": clean(source), "error": "something named " + clean(os.path.basename(target)) + " already exists at " + clean(os.path.dirname(target))})
            continue
        if not os.path.isdir(os.path.dirname(target)):
            emit({"failed": clean(source), "error": "its original folder " + clean(os.path.dirname(target)) + " no longer exists here"})
            continue
        try:
            os.rename(source, target)
        except OSError as exc:
            if exc.errno == errno.EXDEV:
                reason = "it was copied into the home trash from another filesystem; move it back with mv in a shell"
            elif exc.errno in (errno.EACCES, errno.EPERM):
                reason = "permission denied"
            else:
                reason = describe(exc)
            emit({"failed": clean(source), "error": reason})
            continue
        restored_names.add(clean(os.path.basename(source)))
        emit({"restored": clean(source), "to": clean(target)})

    manifest_path = os.path.join(directory, ".manifest.json")
    manifest = read_json(manifest_path)
    if manifest and restored_names:
        items = [item for item in manifest.get("items") or [] if not (isinstance(item, dict) and item.get("name") in restored_names)]
        manifest["items"] = items
        try:
            write_json(manifest_path, manifest)
        except OSError:
            pass
    removed = False
    try:
        remaining = [name for name in os.listdir(directory) if name != ".manifest.json"]
    except OSError:
        remaining = None
    if remaining == []:
        try:
            if os.path.lexists(manifest_path):
                os.unlink(manifest_path)
            os.rmdir(directory)
            removed = True
        except OSError:
            removed = False
    if removed:
        index_dir = os.path.join(home, trash_name, ".index")
        if os.path.isdir(index_dir):
            for name in os.listdir(index_dir):
                pointer = read_json(os.path.join(index_dir, name))
                if pointer and pointer.get("directory") == clean(directory):
                    try:
                        os.unlink(os.path.join(index_dir, name))
                    except OSError:
                        pass
        if os.path.realpath(os.path.dirname(directory)) != os.path.realpath(os.path.join(home, trash_name)):
            try:
                os.rmdir(os.path.dirname(directory))
            except OSError:
                pass
    emit({"done": True, "removed_run": removed})
    """#

    /// The detached worker `jobStart` spawns (standalone: it runs with its own
    /// `-I -c`). Deletes in batches of `rm -rf --`, or copies each item into the
    /// home trash as `cp -a` to `<name>.partial`, renames it into place and only
    /// then removes the original — so a cancelled copy never leaves a
    /// half-copied item under a real name. SIGTERM stops it between items and
    /// cleans up the partial copy.
    ///
    /// Cancel signals the worker's whole process group (`jobPoll`), which
    /// stops a running `cp` at once — wanted, its partial copy is removed.
    /// The copy mode's two removals run in a session of their own instead
    /// (`finish_removal`), out of the signal's reach: an `rm -rf` of the
    /// original killed halfway would leave a gutted original at its real path
    /// that looks intact, beside the only complete copy in the trash.
    /// Item names reserved for the run's bookkeeping (`.manifest.json`, its
    /// temporary file) are skipped with the same `reservedNames` helpers the
    /// prelude uses.
    ///
    /// A delete that removes a trash run folder beside scratch/flash items
    /// (Empty in the Trash sheet, or a permanent delete in the browser) also
    /// drops that run's index pointer, because only here is the run provably
    /// gone: the target was a real directory inside a `trash_name` folder
    /// right before this worker's own `rm -rf`, and it is absent afterwards.
    /// A target that was already absent (its holder renamed meanwhile) keeps
    /// its pointer, so the run is listed as missing rather than orphaned.
    static let jobWorker = #"""
    # hpc-file-script: job-worker
    import json, os, signal, stat, subprocess, sys

    job = sys.argv[1]
    cancelled = [False]


    def on_terminate(signum, frame):
        cancelled[0] = True


    signal.signal(signal.SIGTERM, on_terminate)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)


    def clean(value):
        if value is None:
            return None
        return os.fsencode(value).decode("utf-8", "replace")


    def write_json(path, payload):
        temporary = path + ".tmp-%d" % os.getpid()
        with open(temporary, "w") as handle:
            json.dump(payload, handle)
        os.replace(temporary, path)


    def read_json(path):
        try:
            with open(path, "r") as handle:
                value = json.load(handle)
            return value if isinstance(value, dict) else None
        except (OSError, ValueError):
            return None


    def first_line(data):
        text = data.decode("utf-8", "replace").strip()
        return text.splitlines()[-1] if text else ""


    def finish_removal(path):
        return subprocess.run(["rm", "-rf", "--", path], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.PIPE, start_new_session=True)


    def trash_run_folders(batch, trash_name):
        found = []
        if not trash_name:
            return found
        for target in batch:
            if os.path.basename(os.path.dirname(target)) != trash_name:
                continue
            try:
                if stat.S_ISDIR(os.lstat(target).st_mode):
                    found.append(target)
            except OSError:
                pass
        return found


    def drop_pointers(removed, trash_name):
        gone = set(clean(path) for path in removed)
        index_dir = os.path.join(os.path.realpath(os.path.expanduser("~")), trash_name, ".index")
        try:
            names = os.listdir(index_dir)
        except OSError:
            return
        for name in names:
            if not name.endswith(".json"):
                continue
            pointer = read_json(os.path.join(index_dir, name))
            directory = pointer.get("directory") if pointer else None
            if isinstance(directory, str) and directory in gone:
                try:
                    os.unlink(os.path.join(index_dir, name))
                except OSError:
                    pass
    """# + "\n\n" + reservedNames + "\n\n" + #"""
    with open(os.path.join(job, "request.json"), "r") as handle:
        request = json.load(handle)
    targets = request.get("targets") or []
    state = {
        "pid": os.getpid(), "mode": request.get("mode"), "total": len(targets), "done": 0,
        "failed": [], "moved": [], "current": None, "finished": False, "cancelled": False,
    }


    def save():
        try:
            write_json(os.path.join(job, "status.json"), state)
        except OSError:
            pass


    save()
    if request.get("mode") == "delete":
        batch_size = 25
        for start in range(0, len(targets), batch_size):
            if cancelled[0]:
                break
            batch = targets[start:start + batch_size]
            state["current"] = clean(batch[0])
            save()
            runs = trash_run_folders(batch, request.get("trash_name"))
            result = subprocess.run(["rm", "-rf", "--"] + batch, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            reason = first_line(result.stderr) or ("cancelled" if cancelled[0] else "rm exited %d" % result.returncode)
            for target in batch:
                if os.path.lexists(target):
                    state["failed"].append({"path": clean(target), "error": reason})
            removed_runs = [target for target in runs if not os.path.lexists(target)]
            if removed_runs:
                drop_pointers(removed_runs, request.get("trash_name"))
            state["done"] += len(batch)
            save()
    elif request.get("mode") == "copy":
        directory = request.get("destination")
        manifest_path = os.path.join(directory, ".manifest.json")
        try:
            if not os.path.isdir(os.path.dirname(directory)):
                os.mkdir(os.path.dirname(directory))
            if not os.path.isdir(directory):
                os.mkdir(directory)
        except OSError as exc:
            for target in targets:
                state["failed"].append({"path": clean(target), "error": "could not create " + clean(directory) + ": " + str(exc)})
            targets = []
        for source in targets:
            if cancelled[0]:
                break
            state["current"] = clean(source)
            save()
            destination = unique_destination(directory, os.path.basename(source.rstrip("/")))
            partial = destination + ".partial"
            copy = subprocess.run(["cp", "-a", "--", source, partial], stdin=subprocess.DEVNULL,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            if copy.returncode != 0 or cancelled[0]:
                finish_removal(partial)
                reason = "cancelled" if cancelled[0] else (first_line(copy.stderr) or "cp exited %d" % copy.returncode)
                state["failed"].append({"path": clean(source), "error": reason})
                state["done"] += 1
                save()
                continue
            os.rename(partial, destination)
            manifest = read_json(manifest_path) or {}
            items = manifest.get("items") if isinstance(manifest.get("items"), list) else []
            items.append({"name": clean(os.path.basename(destination)), "original": clean(source)})
            manifest.update({"version": 1, "run": request.get("run"), "cluster": request.get("cluster"),
                             "created": manifest.get("created") or request.get("created"), "items": items})
            try:
                write_json(manifest_path, manifest)
            except OSError:
                pass
            state["moved"].append(clean(source))
            removal = finish_removal(source)
            if removal.returncode != 0 and os.path.lexists(source):
                state["failed"].append({"path": clean(source), "error": "copied to the trash, but the original could not be fully removed: " + first_line(removal.stderr)})
            state["done"] += 1
            save()

    state["cancelled"] = cancelled[0]
    state["finished"] = True
    state["current"] = None
    save()
    """#
}
