#!/usr/bin/env python3
"""Collect a read-only Slurm snapshot from one HPC cluster over SSH.

This is the cluster-agnostic collector behind Leeds HPC Monitor. One
invocation talks to exactly one cluster (AIRE, Calder, ...); the app runs one
collector per cluster, each over that cluster's own SSH ControlMaster.

This script is intentionally local-only: it does not install anything on the
server, write remote files, submit jobs, or cancel jobs. It only runs
read-only Slurm, df, quota and lfs commands through an SSH connection that is
already authenticated (an explicit ControlMaster socket, or a host alias for
manual testing). It never prompts for, receives, or forwards a password.

All remote commands are batched into a single SSH round-trip: a small POSIX
shell script prints section-delimited output which is parsed locally. Each
section carries its own exit status so one failing command does not discard
the rest of the snapshot.

--timeout is the budget for the WHOLE collection (socket probe + round
trip), so the JSON is always printed before a caller watchdog slightly longer
than it fires. Storage runs last: a filesystem that stalls df/quota/lfs past
the budget costs only the storage rows (a warning), never the snapshot.

Storage is data-driven: --storage-spec describes each volume (label,
candidate directory templates, quota method) and the matching remote shell is
generated from it. Path templates may only reference $USER and $HOME; every
other character is shell-quoted literally (see render_path_template).

Run with --self-test to exercise the parsers against embedded fixtures.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Iterable


DEFAULT_CLUSTER_ID = "aire"
DEFAULT_JUMP_HOSTNAME = "rash.leeds.ac.uk"
# Display names / login hosts used only when the caller does not pass
# --cluster-name / --hostname. The app always passes both explicitly.
KNOWN_CLUSTER_NAMES = {"aire": "AIRE", "calder": "Calder"}
KNOWN_CLUSTER_HOSTNAMES = {"aire": "aire.leeds.ac.uk", "calder": "calder.leeds.ac.uk"}

FIELD_SEPARATOR = "|"
SECTION_MARKER_PREFIX = "=====HPC-SECTION:"
STATUS_MARKER_PREFIX = "=====HPC-STATUS:"
MARKER_SUFFIX = "====="

# Storage spec defaults: the shared NFS home directory is the only volume
# every Leeds cluster is guaranteed to have.
DEFAULT_STORAGE_SPEC = [{"label": "Home", "paths": ["$HOME"], "quota": "nfs"}]
QUOTA_METHODS = ("nfs", "lustre", "none")
# Bounds the generated remote script; a real cluster has a handful of volumes.
MAX_STORAGE_VOLUMES = 16
# A real spec is a few hundred bytes. The cap keeps a garbage argument from
# turning into a huge remote script (or a deep-recursion JSON parse).
MAX_STORAGE_SPEC_CHARS = 16384
STORAGE_SPEC_ERROR_PREFIX = "Invalid --storage-spec"

# --timeout is the WHOLE collection budget (socket probe + the single SSH
# round trip), so a caller's watchdog only has to exceed it by a little: the
# app runs the collector with --timeout 30 under a 40 s process watchdog.
DEFAULT_TIMEOUT = 30
# The `ssh -O check` socket probe answers in milliseconds when the master is
# healthy; this only bounds a wedged master.
PROBE_TIMEOUT = 10

# Hostnames, usernames and aliases end up as ssh argv words. Anything starting
# with '-' would be parsed by ssh as an option (e.g. '-oProxyCommand=...'),
# so such values are refused outright instead of being passed along.
SSH_WORD_RE = re.compile(r"^[A-Za-z0-9_.@%+:\[\]][A-Za-z0-9_.@%+:\[\]-]*$")


@dataclass(frozen=True)
class SSHConfig:
    host: str
    username: str | None
    hostname: str | None
    use_jump_host: bool
    jump_hostname: str | None
    control_path: str | None
    jump_control_path: str | None
    # Overall collection budget in seconds (see DEFAULT_TIMEOUT).
    timeout: int
    # Only the self-test changes this (to an absolute path of a local stub),
    # so the real ssh client and the user's control sockets are never touched.
    ssh_executable: str = "ssh"


@dataclass(frozen=True)
class ClusterInfo:
    id: str
    name: str


@dataclass(frozen=True)
class StorageVolume:
    """One entry of --storage-spec (validated)."""

    label: str
    paths: tuple[str, ...]
    quota: str  # "nfs" | "lustre" | "none"
    optional: bool = False


@dataclass(frozen=True)
class RemoteInfo:
    host: str
    hostname: str
    user: str
    cwd: str
    remote_time: str


@dataclass(frozen=True)
class Job:
    job_id: str
    partition: str
    name: str
    user: str
    state: str
    elapsed: str
    time_limit: str
    nodes: str
    reason_or_node_list: str
    submit_time: str | None = None
    start_time: str | None = None
    end_time: str | None = None
    work_dir: str | None = None
    command: str | None = None
    stdout_path: str | None = None
    stderr_path: str | None = None
    batch_host: str | None = None
    node_list: str | None = None
    num_cpus: int | None = None
    num_tasks: int | None = None
    req_tres: str | None = None
    alloc_tres: str | None = None
    tres_per_node: str | None = None


@dataclass(frozen=True)
class PartitionSummary:
    partition: str
    availability: str
    node_count: int | None
    state: str
    gres: str
    cpus_per_node: int | None
    memory_mb_per_node: int | None
    features: str
    # sinfo %l, e.g. "2-00:00:00" or "infinite"; None when the remote output
    # predates the %l column.
    time_limit: str | None = None


@dataclass(frozen=True)
class NodeSummary:
    node: str
    partitions: list[str]
    state: str
    cpu_allocated: int | None
    cpu_idle: int | None
    cpu_other: int | None
    cpu_total: int | None
    memory_mb: int | None
    gres: str
    features: str
    reason: str
    gpu_total: int | None
    gpu_allocated: int | None
    gpu_idle: int | None
    memory_allocated_mb: int | None
    memory_free_mb: int | None
    cpu_load: float | None
    current_watts: int | None
    average_watts: int | None


@dataclass(frozen=True)
class StorageSummary:
    label: str
    # The RESOLVED user directory (first existing candidate), e.g.
    # /scratch-calder/users/<user>. For a required volume none of whose
    # candidates exist it is the first candidate as expanded remotely.
    path: str
    filesystem: str
    # "quota" (NFS quota(1)), "lfs quota", "df" (fallback: filesystem-wide
    # numbers) or "unavailable" (required volume with no directory).
    source: str
    used_gb: float | None
    quota_gb: float | None
    limit_gb: float | None
    available_gb: float | None
    used_percent: float | None
    file_count: int | None
    file_quota: int | None
    file_limit: int | None
    over_quota: bool = False
    # "nfs" | "lustre-project" | "lustre-user" | "df"
    quota_type: str = "df"
    project_id: int | None = None
    mount: str = ""
    # Only for source == "unavailable": why nothing could be read.
    #   "missing"       no candidate directory exists on the login node
    #   "no-figures"    the directory exists but df/quota printed nothing
    #                   (typically a slow or stalled filesystem)
    #   "not-collected" the storage output never reached this volume
    unavailable_reason: str | None = None


@dataclass(frozen=True)
class ClusterSnapshot:
    collected_at: str
    cluster: ClusterInfo
    remote: RemoteInfo
    jobs: list[Job]
    partitions: list[PartitionSummary]
    nodes: list[NodeSummary]
    storage: list[StorageSummary]
    errors: list[str]
    # Non-fatal issues (enrichment sections that failed, quota fallbacks);
    # consumers must never treat these as a failed refresh. Swift's Codable
    # ignores unknown keys, so older app builds are unaffected.
    warnings: list[str] = field(default_factory=list)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Collect a read-only JSON monitoring snapshot from one Slurm cluster."
    )
    parser.add_argument(
        "--cluster-id",
        default=DEFAULT_CLUSTER_ID,
        help="Cluster identifier echoed in the output (e.g. 'aire', 'calder'). Defaults to 'aire'.",
    )
    parser.add_argument(
        "--cluster-name",
        help="Human-readable cluster name echoed in the output. Defaults to a name derived from --cluster-id.",
    )
    parser.add_argument(
        "--host",
        help="SSH host alias used when --username is not supplied (manual testing). Defaults to --cluster-id.",
    )
    parser.add_argument(
        "--username",
        help="Remote username. When supplied, the script connects to --hostname (optionally via --jump-hostname) instead of an SSH alias.",
    )
    parser.add_argument(
        "--hostname",
        dest="hostname",
        help="Cluster login hostname used with --username, e.g. aire.leeds.ac.uk or calder.leeds.ac.uk.",
    )
    # Deprecated spelling from the single-cluster AIRE Monitor. Hidden from
    # --help; kept so stale widget fallbacks keep working.
    parser.add_argument("--aire-hostname", dest="hostname", help=argparse.SUPPRESS)
    parser.add_argument(
        "--jump-hostname",
        default=DEFAULT_JUMP_HOSTNAME,
        help=f"Jump host used with --username and --use-jump-host. Defaults to {DEFAULT_JUMP_HOSTNAME}.",
    )
    jump_group = parser.add_mutually_exclusive_group()
    jump_group.add_argument(
        "--use-jump-host",
        action="store_true",
        help="Route explicit username mode through the jump host.",
    )
    jump_group.add_argument(
        "--no-jump-host",
        action="store_true",
        help="Connect directly to the cluster login host in explicit username mode.",
    )
    parser.add_argument(
        "--control-path",
        help="OpenSSH ControlPath of the cluster's authenticated ControlMaster. Example: ~/.ssh/ctl/aire-<hash>.sock",
    )
    parser.add_argument(
        "--jump-control-path",
        help="OpenSSH ControlPath of the authenticated jump-host ControlMaster (required with --use-jump-host).",
    )
    parser.add_argument(
        "--storage-spec",
        help=(
            "JSON list of storage volumes: "
            '[{"label": "Scratch", "paths": ["/scratch/users/$USER"], "quota": "nfs|lustre|none", "optional": false}]. '
            "Only $USER and $HOME are expanded (remotely). "
            f"Defaults to {json.dumps(DEFAULT_STORAGE_SPEC)}."
        ),
    )
    parser.add_argument(
        "--timeout",
        type=positive_int,
        default=DEFAULT_TIMEOUT,
        help=(
            "Overall time budget in seconds for the whole collection (socket probe plus the "
            "single SSH round trip). Keep it below any caller watchdog. "
            f"Defaults to {DEFAULT_TIMEOUT}."
        ),
    )
    parser.add_argument(
        "--pretty",
        action="store_true",
        help="Pretty-print JSON output.",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run the embedded self-tests and exit (local stubs only; never runs ssh).",
    )
    return parser.parse_args(argv)


def positive_int(value: str) -> int:
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{value!r} is not an integer")
    if number < 1:
        raise argparse.ArgumentTypeError("must be at least 1 second")
    return number


def default_cluster_name(cluster_id: str) -> str:
    return KNOWN_CLUSTER_NAMES.get(cluster_id.lower(), cluster_id.upper())


def ssh_base_options(timeout: int) -> list[str]:
    """Options shared by the target connection and the jump ProxyCommand.

    Every interactive authentication method is disabled and BatchMode is on:
    the collector can only ride an already-authenticated ControlMaster and
    must fail fast (never prompt, never hang) when there is none.
    ControlMaster=no means the collector can only ever be a multiplexing
    CLIENT of an existing master: it never creates, replaces or takes over a
    master socket, even if ~/.ssh/config says ControlMaster=auto.
    """
    return [
        "-o",
        "BatchMode=yes",
        "-o",
        "PubkeyAuthentication=no",
        "-o",
        "GSSAPIAuthentication=no",
        "-o",
        "PasswordAuthentication=no",
        "-o",
        "KbdInteractiveAuthentication=no",
        "-o",
        f"ConnectTimeout={min(timeout, 20)}",
        "-o",
        "ServerAliveInterval=30",
        "-o",
        "ServerAliveCountMax=10",
        "-o",
        "TCPKeepAlive=yes",
        "-o",
        "ControlMaster=no",
    ]


def invalid_ssh_word(name: str, value: str | None) -> str | None:
    if value is not None and not SSH_WORD_RE.match(value):
        return f"{name} {value!r} is not a valid SSH host/user name"
    return None


def build_ssh_command(config: SSHConfig, remote_command: str) -> tuple[list[str] | None, str | None]:
    command = [config.ssh_executable] + ssh_base_options(config.timeout) + ["-o", "ExitOnForwardFailure=yes"]
    if config.control_path:
        command.extend(["-o", f"ControlPath={config.control_path}"])

    if config.username:
        if not config.hostname:
            return None, "--username requires --hostname"
        for name, value in (
            ("--username", config.username),
            ("--hostname", config.hostname),
            ("--jump-hostname", config.jump_hostname if config.use_jump_host else None),
        ):
            problem = invalid_ssh_word(name, value)
            if problem:
                return None, problem
        command.extend(["-o", f"User={config.username}"])
        if config.use_jump_host:
            if not config.jump_hostname:
                return None, "--use-jump-host requires --jump-hostname"
            if not config.control_path:
                return None, "--use-jump-host requires --control-path so refreshes can reuse the authenticated cluster master"
            if not config.jump_control_path:
                return None, "--use-jump-host requires --jump-control-path so refreshes can reuse the authenticated jump host"
            jump_proxy = (
                [config.ssh_executable]
                + ssh_base_options(config.timeout)
                + [
                    "-o",
                    f"ControlPath={config.jump_control_path}",
                    "-o",
                    f"User={config.username}",
                    "-W",
                    "%h:%p",
                    config.jump_hostname,
                ]
            )
            command.extend(["-o", f"ProxyCommand={shlex.join(jump_proxy)}"])
        else:
            command.extend(["-o", "ProxyCommand=none", "-o", "ProxyJump=none"])
        command.extend([config.hostname, remote_command])
    else:
        problem = invalid_ssh_word("--host", config.host)
        if problem:
            return None, problem
        command.extend([config.host, remote_command])
    return command, None


def _as_text(value: object) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value if isinstance(value, str) else ""


def run_captured(command: list[str], timeout: float) -> subprocess.CompletedProcess:
    """subprocess.run for every ssh invocation: stdin closed, output captured
    and decoded as UTF-8 with undecodable bytes replaced (U+FFFD).

    Remote output is not guaranteed to be valid UTF-8: a job name, a latin-1
    scontrol WorkDir=/Command=, a node Reason or quota text can carry any
    byte. Strict decoding (text=True) would raise UnicodeDecodeError, the
    collector would print no JSON at all, and the cluster would look broken
    for as long as that job or node existed. Lenient decoding matches what
    the timeout path does with its partial bytes (_as_text).
    """
    return subprocess.run(
        command,
        check=False,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        # Never let ssh (or a remote login script) read the caller's
        # stdin: the remote side gets EOF immediately.
        stdin=subprocess.DEVNULL,
        timeout=timeout,
    )


def run_ssh(
    config: SSHConfig,
    remote_command: str,
    run_timeout: float | None = None,
) -> tuple[str, str | None, bool]:
    """Run the batched remote script. Returns (stdout, error, timed_out).

    On a timeout the partial stdout is still returned: the caller can keep a
    snapshot whose core sections all completed before, say, a hung Lustre
    mount stalled the storage section.
    """
    command, error = build_ssh_command(config, remote_command)
    if command is None:
        return "", error, False

    effective_timeout = run_timeout if run_timeout is not None else config.timeout
    try:
        completed = run_captured(command, effective_timeout)
    except subprocess.TimeoutExpired as exc:
        # The partial output arrives as raw bytes even in text mode.
        partial = _as_text(exc.stdout).strip()
        return partial, f"Timed out after {effective_timeout:.0f}s: snapshot collection", True

    stdout = completed.stdout.strip()
    stderr = completed.stderr.strip()
    if completed.returncode != 0:
        message = f"Command failed with exit {completed.returncode}: snapshot collection"
        if stderr:
            message = f"{message}; stderr={stderr}"
        return stdout, message, False

    return stdout, None, False


def probe_master(config: SSHConfig, timeout: float = PROBE_TIMEOUT) -> str | None:
    """Return a 'connection lost' error when the control master is definitely dead.

    Returns None when the master is alive or its state cannot be determined
    (e.g. alias mode without an explicit --control-path). `ssh -O check` only
    asks the master whether it is running; it never stops or alters it.
    """
    if not config.control_path:
        return None
    target = config.hostname if config.username else config.host
    if not target or invalid_ssh_word("target", target):
        return None
    command = [
        config.ssh_executable,
        "-o",
        f"ControlPath={config.control_path}",
        "-O",
        "check",
        target,
    ]
    try:
        completed = run_captured(command, timeout)
    except subprocess.TimeoutExpired:
        return "connection lost: SSH control master did not answer the socket probe"
    if completed.returncode == 0:
        return None
    stderr = completed.stderr.strip()
    if "No ControlPath" in stderr:
        return None
    return "connection lost: SSH control master is not running (log in again from the app)"


# ---------------------------------------------------------------------------
# Field-level parsers
# ---------------------------------------------------------------------------


def split_fields(line: str, expected: int) -> list[str] | None:
    fields = [part.strip() for part in line.split(FIELD_SEPARATOR)]
    if len(fields) != expected:
        return None
    return fields


def split_job_fields(line: str) -> list[str] | None:
    """Split a squeue '%i|%P|%j|%u|%T|%M|%l|%D|%R' line into 9 fields.

    Tolerates '|' characters inside the job name (%j) by splitting the last
    six fields from the right and the first two from the left.
    """
    parts = line.split(FIELD_SEPARATOR)
    if len(parts) == 9:
        return [part.strip() for part in parts]
    if len(parts) < 9:
        return None
    right = line.rsplit(FIELD_SEPARATOR, 6)
    left = right[0].split(FIELD_SEPARATOR, 2)
    if len(left) != 3:
        return None
    return [part.strip() for part in left + right[1:]]


def parse_int(value: str) -> int | None:
    value = value.strip()
    if not value or value in {"N/A", "n/a", "(null)"}:
        return None
    try:
        return int(value)
    except ValueError:
        return None


def parse_float(value: str) -> float | None:
    value = value.strip()
    if not value or value in {"N/A", "n/a", "(null)"}:
        return None
    try:
        return float(value)
    except ValueError:
        return None


def strip_quota_markers(value: str) -> tuple[str, bool]:
    """Strip trailing '*'/'+' over-quota markers appended by quota(1)/lfs."""
    stripped = value.strip()
    over_quota = stripped.endswith("*") or stripped.endswith("+")
    return stripped.rstrip("*+").strip(), over_quota


# Binary multipliers relative to GiB. quota -s and lfs -h both use powers of
# 1024 for space; raw lfs output and quota without -s are 1 KiB blocks.
_SIZE_TO_GIB = {
    "k": 1 / (1024 * 1024),
    "m": 1 / 1024,
    "g": 1.0,
    "t": 1024.0,
    "p": 1024.0 * 1024,
    "e": 1024.0 * 1024 * 1024,
}


def parse_size_to_gb(value: str, bare_unit: str = "k") -> float | None:
    """Convert a quota/lfs/df size token to GiB.

    Suffixed tokens ('45455M', '174.2G', '4k', '1.1T') use their suffix.
    Bare numbers are interpreted in `bare_unit` — KiB by default, which is
    what raw `lfs quota` and plain `quota` report.
    """
    value, _ = strip_quota_markers(value)
    if not value or value in {"N/A", "n/a", "(null)", "-"}:
        return None
    number = value
    suffix = bare_unit.lower()
    if value[-1].isalpha():
        number = value[:-1]
        suffix = value[-1].lower()
    try:
        amount = float(number)
    except ValueError:
        return None
    multiplier = _SIZE_TO_GIB.get(suffix)
    if multiplier is None:
        return None
    return amount * multiplier


def parse_percent(value: str) -> float | None:
    return parse_float(value.strip().rstrip("%"))


def parse_cpu_summary(value: str) -> tuple[int | None, int | None, int | None, int | None]:
    # sinfo %C returns allocated/idle/other/total.
    fields = value.split("/")
    if len(fields) != 4:
        return None, None, None, None
    return tuple(parse_int(field) for field in fields)  # type: ignore[return-value]


def parse_list(value: str) -> list[str]:
    cleaned = value.strip().rstrip("*")
    if not cleaned or cleaned in {"N/A", "(null)"}:
        return []
    return [item for item in cleaned.split(",") if item]


# scontrol keys look like 'JobId=', 'ArrayTaskId=', 'gres/gpu='-style tokens.
# Anything else containing '=' (e.g. 'Command=... --lr=0.1') is a value.
KEY_TOKEN_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_:/]*=")


def parse_key_values(line: str) -> dict[str, str]:
    result: dict[str, str] = {}
    current_key: str | None = None
    current_value: list[str] = []
    for token in line.split():
        if KEY_TOKEN_RE.match(token):
            key, value = token.split("=", 1)
            if current_key is not None:
                result[current_key] = " ".join(current_value)
            current_key = key
            current_value = [value]
        elif current_key is not None:
            current_value.append(token)
    if current_key is not None:
        result[current_key] = " ".join(current_value)
    return result


def parse_tres_value(tres: str, key: str) -> int | None:
    for item in tres.split(","):
        if "=" not in item:
            continue
        item_key, item_value = item.split("=", 1)
        if item_key == key:
            return parse_int(item_value.rstrip("MGT"))
    return None


def parse_gres_gpu_total(gres: str) -> int | None:
    """Total GPU count from a sinfo %G gres string.

    Handles typed gres and socket/index suffixes, e.g. 'gpu:l40s:3(S:0-1)'
    (AIRE), 'gpu:nvidia_h200:8(S:0-1)' (Calder), 'gpu:4(IDX:0-3)', and
    comma-joined lists like 'gpu:a100:4,mps:400'.
    """
    cleaned = gres.strip()
    if not cleaned or cleaned in {"(null)", "N/A", "n/a"}:
        return None
    total = 0
    found = False
    for entry in cleaned.split(","):
        entry = re.sub(r"\([^)]*\)", "", entry).strip()
        if not entry.startswith("gpu"):
            continue
        parts = entry.split(":")
        if parts[0] != "gpu":
            continue
        if len(parts) == 1:
            total += 1
            found = True
            continue
        match = re.match(r"(\d+)", parts[-1])
        if match:
            total += int(match.group(1))
            found = True
    return total if found else None


def parse_node_details(output: str) -> dict[str, dict[str, str]]:
    details: dict[str, dict[str, str]] = {}
    for line in nonempty_lines(output):
        values = parse_key_values(line)
        node_name = values.get("NodeName")
        if node_name:
            details[node_name] = values
    return details


def parse_remote_info(host: str, output: str) -> RemoteInfo:
    fields = split_fields(output.splitlines()[0], 4) if output else None
    if not fields:
        return RemoteInfo(host=host, hostname="", user="", cwd="", remote_time="")
    hostname, user, cwd, remote_time = fields
    return RemoteInfo(
        host=host,
        hostname=hostname,
        user=user,
        cwd=cwd,
        remote_time=remote_time,
    )


def parse_jobs(output: str, details_output: str = "") -> list[Job]:
    details_by_job = parse_job_details(details_output)
    jobs: list[Job] = []
    for line in nonempty_lines(output):
        fields = split_job_fields(line)
        if not fields:
            continue
        job_id = fields[0]
        base_id = job_id.split("_", 1)[0].split(".", 1)[0]
        details = details_by_job.get(job_id) or details_by_job.get(base_id) or {}
        jobs.append(
            Job(
                job_id=job_id,
                partition=fields[1],
                name=fields[2],
                user=fields[3],
                state=fields[4],
                elapsed=fields[5],
                time_limit=fields[6],
                nodes=fields[7],
                reason_or_node_list=fields[8],
                submit_time=clean_optional(details.get("SubmitTime")),
                start_time=clean_optional(details.get("StartTime")),
                end_time=clean_optional(details.get("EndTime")),
                work_dir=clean_optional(details.get("WorkDir")),
                command=clean_optional(details.get("Command")),
                stdout_path=clean_optional(details.get("StdOut")),
                stderr_path=clean_optional(details.get("StdErr")),
                batch_host=clean_optional(details.get("BatchHost")),
                node_list=clean_optional(details.get("NodeList")),
                num_cpus=parse_int(details.get("NumCPUs", "")),
                num_tasks=parse_int(details.get("NumTasks", "")),
                req_tres=clean_optional(details.get("ReqTRES")),
                alloc_tres=clean_optional(details.get("AllocTRES")),
                tres_per_node=clean_optional(details.get("TresPerNode")),
            )
        )
    return jobs


def parse_job_details(output: str) -> dict[str, dict[str, str]]:
    """Index scontrol job records by every id squeue might report.

    Keys: the raw JobId, its base id (suffixes stripped), and — for array
    tasks — 'ArrayJobId_ArrayTaskId', which is how squeue %i reports them.
    """
    details: dict[str, dict[str, str]] = {}
    for line in nonempty_lines(output):
        values = parse_key_values(line)
        raw_job_id = values.get("JobId")
        if not raw_job_id:
            continue
        details[raw_job_id] = values
        base_id = raw_job_id.split("_", 1)[0].split(".", 1)[0]
        details.setdefault(base_id, values)
        array_job_id = clean_optional(values.get("ArrayJobId"))
        array_task_id = clean_optional(values.get("ArrayTaskId"))
        if array_job_id and array_task_id and "-" not in array_task_id:
            details[f"{array_job_id}_{array_task_id}"] = values
    return details


def clean_optional(value: str | None) -> str | None:
    if value is None:
        return None
    value = value.strip()
    if not value or value in {"N/A", "n/a", "(null)", "Unknown"}:
        return None
    return value


# ---------------------------------------------------------------------------
# squeue --json support (preferred when the cluster's Slurm provides it)
# ---------------------------------------------------------------------------


def _json_number(value: object) -> int | None:
    """Unwrap Slurm JSON numbers, which are ints or {set, infinite, number}."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, dict):
        if value.get("infinite"):
            return None
        if value.get("set") is False:
            return None
        number = value.get("number")
        if isinstance(number, (int, float)):
            return int(number)
    return None


def _json_is_infinite(value: object) -> bool:
    return isinstance(value, dict) and bool(value.get("infinite"))


def _json_state(value: object) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list) and value:
        first = value[0]
        if isinstance(first, str):
            return first
    return ""


def format_duration(total_seconds: int) -> str:
    total_seconds = max(int(total_seconds), 0)
    days, remainder = divmod(total_seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes, seconds = divmod(remainder, 60)
    if days:
        return f"{days}-{hours:02d}:{minutes:02d}:{seconds:02d}"
    if hours:
        return f"{hours}:{minutes:02d}:{seconds:02d}"
    return f"{minutes}:{seconds:02d}"


def _epoch_to_local_iso(epoch: int | None) -> str | None:
    if not epoch or epoch <= 0:
        return None
    try:
        return datetime.fromtimestamp(epoch).strftime("%Y-%m-%dT%H:%M:%S")
    except (OverflowError, OSError, ValueError):
        return None


def _json_str(value: object) -> str | None:
    if isinstance(value, str):
        return clean_optional(value)
    return None


def parse_jobs_json(output: str, now: datetime | None = None) -> list[Job] | None:
    """Parse `squeue --json` output. Returns None when the payload is unusable
    so the caller can fall back to the pipe-format sections."""
    try:
        payload = json.loads(output)
    except json.JSONDecodeError:
        return None
    raw_jobs = payload.get("jobs") if isinstance(payload, dict) else None
    if not isinstance(raw_jobs, list):
        return None
    reference = now or datetime.now()
    jobs: list[Job] = []
    try:
        for item in raw_jobs:
            if not isinstance(item, dict):
                return None
            base_job_id = _json_number(item.get("job_id"))
            if base_job_id is None:
                continue
            array_job_id = _json_number(item.get("array_job_id"))
            array_task_id = _json_number(item.get("array_task_id"))
            if array_job_id and array_task_id is not None:
                job_id = f"{array_job_id}_{array_task_id}"
            else:
                job_id = str(base_job_id)

            state = _json_state(item.get("job_state"))
            node_list = _json_str(item.get("nodes"))
            state_reason = _json_str(item.get("state_reason"))
            if state in {"RUNNING", "COMPLETING"} and node_list:
                reason_or_node_list = node_list
            elif state_reason and state_reason != "None":
                reason_or_node_list = f"({state_reason})"
            else:
                reason_or_node_list = node_list or ""

            start_epoch = _json_number(item.get("start_time"))
            elapsed = "0:00"
            if state in {"RUNNING", "COMPLETING"} and start_epoch:
                elapsed = format_duration(int(reference.timestamp()) - start_epoch)

            time_limit_value = item.get("time_limit")
            if _json_is_infinite(time_limit_value):
                time_limit = "UNLIMITED"
            else:
                limit_minutes = _json_number(time_limit_value)
                time_limit = (
                    format_duration(limit_minutes * 60) if limit_minutes is not None else ""
                )

            node_count = _json_number(item.get("node_count"))
            jobs.append(
                Job(
                    job_id=job_id,
                    partition=_json_str(item.get("partition")) or "",
                    name=_json_str(item.get("name")) or "",
                    user=_json_str(item.get("user_name")) or "",
                    state=state,
                    elapsed=elapsed,
                    time_limit=time_limit,
                    nodes=str(node_count) if node_count is not None else "",
                    reason_or_node_list=reason_or_node_list,
                    submit_time=_epoch_to_local_iso(_json_number(item.get("submit_time"))),
                    start_time=_epoch_to_local_iso(start_epoch),
                    end_time=_epoch_to_local_iso(_json_number(item.get("end_time"))),
                    work_dir=_json_str(item.get("current_working_directory")),
                    command=_json_str(item.get("command")),
                    stdout_path=_json_str(item.get("standard_output")),
                    stderr_path=_json_str(item.get("standard_error")),
                    batch_host=_json_str(item.get("batch_host")),
                    node_list=node_list,
                    num_cpus=_json_number(item.get("cpus")),
                    num_tasks=_json_number(item.get("tasks")),
                    req_tres=_json_str(item.get("tres_req_str")),
                    alloc_tres=_json_str(item.get("tres_alloc_str")),
                    tres_per_node=_json_str(item.get("tres_per_node")),
                )
            )
    except (TypeError, ValueError, AttributeError):
        return None
    return jobs


def parse_partitions(output: str) -> list[PartitionSummary]:
    """Parse `sinfo -o '%P|%a|%D|%t|%G|%c|%m|%f|%l'` lines.

    %l (time limit) is the LAST column so the older 8-column layout is a
    strict prefix: both are accepted, the older one yields time_limit=None.
    """
    partitions: list[PartitionSummary] = []
    for line in nonempty_lines(output):
        fields = split_fields(line, 9) or split_fields(line, 8)
        if not fields:
            continue
        time_limit = fields[8] if len(fields) == 9 and fields[8] else None
        partitions.append(
            PartitionSummary(
                partition=fields[0].rstrip("*"),
                availability=fields[1],
                node_count=parse_int(fields[2]),
                state=fields[3],
                gres=fields[4],
                cpus_per_node=parse_int(fields[5]),
                memory_mb_per_node=parse_int(fields[6]),
                features=fields[7],
                time_limit=time_limit,
            )
        )
    return partitions


def parse_nodes(output: str, details_output: str = "") -> list[NodeSummary]:
    details_by_node = parse_node_details(details_output)
    nodes_by_name: dict[str, NodeSummary] = {}
    for line in nonempty_lines(output):
        fields = split_fields(line, 8)
        if not fields:
            continue
        allocated, idle, other, total = parse_cpu_summary(fields[3])
        node_name = fields[0]
        details = details_by_node.get(node_name, {})
        gpu_total = parse_tres_value(details.get("CfgTRES", ""), "gres/gpu")
        gpu_allocated = parse_tres_value(details.get("AllocTRES", ""), "gres/gpu")
        if gpu_total is None:
            gpu_total = parse_gres_gpu_total(fields[5])
        gpu_idle = None
        if gpu_total is not None and gpu_allocated is not None:
            gpu_idle = max(gpu_total - gpu_allocated, 0)
        current = NodeSummary(
            node=node_name,
            partitions=parse_list(fields[1]),
            state=fields[2],
            cpu_allocated=allocated,
            cpu_idle=idle,
            cpu_other=other,
            cpu_total=total,
            memory_mb=parse_int(fields[4]),
            gres=fields[5],
            features=fields[6],
            reason=fields[7],
            gpu_total=gpu_total,
            gpu_allocated=gpu_allocated,
            gpu_idle=gpu_idle,
            memory_allocated_mb=parse_int(details.get("AllocMem", "")),
            memory_free_mb=parse_int(details.get("FreeMem", "")),
            cpu_load=parse_float(details.get("CPULoad", "")),
            current_watts=parse_int(details.get("CurrentWatts", "")),
            average_watts=parse_int(details.get("AveWatts", "")),
        )
        if node_name in nodes_by_name:
            current = merge_node_summary(nodes_by_name[node_name], current)
        nodes_by_name[node_name] = current
    return list(nodes_by_name.values())


def merge_node_summary(left: NodeSummary, right: NodeSummary) -> NodeSummary:
    partitions = sorted(set(left.partitions) | set(right.partitions))
    return NodeSummary(
        node=left.node,
        partitions=partitions,
        state=left.state,
        cpu_allocated=left.cpu_allocated,
        cpu_idle=left.cpu_idle,
        cpu_other=left.cpu_other,
        cpu_total=left.cpu_total,
        memory_mb=left.memory_mb,
        gres=left.gres,
        features=left.features,
        reason=left.reason,
        gpu_total=left.gpu_total,
        gpu_allocated=left.gpu_allocated,
        gpu_idle=left.gpu_idle,
        memory_allocated_mb=left.memory_allocated_mb,
        memory_free_mb=left.memory_free_mb,
        cpu_load=left.cpu_load,
        current_watts=left.current_watts,
        average_watts=left.average_watts,
    )


# ---------------------------------------------------------------------------
# Storage spec: parsing, safe remote rendering, and output parsing
# ---------------------------------------------------------------------------


def parse_storage_spec(text: str | None) -> tuple[list[StorageVolume], str | None]:
    """Validate --storage-spec. Returns (volumes, error).

    Never raises: a malformed spec becomes one clear error string that the
    caller reports in snapshot.errors instead of crashing.
    """
    if text is None:
        raw: object = DEFAULT_STORAGE_SPEC
    else:
        if len(text) > MAX_STORAGE_SPEC_CHARS:
            return [], (
                f"{STORAGE_SPEC_ERROR_PREFIX}: {len(text)} characters "
                f"(at most {MAX_STORAGE_SPEC_CHARS} are accepted)"
            )
        try:
            raw = json.loads(text)
        except json.JSONDecodeError as exc:
            return [], (
                f"{STORAGE_SPEC_ERROR_PREFIX}: not valid JSON "
                f"({exc.msg} at line {exc.lineno} column {exc.colno})"
            )
        except (ValueError, RecursionError) as exc:
            # Deeply nested arrays exhaust the decoder's recursion limit;
            # other ValueErrors (e.g. an absurdly long integer) are just as
            # much a malformed spec. Neither may crash the collector.
            return [], f"{STORAGE_SPEC_ERROR_PREFIX}: not usable JSON ({type(exc).__name__})"
    if not isinstance(raw, list):
        return [], f"{STORAGE_SPEC_ERROR_PREFIX}: expected a JSON list of volume objects"
    if len(raw) > MAX_STORAGE_VOLUMES:
        return [], f"{STORAGE_SPEC_ERROR_PREFIX}: at most {MAX_STORAGE_VOLUMES} volumes are supported"

    volumes: list[StorageVolume] = []
    seen_labels: set[str] = set()
    for index, item in enumerate(raw):
        where = f"{STORAGE_SPEC_ERROR_PREFIX}: volume {index}"
        if not isinstance(item, dict):
            return [], f"{where} is not an object"
        label = item.get("label")
        if not isinstance(label, str) or not label.strip():
            return [], f"{where} needs a non-empty string 'label'"
        label = label.strip()
        where = f"{STORAGE_SPEC_ERROR_PREFIX}: volume {label!r}"
        # The app identifies storage rows by label, so labels must be unique.
        if label in seen_labels:
            return [], f"{where} is listed twice (labels must be unique)"
        seen_labels.add(label)
        paths = item.get("paths")
        if not isinstance(paths, list) or not paths:
            return [], f"{where} needs a non-empty list 'paths'"
        for path in paths:
            if not isinstance(path, str) or not path:
                return [], f"{where} has an empty or non-string path"
            # A newline would break the line-oriented remote output (and
            # has no business in a directory template); NUL cannot be
            # passed through a shell at all.
            if any(char in path for char in "\n\r\0"):
                return [], f"{where} has a path containing a newline or NUL"
        quota = item.get("quota", "none")
        if quota not in QUOTA_METHODS:
            return [], f"{where} has unknown quota method {quota!r} (expected one of {', '.join(QUOTA_METHODS)})"
        optional = item.get("optional", False)
        if not isinstance(optional, bool):
            return [], f"{where} has a non-boolean 'optional'"
        volumes.append(
            StorageVolume(label=label, paths=tuple(paths), quota=quota, optional=optional)
        )
    return volumes, None


# $USER / ${USER} / $HOME / ${HOME} — and nothing else. '$USERNAME' is a
# different variable, so a bare name must not be followed by a name char.
PATH_TOKEN_RE = re.compile(r"\$(?:\{(USER|HOME)\}|(USER|HOME)(?![A-Za-z0-9_]))")


def shell_single_quote(text: str) -> str:
    """Quote text as ONE literal POSIX shell word (no expansion of any kind)."""
    return "'" + text.replace("'", "'\"'\"'") + "'"


def render_path_template(template: str) -> str:
    """Render a storage path template as a single safe POSIX shell word.

    Only $USER and $HOME (or ${USER}/${HOME}) are expanded, and only on the
    remote side, inside double quotes so the result is never word-split or
    globbed. Every literal piece — including any other '$VAR', backticks,
    '$(...)', globs, spaces and single quotes — is single-quoted, so the spec
    can never inject shell syntax into the remote script.

    '/scratch-calder/users/$USER'  ->  '/scratch-calder/users/'"$USER"
    """
    parts: list[str] = []
    position = 0
    for match in PATH_TOKEN_RE.finditer(template):
        literal = template[position:match.start()]
        if literal:
            parts.append(shell_single_quote(literal))
        name = match.group(1) or match.group(2)
        parts.append(f'"${name}"')
        position = match.end()
    tail = template[position:]
    if tail or not parts:
        parts.append(shell_single_quote(tail))
    return "".join(parts)


# Remote helper that collects one storage volume. Arguments: volume index,
# quota method (validated enum), then the rendered candidate directories.
# Output is a block delimited by __HPC-VOLUME:<n>__ / __HPC-VOLUME-END:<n>__
# with sub-blocks __HPC-PATH__, __HPC-DF__, __HPC-MOUNT__, __HPC-PROJECT__,
# __HPC-QUOTA__ (or __HPC-TRIED__ when no candidate directory exists).
# Everything here is read-only: [ -d ], df, quota, lfs project -d (prints the
# project id of the directory itself), lfs quota. Variables are hpc_-prefixed
# because POSIX sh has no `local`.
#
# hpc_run bounds each df/quota/lfs command with coreutils `timeout` (limit in
# $hpc_storage_timeout, set by build_storage_script) so one slow filesystem
# cannot swallow the collection budget and later volumes still report. It is
# best effort: `timeout` is probed by actually running it, a login node
# without a usable one runs the commands unbounded, and a process stuck in
# uninterruptible I/O can outlive even SIGKILL. The local collection budget
# (--timeout) is the real backstop; storage comes last precisely so that the
# core sections are already safely received when it stalls.
REMOTE_STORAGE_HELPER = r"""
if timeout -k 2 5 true >/dev/null 2>&1; then
    hpc_run() { timeout -k 2 "$hpc_storage_timeout" "$@"; }
else
    hpc_run() { "$@"; }
fi
hpc_volume() {
    hpc_index=$1
    hpc_method=$2
    shift 2
    printf '__HPC-VOLUME:%s__\n' "$hpc_index"
    hpc_dir=''
    for hpc_candidate in "$@"; do
        if [ -d "$hpc_candidate" ]; then
            hpc_dir=$hpc_candidate
            break
        fi
    done
    if [ -z "$hpc_dir" ]; then
        printf '__HPC-TRIED__\n'
        printf '%s\n' "$@"
        printf '__HPC-VOLUME-END:%s__\n' "$hpc_index"
        return 0
    fi
    printf '__HPC-PATH__\n%s\n' "$hpc_dir"
    hpc_df=$(hpc_run df -Pk "$hpc_dir" 2>/dev/null)
    printf '__HPC-DF__\n%s\n' "$hpc_df"
    # Mount point = df -P column 6 onwards (re-joined in case it has spaces).
    hpc_mount=$(printf '%s\n' "$hpc_df" | awk 'NR == 2 { m = $6; for (i = 7; i <= NF; i++) m = m " " $i; print m }')
    printf '__HPC-MOUNT__\n%s\n' "$hpc_mount"
    case $hpc_method in
    nfs)
        printf '__HPC-QUOTA__\n'
        if command -v quota >/dev/null 2>&1; then
            # -w keeps each filesystem on one line. Older quota(1) builds
            # reject -w (usage on stderr, nothing on stdout): retry without.
            # Not `||`: quota(1) may exit non-zero merely for being over
            # quota, which would print the table twice.
            hpc_quota=$(hpc_run quota -s -w 2>/dev/null)
            if [ -z "$hpc_quota" ]; then
                hpc_quota=$(hpc_run quota -s 2>/dev/null)
            fi
            printf '%s\n' "$hpc_quota"
        fi
        ;;
    lustre)
        if command -v lfs >/dev/null 2>&1 && [ -n "$hpc_mount" ]; then
            hpc_project=$(hpc_run lfs project -d "$hpc_dir" 2>/dev/null | awk 'NR == 1 { print $1 }')
            case $hpc_project in
            '' | *[!0-9]*) hpc_project=0 ;;
            esac
            printf '__HPC-PROJECT__\n%s\n' "$hpc_project"
            printf '__HPC-QUOTA__\n'
            # Raw (no -h) output: exact KiB values, parsed locally.
            if [ "$hpc_project" -ne 0 ] 2>/dev/null; then
                hpc_run lfs quota -p "$hpc_project" "$hpc_mount" 2>/dev/null
            else
                hpc_run lfs quota -u "$USER" "$hpc_mount" 2>/dev/null
            fi
        fi
        ;;
    esac
    printf '__HPC-VOLUME-END:%s__\n' "$hpc_index"
}
"""


def storage_command_timeout(budget: int) -> int:
    """Per-command remote limit for df/quota/lfs: a third of the collection
    budget, clamped to 2..10 s (each normally answers in well under 1 s)."""
    return max(2, min(10, budget // 3))


def build_storage_script(volumes: list[StorageVolume], budget: int = DEFAULT_TIMEOUT) -> str:
    """Generate the remote storage section body from validated volumes."""
    lines = [
        # An int computed here, never caller text: safe to splice unquoted.
        f"hpc_storage_timeout={storage_command_timeout(budget)}",
        REMOTE_STORAGE_HELPER.strip("\n"),
    ]
    for index, volume in enumerate(volumes):
        candidates = " ".join(render_path_template(path) for path in volume.paths)
        lines.append(f"hpc_volume {index} {shell_single_quote(volume.quota)} {candidates}")
    return "\n".join(lines) + "\n"


VOLUME_START_RE = re.compile(r"^__HPC-VOLUME:(\d+)__$")
VOLUME_END_RE = re.compile(r"^__HPC-VOLUME-END:(\d+)__$")
VOLUME_FIELD_RE = re.compile(r"^__HPC-([A-Z]+)__$")


def split_storage_blocks(output: str) -> dict[int, dict[str, list[str]]]:
    """Split the storage section into {volume index: {FIELD: lines}}.

    A block cut short (e.g. the round trip timed out mid-volume) keeps
    whatever sub-blocks it already printed.
    """
    blocks: dict[int, dict[str, list[str]]] = {}
    current: dict[str, list[str]] | None = None
    field_lines: list[str] | None = None
    for line in output.splitlines():
        stripped = line.strip()
        start = VOLUME_START_RE.match(stripped)
        if start:
            current = {}
            blocks[int(start.group(1))] = current
            field_lines = None
            continue
        if VOLUME_END_RE.match(stripped):
            current = None
            field_lines = None
            continue
        if current is None:
            continue
        marker = VOLUME_FIELD_RE.match(stripped)
        if marker:
            field_lines = current.setdefault(marker.group(1), [])
            continue
        if field_lines is not None:
            field_lines.append(line)
    return blocks


def first_nonempty(lines: list[str] | None) -> str | None:
    for line in lines or []:
        line = line.strip()
        if line:
            return line
    return None


def storage_percent(
    used_gb: float | None,
    limit_gb: float | None,
    fallback: float | None,
) -> float | None:
    if used_gb is not None and limit_gb is not None and limit_gb > 0:
        return min(max(used_gb / limit_gb * 100, 0), 100)
    return fallback


def parse_df_block(lines: list[str] | None) -> dict[str, object]:
    """Parse `df -Pk` output: source, sizes (KiB -> GiB), percent, mount."""
    result: dict[str, object] = {}
    if not lines:
        return result
    for line in lines:
        fields = line.split()
        if len(fields) < 6 or fields[0] == "Filesystem":
            continue
        result["filesystem_text"] = fields[0]
        result["total_gb"] = parse_size_to_gb(fields[1] + "K")
        result["used_gb"] = parse_size_to_gb(fields[2] + "K")
        result["available_gb"] = parse_size_to_gb(fields[3] + "K")
        result["used_percent"] = parse_percent(fields[4])
        result["mount"] = " ".join(fields[5:])
        break
    return result


# A size/count value as printed by quota(1) and lfs quota (raw or -h), with
# an optional over-quota marker. Most grace columns ('-', '6days', 'none',
# '23:59', '6d23h59m59s') never match, which is how they are told apart; see
# parse_quota_values for lfs's one ambiguous grace form ('5m').
QUOTA_VALUE_RE = re.compile(r"^\d+(?:\.\d+)?[kKmMgGtTpPeE]?[*+]?$")
# lfs prints a figure it could not fully collect (some OSTs/MDTs did not
# answer, e.g. during a failover) in brackets, any over-quota marker after
# the closing bracket, and adds a 'The data in "[]" is inaccurate' notice.
BRACKETED_VALUE_RE = re.compile(r"^\[([^\[\]]*)\]([*+]?)$")


def unbracket_quota_value(value: str) -> tuple[str, bool]:
    """'[3605893120]' -> ('3605893120', True); '[12G]*' -> ('12G*', True)."""
    value = value.strip()
    match = BRACKETED_VALUE_RE.match(value)
    if match:
        return match.group(1) + match.group(2), True
    return value, False


def is_quota_value(value: str) -> bool:
    return bool(QUOTA_VALUE_RE.match(unbracket_quota_value(value)[0]))


def has_size_suffix(value: str) -> bool:
    bare, _ = strip_quota_markers(unbracket_quota_value(value)[0])
    return bool(bare) and bare[-1].isalpha()


def parse_quota_values(values: list[str]) -> dict[str, object]:
    """Interpret the numbers after the filesystem column of quota/lfs output.

    Layout: used quota limit [grace] files quota limit [grace]. With all
    eight columns present (lfs always prints both grace columns, '-' when
    unset) the positions are certain. Otherwise a grace column was left
    blank (quota -s does that) and the block grace is recognised by shape,
    so a file-only grace cannot shift columns. lfs's grace format can look
    like a size ('5m' = five minutes left), but raw output (bare KiB
    integers, which this collector requests) never has a suffixed value, so
    there a suffixed token must be the grace. Bracketed (inaccurate) lfs
    figures are used as printed and flagged with 'inaccurate'.
    A quota/limit of 0 means "no limit" and becomes None.
    """
    result: dict[str, object] = {}
    unbracketed = [unbracket_quota_value(value) for value in values]
    values = [value for value, _ in unbracketed]
    if len(values) < 3 or not all(QUOTA_VALUE_RE.match(value) for value in values[:3]):
        return result
    used, soft, hard = values[:3]
    if len(values) >= 8:
        rest = values[4:]
    else:
        rest = values[3:]
        if rest and (
            not QUOTA_VALUE_RE.match(rest[0])
            or (not has_size_suffix(used) and has_size_suffix(rest[0]))
        ):
            rest = rest[1:]
    files = [value for value in rest[:3] if QUOTA_VALUE_RE.match(value)]
    if len(files) != 3:
        files = []

    result["used_gb"] = parse_size_to_gb(used)
    result["quota_gb"] = parse_size_to_gb(soft) or None
    result["limit_gb"] = parse_size_to_gb(hard) or None
    if files:
        result["file_count_int"] = parse_count(files[0])
        result["file_quota_int"] = parse_count(files[1]) or None
        result["file_limit_int"] = parse_count(files[2]) or None
    result["over_quota"] = any(
        strip_quota_markers(value)[1] for value in [used, soft, hard] + files
    )
    if any(bracketed for _, bracketed in unbracketed):
        result["inaccurate"] = True
    return result


def _quota_row(lines: list[str], index: int) -> list[str]:
    """Values for the device row at `index`, following the wrapped layout
    (device alone on its line, numbers on the next) when needed."""
    values = lines[index].split()[1:]
    if not values or not is_quota_value(values[0]):
        values = lines[index + 1].split() if index + 1 < len(lines) else []
    return values


def _export_path(device: str) -> str | None:
    return device.split(":", 1)[1] if ":" in device else None


def parse_nfs_quota(
    lines: list[str] | None,
    filesystem: str = "",
    mount: str = "",
) -> dict[str, object]:
    """Parse `quota -s [-w]` output for the filesystem behind one directory.

    The row is matched against the df filesystem source of the directory
    (e.g. '10.10.0.15:/export/users'), falling back to the same export path
    on a differently spelled server, then to the mount point. Handles both
    the single-line (-w) and the wrapped layout.
    """
    result: dict[str, object] = {}
    if not lines:
        return result
    rows = [
        (index, line.split()[0])
        for index, line in enumerate(lines)
        if line.split() and line.split()[0] not in {"Disk", "Filesystem"}
    ]
    wanted_export = _export_path(filesystem) if filesystem else None
    match_index: int | None = None
    for predicate in (
        lambda device: bool(filesystem) and device == filesystem,
        lambda device: wanted_export is not None and _export_path(device) == wanted_export,
        lambda device: bool(mount) and device == mount,
    ):
        for index, device in rows:
            if predicate(device):
                match_index = index
                break
        if match_index is not None:
            break
    if match_index is None:
        return result
    parsed = parse_quota_values(_quota_row(lines, match_index))
    if parsed:
        result.update(parsed)
        result["filesystem_text"] = lines[match_index].split()[0]
    return result


def parse_home_quota(lines: list[str] | None, filesystem: str = "") -> dict[str, object]:
    """Back-compat wrapper: the NFS home quota row. Without an explicit
    filesystem it matches the Leeds '/export/users' export on any server."""
    if filesystem:
        return parse_nfs_quota(lines, filesystem=filesystem)
    return parse_nfs_quota(lines, filesystem="any:/export/users")


def parse_lfs_quota(lines: list[str] | None, mount: str = "") -> dict[str, object]:
    """Parse `lfs quota [-h] -u USER|-p ID <mount>` output.

    Accepts raw KiB values (preferred) and -h values, and both the single-line
    layout and the wrapped layout lfs uses for long filesystem names. The row
    is the one naming `mount`; failing that, the first row naming any path
    (lfs prints exactly one filesystem row per query).
    """
    result: dict[str, object] = {}
    if not lines:
        return result
    candidates = [
        index for index, line in enumerate(lines)
        if line.split() and line.split()[0].startswith("/")
    ]
    exact = [index for index in candidates if mount and lines[index].split()[0] == mount]
    ordered = exact + [index for index in candidates if index not in exact]
    for index in ordered:
        parsed = parse_quota_values(_quota_row(lines, index))
        if parsed:
            result.update(parsed)
            result["filesystem_text"] = lines[index].split()[0]
            break
    # The notice alone also counts, in case a bracket went unnoticed.
    if result and any("is inaccurate" in line for line in lines):
        result["inaccurate"] = True
    return result


def parse_count(value: str) -> int | None:
    value, _ = strip_quota_markers(value)
    if not value or value in {"-", "0"}:
        return None if value == "-" else 0
    suffix = value[-1].lower()
    multiplier = 1
    number = value
    # quota(1) and lfs -h abbreviate inode counts in powers of 1000.
    if suffix in {"k", "m", "g", "t"}:
        multiplier = {"k": 1_000, "m": 1_000_000, "g": 1_000_000_000, "t": 1_000_000_000_000}[suffix]
        number = value[:-1]
    try:
        return int(float(number) * multiplier)
    except ValueError:
        return None


def unavailable_volume(
    volume: StorageVolume,
    path: str,
    reason: str,
    filesystem: str = "",
    mount: str = "",
) -> StorageSummary:
    return StorageSummary(
        label=volume.label,
        path=path,
        filesystem=filesystem,
        source="unavailable",
        used_gb=None,
        quota_gb=None,
        limit_gb=None,
        available_gb=None,
        used_percent=None,
        file_count=None,
        file_quota=None,
        file_limit=None,
        over_quota=False,
        quota_type="df",
        project_id=None,
        mount=mount,
        unavailable_reason=reason,
    )


def summarize_volume(
    volume: StorageVolume,
    block: dict[str, list[str]] | None,
) -> tuple[StorageSummary | None, list[str]]:
    """Build one storage row (or None to omit it) plus any warnings."""
    warnings: list[str] = []
    if block is None:
        # No output at all for this volume: the storage section failed or was
        # cut short, which is already reported at section level.
        if volume.optional:
            return None, warnings
        # Never report the unexpanded template ("/scratch-calder/users/$USER")
        # as if it were a real path.
        return unavailable_volume(volume, "", "not-collected"), warnings

    path = first_nonempty(block.get("PATH"))
    if not path:
        if volume.optional:
            return None, warnings
        tried = [line.strip() for line in block.get("TRIED", []) if line.strip()]
        shown = ", ".join(tried) if tried else ", ".join(volume.paths)
        warnings.append(f"Storage '{volume.label}': no directory found (tried {shown})")
        return unavailable_volume(volume, tried[0] if tried else "", "missing"), warnings

    df = parse_df_block(block.get("DF"))
    df_source = str(df.get("filesystem_text") or "")
    mount = first_nonempty(block.get("MOUNT")) or str(df.get("mount") or "")
    quota_lines = block.get("QUOTA")

    quota: dict[str, object] = {}
    quota_type = "df"
    project_id: int | None = None
    source = "df"
    if volume.quota == "nfs":
        quota = parse_nfs_quota(quota_lines, filesystem=df_source, mount=mount)
        if quota.get("used_gb") is not None:
            quota_type, source = "nfs", "quota"
    elif volume.quota == "lustre":
        raw_project = first_nonempty(block.get("PROJECT")) or ""
        project_number = int(raw_project) if raw_project.isdigit() else 0
        quota = parse_lfs_quota(quota_lines, mount=mount)
        if quota.get("used_gb") is not None:
            source = "lfs quota"
            if project_number > 0:
                quota_type, project_id = "lustre-project", project_number
            else:
                quota_type = "lustre-user"

    if quota_type == "df":
        if df.get("total_gb") is None and df.get("used_gb") is None:
            # Neither quota nor df produced a figure: the volume was cut off
            # mid-block (round trip ran out of budget), or df itself failed
            # or timed out on a slow filesystem. There are no totals to show,
            # so say "unavailable" rather than a df row full of nulls.
            warnings.append(
                f"Storage '{volume.label}': no usage figures for {path} "
                "(df/quota gave no output; the filesystem may be slow)"
            )
            return unavailable_volume(volume, path, "no-figures", filesystem=df_source, mount=mount), warnings
        if volume.quota != "none":
            warnings.append(
                f"Storage '{volume.label}': {volume.quota} quota unavailable for {path}; "
                "showing filesystem totals from df"
            )
        used = df.get("used_gb")
        limit = df.get("total_gb")
        return StorageSummary(
            label=volume.label,
            path=path,
            filesystem=df_source or mount,
            source="df",
            used_gb=used,  # type: ignore[arg-type]
            quota_gb=None,
            limit_gb=limit,  # type: ignore[arg-type]
            available_gb=df.get("available_gb"),  # type: ignore[arg-type]
            used_percent=df.get("used_percent"),  # type: ignore[arg-type]
            file_count=None,
            file_quota=None,
            file_limit=None,
            over_quota=False,
            quota_type="df",
            project_id=None,
            mount=mount,
        ), warnings

    if quota.get("inaccurate"):
        warnings.append(
            f"Storage '{volume.label}': lfs marked the quota figures for {path} as inaccurate "
            "(some Lustre servers did not answer); usage may be under-reported"
        )
    used = quota.get("used_gb")
    limit = quota.get("limit_gb") or quota.get("quota_gb")
    available = None
    if limit is not None and used is not None:
        available = max(limit - used, 0)  # type: ignore[operator]
    elif df.get("available_gb") is not None:
        available = df.get("available_gb")
    return StorageSummary(
        label=volume.label,
        path=path,
        filesystem=df_source or str(quota.get("filesystem_text") or "") or mount,
        source=source,
        used_gb=used,  # type: ignore[arg-type]
        quota_gb=quota.get("quota_gb"),  # type: ignore[arg-type]
        limit_gb=limit,  # type: ignore[arg-type]
        available_gb=available,  # type: ignore[arg-type]
        used_percent=storage_percent(used, limit, df.get("used_percent")),  # type: ignore[arg-type]
        file_count=quota.get("file_count_int"),  # type: ignore[arg-type]
        file_quota=quota.get("file_quota_int"),  # type: ignore[arg-type]
        file_limit=quota.get("file_limit_int"),  # type: ignore[arg-type]
        over_quota=bool(quota.get("over_quota", False)),
        quota_type=quota_type,
        project_id=project_id,
        mount=mount,
    ), warnings


def parse_storage(
    output: str,
    volumes: list[StorageVolume],
) -> tuple[list[StorageSummary], list[str]]:
    """Parse the storage section for every spec volume, in spec order."""
    blocks = split_storage_blocks(output)
    storage: list[StorageSummary] = []
    warnings: list[str] = []
    for index, volume in enumerate(volumes):
        summary, volume_warnings = summarize_volume(volume, blocks.get(index))
        warnings.extend(volume_warnings)
        if summary is not None:
            storage.append(summary)
    return storage, warnings


def nonempty_lines(output: str) -> Iterable[str]:
    for line in output.splitlines():
        stripped = line.strip()
        if stripped:
            yield stripped


# ---------------------------------------------------------------------------
# Single-round-trip collection
# ---------------------------------------------------------------------------


# One POSIX shell script executed remotely in a single SSH round-trip. Each
# section is delimited so a failing command only loses its own section, and
# each section reports its exit status. The jobs are additionally collected
# via `squeue --json` when the remote Slurm supports it; the pipe-format
# sections are kept as a fallback for older Slurm versions and local parse
# failures. The storage section body is generated from --storage-spec.
REMOTE_SCRIPT_HEAD = r"""
section() { printf '\n=====HPC-SECTION:%s=====\n' "$1"; }
finish() { printf '\n=====HPC-STATUS:%s:%s=====\n' "$1" "$2"; }

# A non-interactive `ssh host cmd` shell may not have run the login profile
# that puts Slurm/Lustre tools on PATH. Only if squeue is missing, source the
# system profile with all of its output discarded (so a chatty profile.d
# script cannot corrupt the section stream). Never touches user dotfiles.
if ! command -v squeue >/dev/null 2>&1; then
    . /etc/profile >/dev/null 2>&1 || true
fi
[ -n "${USER:-}" ] || USER=$(id -un 2>/dev/null)

section remote
printf '%s|%s|%s|%s\n' "$(hostname -f 2>/dev/null || hostname)" "$(whoami)" "$PWD" "$(date -Iseconds 2>/dev/null || date)"
finish remote $?

section jobs_json
squeue -u "$USER" --json 2>/dev/null
finish jobs_json $?

section jobs
squeue -u "$USER" -h -o '%i|%P|%j|%u|%T|%M|%l|%D|%R'
finish jobs $?

section job_details
# Query per id and tolerate vanished jobs: a job finishing between the
# squeue above and this scontrol would otherwise fail the WHOLE list with
# "Invalid job id specified" (exit 1) — a race that fires constantly for
# short-lived jobs and used to poison every snapshot.
for job_id in $(squeue -u "$USER" -h -o '%i'); do
    scontrol show job -o "$job_id" 2>/dev/null || true
done
finish job_details 0

section partitions
# %l (partition time limit) is last so older parsers see an 8-field prefix.
sinfo -h -o '%P|%a|%D|%t|%G|%c|%m|%f|%l'
finish partitions $?

section nodes
sinfo -N -h -o '%N|%P|%t|%C|%m|%G|%f|%E'
finish nodes $?

section node_details
scontrol show node -o
finish node_details $?

section storage
"""

REMOTE_SCRIPT_TAIL = r"""finish storage 0
"""


def build_remote_script(volumes: list[StorageVolume], budget: int = DEFAULT_TIMEOUT) -> str:
    return REMOTE_SCRIPT_HEAD + build_storage_script(volumes, budget) + REMOTE_SCRIPT_TAIL


# Core sections make or break a snapshot: their failure means the connection
# or Slurm itself is unusable, so it surfaces as an error (the app treats any
# error as a failed refresh). Enrichment sections only add detail on top of a
# perfectly good snapshot — their failure must never mark the session offline,
# so it is reported as a warning instead.
CORE_SECTIONS = (
    "remote",
    "jobs",
    "partitions",
    "nodes",
)

ENRICHMENT_SECTIONS = (
    "job_details",
    "node_details",
    "storage",
)

EXPECTED_SECTIONS = CORE_SECTIONS + ENRICHMENT_SECTIONS


def split_sections(output: str) -> tuple[dict[str, str], dict[str, int]]:
    sections: dict[str, list[str]] = {}
    statuses: dict[str, int] = {}
    current: str | None = None
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith(SECTION_MARKER_PREFIX) and stripped.endswith(MARKER_SUFFIX):
            current = stripped[len(SECTION_MARKER_PREFIX):-len(MARKER_SUFFIX)]
            sections[current] = []
            continue
        if stripped.startswith(STATUS_MARKER_PREFIX) and stripped.endswith(MARKER_SUFFIX):
            body = stripped[len(STATUS_MARKER_PREFIX):-len(MARKER_SUFFIX)]
            name, _, code = body.rpartition(":")
            try:
                statuses[name] = int(code)
            except ValueError:
                pass
            current = None
            continue
        if current is not None:
            sections[current].append(line)
    joined = {name: "\n".join(lines).strip("\n") for name, lines in sections.items()}
    return joined, statuses


def remote_host_label(config: SSHConfig) -> str:
    return (config.hostname or config.host) if config.username else config.host


def empty_snapshot(
    config: SSHConfig,
    cluster: ClusterInfo,
    collected_at: str,
    error: str,
) -> ClusterSnapshot:
    return ClusterSnapshot(
        collected_at=collected_at,
        cluster=cluster,
        remote=RemoteInfo(host=remote_host_label(config), hostname="", user="", cwd="", remote_time=""),
        jobs=[],
        partitions=[],
        nodes=[],
        storage=[],
        errors=[error],
    )


def assemble_snapshot(
    config: SSHConfig,
    cluster: ClusterInfo,
    volumes: list[StorageVolume],
    collected_at: str,
    output: str,
    error: str | None,
    timed_out: bool,
) -> ClusterSnapshot:
    """Turn the raw remote output of one round trip into a snapshot."""
    errors: list[str] = []
    warnings: list[str] = []
    sections, statuses = split_sections(output)

    core_complete = bool(sections) and all(statuses.get(name) == 0 for name in CORE_SECTIONS)
    if error:
        # A timeout after every core section finished cleanly (typically a
        # hung filesystem stalling df/quota/lfs in the storage section) still
        # yields a good snapshot; the stall is reported as a warning.
        if timed_out and core_complete:
            warnings.append(f"{error} (core sections were complete; storage may be partial)")
        else:
            errors.append(error)

    if sections:
        for name in CORE_SECTIONS:
            code = statuses.get(name)
            if code is None:
                errors.append(f"Section '{name}' missing from remote output")
            elif code != 0:
                errors.append(f"Section '{name}' failed with exit {code}")
        for name in ENRICHMENT_SECTIONS:
            code = statuses.get(name)
            if code is None:
                warnings.append(f"Section '{name}' missing from remote output")
            elif code != 0:
                warnings.append(f"Section '{name}' failed with exit {code}")

    jobs: list[Job] | None = None
    if statuses.get("jobs_json") == 0 and sections.get("jobs_json"):
        jobs = parse_jobs_json(sections["jobs_json"])
    if jobs is None:
        jobs = parse_jobs(sections.get("jobs", ""), sections.get("job_details", ""))

    # No storage section at all (round trip failed or ended before it):
    # report no rows rather than one placeholder per volume. A section that
    # started but was cut short still lists required volumes as unavailable.
    storage: list[StorageSummary] = []
    if "storage" in sections:
        storage, storage_warnings = parse_storage(sections["storage"], volumes)
        warnings.extend(storage_warnings)

    return ClusterSnapshot(
        collected_at=collected_at,
        cluster=cluster,
        remote=parse_remote_info(remote_host_label(config), sections.get("remote", "")),
        jobs=jobs,
        partitions=parse_partitions(sections.get("partitions", "")),
        nodes=parse_nodes(sections.get("nodes", ""), sections.get("node_details", "")),
        storage=storage,
        errors=errors,
        warnings=warnings,
    )


def collect_snapshot(
    config: SSHConfig,
    cluster: ClusterInfo,
    volumes: list[StorageVolume],
) -> ClusterSnapshot:
    collected_at = datetime.now(timezone.utc).isoformat()
    # config.timeout is the budget for EVERYTHING below, so the collector
    # always prints its JSON before a caller watchdog of timeout + a few
    # seconds fires (the app: --timeout 30, 40 s watchdog). A hung storage
    # command then costs the storage rows (a warning), never the snapshot.
    deadline = time.monotonic() + config.timeout

    probe_error = probe_master(config, timeout=min(PROBE_TIMEOUT, config.timeout))
    if probe_error:
        return empty_snapshot(config, cluster, collected_at, probe_error)

    remaining = max(1.0, deadline - time.monotonic())
    output, error, timed_out = run_ssh(
        config, build_remote_script(volumes, config.timeout), run_timeout=remaining
    )
    return assemble_snapshot(config, cluster, volumes, collected_at, output, error, timed_out)


# ---------------------------------------------------------------------------
# Self-tests
# ---------------------------------------------------------------------------


AIRE_SPEC = (
    '[{"label":"Home","paths":["$HOME"],"quota":"nfs"},'
    '{"label":"Scratch","paths":["/scratch-aire/users/$USER","/mnt/scratch/$USER","/mnt/scratch/users/$USER"],"quota":"lustre"},'
    '{"label":"Flash","paths":["/flash-aire/users/$USER","/mnt/flash/$USER","/mnt/flash/users/$USER"],"quota":"lustre","optional":true}]'
)
CALDER_SPEC = (
    '[{"label":"Home","paths":["$HOME"],"quota":"nfs"},'
    '{"label":"Scratch","paths":["/scratch-calder/users/$USER","/scratch-calder/$USER"],"quota":"lustre"},'
    '{"label":"Flash","paths":["/flash-calder/users/$USER","/flash-calder/$USER"],"quota":"lustre","optional":true}]'
)


def _shell_expand(word: str, env: dict[str, str]) -> str | None:
    """Evaluate one rendered shell word with /bin/sh (self-test helper)."""
    if not os.path.exists("/bin/sh"):
        return None
    completed = subprocess.run(
        ["/bin/sh", "-c", f"printf '%s' {word}"],
        check=False,
        capture_output=True,
        text=True,
        env=env,
        stdin=subprocess.DEVNULL,
        timeout=10,
    )
    return completed.stdout if completed.returncode == 0 else None


def _write_stub(directory: str, name: str, body: str) -> None:
    path = os.path.join(directory, name)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("#!/bin/sh\n" + body)
    os.chmod(path, 0o755)


def _run_remote_script_locally(check) -> None:  # type: ignore[no-untyped-def]
    """Execute the generated remote script under the LOCAL /bin/sh against a
    fake directory tree and stub slurm/df/quota/lfs/timeout commands. Proves
    the generated shell (quoting, candidate resolution, project-id branch,
    mount extraction, hpc_run wrapping, section markers) end to end without
    any SSH."""
    if not os.path.exists("/bin/sh") or shutil.which("awk") is None:
        return
    # A temp root containing a space and a single quote exercises quoting.
    root = tempfile.mkdtemp(prefix="hpc self'test ")
    try:
        bin_dir = os.path.join(root, "bin")
        home = os.path.join(root, "home", "alice")
        scratch = os.path.join(root, "scratch-calder", "users", "alice")
        for directory in (bin_dir, home, scratch):
            os.makedirs(directory)
        # Stubs. df reports the NFS home or the Lustre scratch depending on
        # the path; lfs only answers for the project id it hands out.
        _write_stub(bin_dir, "df", (
            'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\\n"\n'
            'case "$2" in\n'
            '*scratch-calder*) printf "10.20.0.1@o2ib:/scratch 5944000000000 1200000000000 4744000000000 21%% /scratch-calder\\n" ;;\n'
            '*) printf "10.10.0.15:/export/users 104857600000 70000000000 34857600000 67%% /users\\n" ;;\n'
            'esac\n'
        ))
        _write_stub(bin_dir, "quota", (
            'printf "Disk quotas for user alice (uid 1001):\\n"\n'
            'printf "     Filesystem   space   quota   limit   grace   files   quota   limit   grace\\n"\n'
            'printf "10.10.0.15:/export/users  45455M  66560M  66560M            294k  1500k  1500k\\n"\n'
        ))
        _write_stub(bin_dir, "lfs", (
            'if [ "$1" = project ]; then printf "123456 P %s\\n" "$3"; exit 0; fi\n'
            'if [ "$1" = quota ] && [ "$2" = -p ] && [ "$3" = 123456 ] && [ "$4" = /scratch-calder ]; then\n'
            '  printf "Disk quotas for prj 123456 (pid 123456):\\n"\n'
            '  printf "     Filesystem  kbytes   quota   limit   grace   files   quota   limit   grace\\n"\n'
            '  printf " /scratch-calder  182648832  1073741824  1181116006  -  235436  0  1000000  -\\n"\n'
            '  exit 0\n'
            'fi\n'
            'exit 1\n'
        ))
        for name, text in (("squeue", ""), ("sinfo", ""), ("scontrol", "")):
            _write_stub(bin_dir, name, f'printf "%s" "{text}"\n')
        # `timeout` logs how hpc_run called it, then runs the command — or,
        # for a df of a path containing $HPC_SELFTEST_STALL, pretends the
        # limit expired (exit 124, no output) like a hung filesystem.
        timeout_log = os.path.join(root, "timeout.log")
        _write_stub(bin_dir, "timeout", (
            f'printf "%s %s %s %s\\n" "$1" "$2" "$3" "$4" >> {shell_single_quote(timeout_log)}\n'
            'shift 3\n'
            'if [ -n "${HPC_SELFTEST_STALL:-}" ] && [ "$1" = df ]; then\n'
            '    case "$3" in *"$HPC_SELFTEST_STALL"*) exit 124 ;; esac\n'
            'fi\n'
            'exec "$@"\n'
        ))
        spec = json.dumps([
            {"label": "Home", "paths": ["$HOME"], "quota": "nfs"},
            {"label": "Scratch", "paths": [root + "/scratch-calder/users/$USER", root + "/scratch-calder/$USER"], "quota": "lustre"},
            {"label": "Flash", "paths": [root + "/flash-calder/users/$USER"], "quota": "lustre", "optional": True},
            {"label": "Projects", "paths": [root + "/projects/${USER}"], "quota": "none"},
        ])
        volumes, spec_error = parse_storage_spec(spec)
        check("harness spec", spec_error is None and len(volumes) == 4, spec_error)
        env = {
            "PATH": bin_dir + os.pathsep + "/usr/bin:/bin",
            "USER": "alice",
            "HOME": home,
            "LC_ALL": "C",
        }

        def run_script(extra_env: dict[str, str]) -> subprocess.CompletedProcess:
            return subprocess.run(
                ["/bin/sh", "-c", build_remote_script(volumes)],
                check=False,
                capture_output=True,
                text=True,
                env=dict(env, **extra_env),
                cwd=home,
                stdin=subprocess.DEVNULL,
                timeout=30,
            )

        completed = run_script({})
        sections, statuses = split_sections(completed.stdout)
        check("harness statuses", statuses.get("storage") == 0 and statuses.get("partitions") == 0,
              (statuses, completed.stderr))
        storage, storage_warnings = parse_storage(sections.get("storage", ""), volumes)
        by_label = {item.label: item for item in storage}
        check("harness labels", sorted(by_label) == ["Home", "Projects", "Scratch"], sorted(by_label))
        home_row = by_label.get("Home")
        check("harness home nfs", home_row is not None and home_row.quota_type == "nfs"
              and home_row.path == home and home_row.limit_gb == 65.0
              and home_row.filesystem == "10.10.0.15:/export/users" and home_row.mount == "/users", home_row)
        scratch_row = by_label.get("Scratch")
        check("harness scratch project", scratch_row is not None
              and scratch_row.quota_type == "lustre-project" and scratch_row.project_id == 123456
              and scratch_row.path == scratch and scratch_row.mount == "/scratch-calder"
              and scratch_row.file_limit == 1_000_000, scratch_row)
        projects_row = by_label.get("Projects")
        check("harness required missing", projects_row is not None
              and projects_row.source == "unavailable" and projects_row.used_gb is None
              and projects_row.path == root + "/projects/alice"
              and projects_row.unavailable_reason == "missing", projects_row)
        check("harness warnings", len(storage_warnings) == 1 and "Projects" in storage_warnings[0],
              storage_warnings)
        try:
            with open(timeout_log, encoding="utf-8") as handle:
                wrapped = [line.split() for line in handle.read().splitlines()]
        except OSError:
            wrapped = []
        # The probe runs once with 5 s; every storage command gets the
        # default budget's 10 s limit and a 2 s SIGKILL grace.
        check("harness hpc_run probe", ["-k", "2", "5", "true"] in wrapped, wrapped)
        check("harness hpc_run commands",
              {words[3] for words in wrapped if words[:3] == ["-k", "2", "10"]} == {"df", "quota", "lfs"},
              wrapped)

        # df of the scratch directory "times out": no df, so no mount, so no
        # lfs query — the row must be "unavailable", never a df row of nulls.
        stalled = run_script({"HPC_SELFTEST_STALL": "scratch-calder"})
        stalled_sections, stalled_statuses = split_sections(stalled.stdout)
        stalled_rows, stalled_warnings = parse_storage(stalled_sections.get("storage", ""), volumes)
        stalled_by_label = {item.label: item for item in stalled_rows}
        stalled_scratch = stalled_by_label.get("Scratch")
        check("harness stalled df", stalled_statuses.get("storage") == 0 and stalled_scratch is not None
              and stalled_scratch.source == "unavailable" and stalled_scratch.path == scratch
              and stalled_scratch.unavailable_reason == "no-figures"
              and stalled_by_label.get("Home") == home_row, (stalled_rows, stalled.stderr))
        check("harness stalled warning", any("Scratch" in w and "no usage figures" in w
                                             for w in stalled_warnings), stalled_warnings)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def _run_collector_with_stub_ssh(check, full_output: str) -> None:  # type: ignore[no-untyped-def]
    """Drive collect_snapshot end to end through a local stub in place of
    ssh. SSHConfig.ssh_executable is the stub's absolute path, so the real
    ssh client, the network and the user's control sockets are never
    involved. The stub answers `-O check` itself and otherwise prints a
    canned remote output, optionally stalling afterwards. Covers lenient
    decoding of non-UTF-8 remote bytes, the overall --timeout budget, and a
    dead master short-circuiting before any round trip."""
    if not os.path.exists("/bin/sh"):
        return
    root = tempfile.mkdtemp(prefix="hpc-selftest-ssh-")
    try:
        round_trip_marker = os.path.join(root, "round-trip-ran")

        def make_stub(name: str, payload: bytes, probe_rc: int = 0, stall: bool = False) -> str:
            fixture = os.path.join(root, name + ".out")
            with open(fixture, "wb") as handle:
                handle.write(payload)
            _write_stub(root, name, (
                'for hpc_arg in "$@"; do\n'
                '    if [ "$hpc_arg" = "-O" ]; then\n'
                f'        [ {probe_rc} -eq 0 ] || echo "Control socket connect: No such file or directory" >&2\n'
                f'        exit {probe_rc}\n'
                '    fi\n'
                'done\n'
                f': > {shell_single_quote(round_trip_marker)}\n'
                f'cat {shell_single_quote(fixture)}\n'
                + ("exec sleep 30\n" if stall else "exit 0\n")
            ))
            return os.path.join(root, name)

        def config_for(stub: str, timeout: int) -> SSHConfig:
            return SSHConfig(host="selftest", username="u", hostname="selftest.invalid",
                             use_jump_host=False, jump_hostname=None,
                             control_path=os.path.join(root, "ctl.sock"), jump_control_path=None,
                             timeout=timeout, ssh_executable=stub)

        cluster = ClusterInfo("calder", "Calder")
        volumes, _ = parse_storage_spec(CALDER_SPEC)

        # 1. A job name with a latin-1 byte (\xe9) must not crash decoding.
        job_line = "777|calder-cpu-turin|caf@E9@-run|u|RUNNING|0:10|2-00:00:00|1|calder-c001"
        text = full_output.replace("=====HPC-SECTION:jobs=====\n",
                                   "=====HPC-SECTION:jobs=====\n" + job_line + "\n")
        stub = make_stub("ssh-latin1", text.encode("utf-8").replace(b"@E9@", b"\xe9"))
        snap = collect_snapshot(config_for(stub, 10), cluster, volumes)
        check("stub ssh non-utf8", snap.errors == [] and len(snap.jobs) == 1
              and snap.jobs[0].name == "caf\ufffd-run"
              and [row.label for row in snap.storage] == ["Home", "Scratch"], (snap.errors, snap.jobs))
        encoded = json.dumps(asdict(snap), ensure_ascii=False).encode("utf-8")
        check("stub ssh json", b"caf\xef\xbf\xbd-run" in encoded, "U+FFFD missing")

        # 2. Core sections arrive, then storage stalls: the whole collection
        #    must end within the budget with a usable snapshot.
        partial = full_output.split("=====HPC-SECTION:storage=====")[0] + (
            "=====HPC-SECTION:storage=====\n__HPC-VOLUME:0__\n__HPC-PATH__\n/users/u\n"
        )
        stub = make_stub("ssh-stall", partial.encode("utf-8"), stall=True)
        budget = 2
        started = time.monotonic()
        stalled = collect_snapshot(config_for(stub, budget), cluster, volumes)
        elapsed = time.monotonic() - started
        check("stub ssh budget", elapsed < budget + 3, f"{elapsed:.1f}s for a {budget}s budget")
        check("stub ssh stall kept", stalled.errors == [] and len(stalled.partitions) == 2
              and any("Timed out" in w for w in stalled.warnings), (stalled.errors, stalled.warnings))
        check("stub ssh stall storage", [(r.label, r.source) for r in stalled.storage]
              == [("Home", "unavailable"), ("Scratch", "unavailable")]
              and not any("showing filesystem totals" in w for w in stalled.warnings), stalled.storage)
        check("stub ssh stall reasons", all(
            r.unavailable_reason in ("no-figures", "not-collected") and "$" not in r.path
            for r in stalled.storage), stalled.storage)

        # 3. Dead master: reported as lost, and no round trip is attempted.
        if os.path.exists(round_trip_marker):
            os.remove(round_trip_marker)
        stub = make_stub("ssh-dead", b"", probe_rc=255)
        dead = collect_snapshot(config_for(stub, 10), cluster, volumes)
        check("stub ssh dead master", len(dead.errors) == 1
              and "control master is not running" in dead.errors[0]
              and not os.path.exists(round_trip_marker), dead.errors)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def run_self_test() -> int:
    failures: list[str] = []
    checks = [0]

    def check(name: str, condition: bool, detail: object = "") -> None:
        checks[0] += 1
        if not condition:
            failures.append(f"{name}: {detail}")

    # --- gres GPU totals (socket/index suffixes, typed gres, lists) ---
    check("gres l40s", parse_gres_gpu_total("gpu:l40s:3(S:0-1)") == 3,
          parse_gres_gpu_total("gpu:l40s:3(S:0-1)"))
    check("gres h200", parse_gres_gpu_total("gpu:nvidia_h200:8(S:0-1)") == 8,
          parse_gres_gpu_total("gpu:nvidia_h200:8(S:0-1)"))
    check("gres idx", parse_gres_gpu_total("gpu:4(IDX:0-3)") == 4,
          parse_gres_gpu_total("gpu:4(IDX:0-3)"))
    check("gres list", parse_gres_gpu_total("gpu:a100:4,mps:400") == 4,
          parse_gres_gpu_total("gpu:a100:4,mps:400"))
    check("gres null", parse_gres_gpu_total("(null)") is None,
          parse_gres_gpu_total("(null)"))
    check("gres bare", parse_gres_gpu_total("gpu") == 1, parse_gres_gpu_total("gpu"))

    # --- over-quota markers and units ---
    check("size star", parse_size_to_gb("12.5G*") == 12.5, parse_size_to_gb("12.5G*"))
    check("size plus", parse_size_to_gb("12.5G+") == 12.5, parse_size_to_gb("12.5G+"))
    check("size tb", parse_size_to_gb("1T") == 1024, parse_size_to_gb("1T"))
    check("size raw kib", parse_size_to_gb("1073741824") == 1024, parse_size_to_gb("1073741824"))
    check("size lfs k", parse_size_to_gb("4k") == 4 / 1024 / 1024, parse_size_to_gb("4k"))
    check("count star", parse_count("100k*") == 100_000, parse_count("100k*"))
    check("count dash", parse_count("-") is None, parse_count("-"))

    # --- parse_key_values must not treat '--lr=0.1' as a key ---
    kv = parse_key_values(
        "JobId=123 Command=/home/u/run.sh --lr=0.1 --batch=32 WorkDir=/home/u"
    )
    check("kv command", kv.get("Command") == "/home/u/run.sh --lr=0.1 --batch=32", kv)
    check("kv workdir", kv.get("WorkDir") == "/home/u", kv)

    # --- array-job detail join ---
    scontrol_output = (
        "JobId=12345 ArrayJobId=12340 ArrayTaskId=5 JobName=train "
        "SubmitTime=2026-07-19T09:00:00 WorkDir=/home/u NumCPUs=8 NodeList=gpu001"
    )
    squeue_output = "12340_5|gpu|train|user|RUNNING|1:00|2:00:00|1|gpu001"
    jobs = parse_jobs(squeue_output, scontrol_output)
    check("array join count", len(jobs) == 1, jobs)
    if jobs:
        check("array join workdir", jobs[0].work_dir == "/home/u", jobs[0])
        check("array join cpus", jobs[0].num_cpus == 8, jobs[0])

    # --- '|' inside the job name ---
    fields = split_job_fields("123|gpu|my|weird|name|user|RUNNING|1:00|2:00:00|1|(Priority)")
    check("pipe name", fields is not None and fields[2] == "my|weird|name", fields)

    # --- home quota: wrapped layout, over quota ---
    wrapped = [
        "Disk quotas for user u (uid 12345):",
        "     Filesystem   space   quota   limit   grace   files   quota   limit   grace",
        "storage:/export/users",
        "                  12.5G*    10G     15G   6days    100k    200k    300k",
    ]
    hq = parse_home_quota(wrapped)
    check("home wrapped used", hq.get("used_gb") == 12.5, hq)
    check("home wrapped files", hq.get("file_count_int") == 100_000, hq)
    check("home wrapped over", hq.get("over_quota") is True, hq)

    # --- home quota: single-line layout ---
    single = [
        "Disk quotas for user u (uid 12345):",
        "     Filesystem   space   quota   limit   grace   files   quota   limit   grace",
        "nfs:/export/users   5G     10G     15G             50k    200k    300k",
    ]
    hq2 = parse_home_quota(single)
    check("home single used", hq2.get("used_gb") == 5, hq2)
    check("home single files", hq2.get("file_count_int") == 50_000, hq2)
    check("home single over", hq2.get("over_quota") is False, hq2)

    # --- NFS quota -s -w as printed on AIRE/Calder, matched by df source ---
    nfs_lines = [
        "Disk quotas for user abcd1234 (uid 1234):",
        "     Filesystem   space   quota   limit   grace   files   quota   limit   grace",
        "10.10.0.15:/export/apps    1M      0K      0K             10       0       0",
        "10.10.0.15:/export/users  45455M  66560M  66560M            294k  1500k  1500k",
    ]
    nq = parse_nfs_quota(nfs_lines, filesystem="10.10.0.15:/export/users")
    check("nfs used", abs((nq.get("used_gb") or 0) - 45455 / 1024) < 1e-9, nq)
    check("nfs limit", nq.get("limit_gb") == 65.0 and nq.get("quota_gb") == 65.0, nq)
    check("nfs files", nq.get("file_count_int") == 294_000 and nq.get("file_limit_int") == 1_500_000, nq)
    check("nfs not over", nq.get("over_quota") is False, nq)
    nq_alias = parse_nfs_quota(nfs_lines, filesystem="nfs-home.leeds:/export/users")
    check("nfs export-path match", nq_alias.get("limit_gb") == 65.0, nq_alias)
    check("nfs no match", parse_nfs_quota(nfs_lines, filesystem="10.10.0.15:/export/other") == {},
          "expected no match")
    # File grace present, block grace absent: columns must not shift.
    file_grace = ["nfs:/export/users  5G  10G  15G  300k*  200k  300k  6days"]
    fg = parse_nfs_quota(file_grace, filesystem="nfs:/export/users")
    check("nfs file grace", fg.get("file_count_int") == 300_000 and fg.get("file_limit_int") == 300_000
          and fg.get("over_quota") is True, fg)

    # --- lfs quota with over-quota marker (-h form, legacy fixture) ---
    lfs = [
        "Disk quotas for usr u (uid 12345):",
        "     Filesystem  used   quota   limit   grace   files   quota   limit   grace",
        "   /mnt/scratch  500G*     1T    1.5T       -  100000  200000  300000       -",
    ]
    lq = parse_lfs_quota(lfs, mount="/mnt/scratch")
    check("lfs used", lq.get("used_gb") == 500, lq)
    check("lfs files", lq.get("file_count_int") == 100_000, lq)
    check("lfs over", lq.get("over_quota") is True, lq)

    # --- lfs project quota, raw KiB (Calder scratch) ---
    lfs_project = [
        "Disk quotas for prj 123456 (pid 123456):",
        "     Filesystem  kbytes   quota   limit   grace   files   quota   limit   grace",
        "/scratch-calder  182648832  1073741824  1181116006  -  235436  0  1000000  -",
    ]
    lp = parse_lfs_quota(lfs_project, mount="/scratch-calder")
    check("lfs prj used", abs((lp.get("used_gb") or 0) - 182648832 / 1024 / 1024) < 1e-9, lp)
    check("lfs prj quota", lp.get("quota_gb") == 1024.0, lp)
    check("lfs prj limit", abs((lp.get("limit_gb") or 0) - 1181116006 / 1024 / 1024) < 1e-9, lp)
    check("lfs prj files", lp.get("file_count_int") == 235_436 and lp.get("file_quota_int") is None
          and lp.get("file_limit_int") == 1_000_000, lp)
    check("lfs prj not over", lp.get("over_quota") is False, lp)

    # --- same, wrapped layout (filesystem alone on its line) ---
    lfs_wrapped = [
        "Disk quotas for prj 123456 (pid 123456):",
        "     Filesystem  kbytes   quota   limit   grace   files   quota   limit   grace",
        "/scratch-calder-longer-name",
        "                182648832  1073741824  1181116006       -  235436       0 1000000       -",
    ]
    lw = parse_lfs_quota(lfs_wrapped, mount="/scratch-calder-longer-name")
    check("lfs wrapped", lw.get("quota_gb") == 1024.0 and lw.get("file_count_int") == 235_436, lw)

    # --- same quota in -h form ---
    lfs_human = [
        "Disk quotas for prj 123456 (pid 123456):",
        "     Filesystem    used   quota   limit   grace   files   quota   limit   grace",
        "/scratch-calder  174.2G      1T    1.1T       -  235436       0 1000000       -",
    ]
    lh = parse_lfs_quota(lfs_human, mount="/scratch-calder")
    check("lfs human", abs((lh.get("used_gb") or 0) - 174.2) < 1e-9 and lh.get("quota_gb") == 1024.0
          and abs((lh.get("limit_gb") or 0) - 1126.4) < 1e-9, lh)

    # --- AIRE user quota, raw KiB, soft quota 0 = no soft limit ---
    lfs_aire = [
        "Disk quotas for usr abcd1234 (uid 1234):",
        "     Filesystem  kbytes   quota   limit   grace   files   quota   limit   grace",
        "/mnt/scratch 3605893120 0 4294967296 - 3182119 0 5000000 -",
    ]
    la = parse_lfs_quota(lfs_aire, mount="/mnt/scratch")
    check("lfs aire limit", la.get("limit_gb") == 4096.0 and la.get("quota_gb") is None, la)
    check("lfs aire used", abs((la.get("used_gb") or 0) - 3605893120 / 1024 / 1024) < 1e-9, la)
    check("lfs aire files", la.get("file_count_int") == 3_182_119 and la.get("file_limit_int") == 5_000_000, la)

    # --- lfs figures in brackets (some OSTs/MDTs did not answer) ---
    lfs_bracket = [
        "Disk quotas for usr abcd1234 (uid 1234):",
        "     Filesystem  kbytes   quota   limit   grace   files   quota   limit   grace",
        "   /mnt/scratch [3605893120]  0 4294967296  - 3182119 0 5000000 -",
        'Some errors happened when getting quota info. Some devices may be not working or '
        'deactivated. The data in "[]" is inaccurate.',
    ]
    lb = parse_lfs_quota(lfs_bracket, mount="/mnt/scratch")
    check("lfs bracket used", abs((lb.get("used_gb") or 0) - 3605893120 / 1024 / 1024) < 1e-9
          and lb.get("limit_gb") == 4096.0 and lb.get("file_limit_int") == 5_000_000, lb)
    check("lfs bracket flagged", lb.get("inaccurate") is True and lb.get("over_quota") is False, lb)
    lb_over = parse_lfs_quota(
        ["/scratch-calder [1100000000]* 1073741824 1181116006 6d23h59m59s [235436] 0 1000000 -"],
        mount="/scratch-calder",
    )
    check("lfs bracket marker", lb_over.get("over_quota") is True and lb_over.get("inaccurate") is True
          and lb_over.get("file_count_int") == 235_436, lb_over)
    lb_wrapped = parse_lfs_quota(
        ["/scratch-calder-longer-name", "   [182648832]  1073741824  1181116006  -  235436  0  1000000  -"],
        mount="/scratch-calder-longer-name",
    )
    check("lfs bracket wrapped", lb_wrapped.get("quota_gb") == 1024.0
          and lb_wrapped.get("inaccurate") is True, lb_wrapped)
    check("lfs accurate unflagged", "inaccurate" not in lp and "inaccurate" not in la, (lp, la))

    # --- lfs grace that looks like a size: '5m' = five minutes left ---
    for name, row in (
        ("raw", "/scratch-calder  1100000000*  1073741824  1181116006  5m  235436  0  1000000  -"),
        ("human", "/scratch-calder  1.1T*  1T  1.1T  5m  235436  0  1000000  -"),
    ):
        g5 = parse_lfs_quota([row], mount="/scratch-calder")
        check(f"lfs grace 5m {name}", g5.get("file_count_int") == 235_436 and g5.get("file_quota_int") is None
              and g5.get("file_limit_int") == 1_000_000 and g5.get("over_quota") is True, g5)
    # Seven raw columns (an older lfs leaves the file grace blank when the
    # file hard limit is hit): only the raw-means-no-suffix rule tells the
    # '5m' block grace from a file count here.
    g7 = parse_lfs_quota(["/scratch-calder 1100000000* 1073741824 1181116006 5m 1000000* 0 1000000"],
                         mount="/scratch-calder")
    check("lfs grace 5m seven columns", g7.get("file_count_int") == 1_000_000
          and g7.get("file_limit_int") == 1_000_000 and g7.get("file_quota_int") is None, g7)
    # Raw row with a blank block grace (older lfs, hard limit hit): the
    # first file column is a bare integer and must not be skipped.
    g_blank = parse_lfs_quota(["/mnt/scratch 4294967296* 0 4294967296 3182119 0 5000000 -"],
                              mount="/mnt/scratch")
    check("lfs blank grace", g_blank.get("file_count_int") == 3_182_119
          and g_blank.get("file_limit_int") == 5_000_000, g_blank)

    # --- partitions: new 9-column layout with %l, and legacy 8 columns ---
    calder_partitions = parse_partitions(
        "calder-cpu-turin*|up|98|mix|(null)|128|772480|(null)|2-00:00:00\n"
        "calder-gpu-hopper|up|7|mix|gpu:nvidia_h200:8(S:0-1)|128|1546664|(null)|2-00:00:00\n"
        "nodes|up|52|mix|(null)|168|768000|(null)|infinite\n"
        "legacy|up|1|idle|(null)|8|1000|none\n"
    )
    check("partition count", len(calder_partitions) == 4, calder_partitions)
    if len(calder_partitions) == 4:
        cpu, gpu, aire_nodes, legacy = calder_partitions
        check("partition default star", cpu.partition == "calder-cpu-turin", cpu)
        check("partition time limit", cpu.time_limit == "2-00:00:00" and gpu.time_limit == "2-00:00:00", cpu)
        check("partition infinite", aire_nodes.time_limit == "infinite", aire_nodes)
        check("partition gpu gres", parse_gres_gpu_total(gpu.gres) == 8 and gpu.memory_mb_per_node == 1546664, gpu)
        check("partition legacy", legacy.time_limit is None and legacy.features == "none", legacy)

    # --- path-template quoting ---
    check("render user", render_path_template("/scratch-calder/users/$USER")
          == "'/scratch-calder/users/'\"$USER\"", render_path_template("/scratch-calder/users/$USER"))
    check("render home", render_path_template("$HOME") == '"$HOME"', render_path_template("$HOME"))
    check("render braces", render_path_template("${HOME}/x") == "\"$HOME\"'/x'",
          render_path_template("${HOME}/x"))
    check("render other vars literal", render_path_template("/d/$USERNAME/$SCRATCH")
          == "'/d/$USERNAME/$SCRATCH'", render_path_template("/d/$USERNAME/$SCRATCH"))
    check("render quote", render_path_template("/o'brien/$USER")
          == "'/o'\"'\"'brien/'\"$USER\"", render_path_template("/o'brien/$USER"))
    shell_env = {"PATH": "/usr/bin:/bin", "USER": "alice", "HOME": "/home/alice",
                 "SCRATCH": "/should/not/expand", "USERNAME": "nope"}
    for template, expected in (
        ("/scratch-calder/users/$USER", "/scratch-calder/users/alice"),
        ("$HOME", "/home/alice"),
        ("${HOME}/a b", "/home/alice/a b"),
        ("/o'brien/$USER", "/o'brien/alice"),
        ("/x/$SCRATCH/$USERNAME/${SCRATCH}", "/x/$SCRATCH/$USERNAME/${SCRATCH}"),
        ("/x/$(id -un)/`id -un`/*/\"$USER\"", "/x/$(id -un)/`id -un`/*/\"alice\""),
        ("$USER$HOME", "alice/home/alice"),
    ):
        expanded = _shell_expand(render_path_template(template), shell_env)
        if expanded is not None:
            check(f"shell expand {template!r}", expanded == expected, expanded)

    # --- storage spec validation (errors, never exceptions) ---
    default_volumes, default_error = parse_storage_spec(None)
    check("spec default", default_error is None and [v.label for v in default_volumes] == ["Home"],
          default_error)
    for name, text in (
        ("bad json", "[{"),
        ("not list", '{"label": "Home"}'),
        ("no label", '[{"paths": ["$HOME"]}]'),
        ("no paths", '[{"label": "Home", "paths": []}]'),
        ("bad quota", '[{"label": "Home", "paths": ["$HOME"], "quota": "zfs"}]'),
        ("bad optional", '[{"label": "Home", "paths": ["$HOME"], "optional": "yes"}]'),
        ("dup label", '[{"label": "Home", "paths": ["$HOME"]}, {"label": "Home", "paths": ["/x"]}]'),
        ("newline path", '[{"label": "Home", "paths": ["/a\\nb"]}]'),
        # Deep nesting (still under the size cap) exhausts the JSON
        # decoder's recursion limit: RecursionError, not JSONDecodeError.
        ("deep nesting", "[" * 16000),
        ("oversize", '[{"label": "Home", "paths": ["' + "x" * MAX_STORAGE_SPEC_CHARS + '"]}]'),
    ):
        volumes, error = parse_storage_spec(text)
        check(f"spec {name}", volumes == [] and bool(error) and error.startswith(STORAGE_SPEC_ERROR_PREFIX),
              error)
    for name, text in (("aire", AIRE_SPEC), ("calder", CALDER_SPEC)):
        volumes, error = parse_storage_spec(text)
        check(f"spec {name}", error is None and [v.label for v in volumes] == ["Home", "Scratch", "Flash"]
              and volumes[2].optional and volumes[1].quota == "lustre", error)
    # A bad spec must surface as snapshot.errors without any SSH round trip.
    bad_config = SSHConfig(host="aire", username=None, hostname=None, use_jump_host=False,
                           jump_hostname=None, control_path=None, jump_control_path=None, timeout=5)
    _, bad_error = parse_storage_spec("not json")
    bad_snapshot = empty_snapshot(bad_config, ClusterInfo("aire", "AIRE"), "now", bad_error or "")
    check("spec error snapshot", bad_snapshot.errors == [bad_error] and bad_snapshot.storage == []
          and asdict(bad_snapshot)["cluster"] == {"id": "aire", "name": "AIRE"}, bad_snapshot.errors)

    # --- generated script: every literal quoted, markers renamed ---
    calder_volumes, _ = parse_storage_spec(CALDER_SPEC)
    script = build_remote_script(calder_volumes)
    check("script calder candidates",
          "hpc_volume 1 'lustre' '/scratch-calder/users/'\"$USER\" '/scratch-calder/'\"$USER\"" in script,
          script[-400:])
    check("script markers", "=====HPC-SECTION:" in script and "AIRE-SECTION" not in script, "markers")
    check("script time limit", "%f|%l'" in script, "sinfo format")
    check("script storage timeout", "hpc_storage_timeout=10\n" in script
          and "hpc_storage_timeout=2\n" in build_remote_script(calder_volumes, 5)
          and "hpc_run df -Pk" in script and "hpc_run lfs quota -p" in script, "hpc_run")
    check("storage command timeout", [storage_command_timeout(b) for b in (1, 8, 20, 30, 300)]
          == [2, 2, 6, 10, 10], "clamp")

    # --- bracketed lfs figures surface as a warning on the storage row ---
    bracket_rows, bracket_warnings = parse_storage("\n".join([
        "__HPC-VOLUME:1__", "__HPC-PATH__", "/mnt/scratch/abcd1234", "__HPC-DF__",
        "Filesystem 1024-blocks Used Available Capacity Mounted on",
        "10.1.0.1@o2ib:/scratch 3972844748800 2000000000000 1972844748800 51% /mnt/scratch",
        "__HPC-MOUNT__", "/mnt/scratch", "__HPC-PROJECT__", "0", "__HPC-QUOTA__",
    ] + lfs_bracket + ["__HPC-VOLUME-END:1__"]), [
        StorageVolume("Home", ("$HOME",), "none", optional=True),
        StorageVolume("Scratch", ("/mnt/scratch/$USER",), "lustre"),
    ])
    check("bracket row", len(bracket_rows) == 1 and bracket_rows[0].quota_type == "lustre-user"
          and bracket_rows[0].limit_gb == 4096.0, bracket_rows)
    check("bracket warning", len(bracket_warnings) == 1 and "inaccurate" in bracket_warnings[0],
          bracket_warnings)

    # --- section splitting ---
    sample = (
        "\n=====HPC-SECTION:remote=====\n"
        "host|user|/home/u|2026-07-19T10:00:00\n"
        "\n=====HPC-STATUS:remote:0=====\n"
        "\n=====HPC-SECTION:jobs=====\n"
        "\n=====HPC-STATUS:jobs:1=====\n"
    )
    sections, statuses = split_sections(sample)
    check("sections remote", sections.get("remote") == "host|user|/home/u|2026-07-19T10:00:00",
          sections)
    check("statuses", statuses == {"remote": 0, "jobs": 1}, statuses)

    # --- full synthetic Calder round trip: Home nfs + Scratch lustre-project
    #     + optional Flash missing (omitted) ---
    calder_output = "\n".join([
        "=====HPC-SECTION:remote=====",
        "calder-login-1.arc.leeds.ac.uk|abcd1234|/users/abcd1234|2026-10-12T02:00:00+01:00",
        "=====HPC-STATUS:remote:0=====",
        "=====HPC-SECTION:jobs_json=====",
        "=====HPC-STATUS:jobs_json:1=====",
        "=====HPC-SECTION:jobs=====",
        "=====HPC-STATUS:jobs:0=====",
        "=====HPC-SECTION:job_details=====",
        "=====HPC-STATUS:job_details:0=====",
        "=====HPC-SECTION:partitions=====",
        "calder-cpu-turin*|up|98|mix|(null)|128|772480|(null)|2-00:00:00",
        "calder-gpu-hopper|up|7|mix|gpu:nvidia_h200:8(S:0-1)|128|1546664|(null)|2-00:00:00",
        "=====HPC-STATUS:partitions:0=====",
        "=====HPC-SECTION:nodes=====",
        "calder-h200-01|calder-gpu-hopper|mix|64/64/0/128|1546664|gpu:nvidia_h200:8(S:0-1)|(null)|none",
        "=====HPC-STATUS:nodes:0=====",
        "=====HPC-SECTION:node_details=====",
        "NodeName=calder-h200-01 CfgTRES=cpu=128,mem=1546664M,gres/gpu=8 AllocTRES=cpu=64,gres/gpu=5",
        "=====HPC-STATUS:node_details:0=====",
        "=====HPC-SECTION:storage=====",
        "__HPC-VOLUME:0__",
        "__HPC-PATH__",
        "/users/abcd1234",
        "__HPC-DF__",
        "Filesystem              1024-blocks        Used   Available Capacity Mounted on",
        "10.10.0.15:/export/users 104857600000 70000000000 34857600000      67% /users",
        "__HPC-MOUNT__",
        "/users",
        "__HPC-QUOTA__",
        "Disk quotas for user abcd1234 (uid 1234):",
        "     Filesystem   space   quota   limit   grace   files   quota   limit   grace",
        "10.10.0.15:/export/users  45455M  66560M  66560M            294k  1500k  1500k",
        "__HPC-VOLUME-END:0__",
        "__HPC-VOLUME:1__",
        "__HPC-PATH__",
        "/scratch-calder/users/abcd1234",
        "__HPC-DF__",
        "Filesystem                1024-blocks          Used     Available Capacity Mounted on",
        "10.20.0.1@o2ib:/scratch 5944000000000 1200000000000 4744000000000      21% /scratch-calder",
        "__HPC-MOUNT__",
        "/scratch-calder",
        "__HPC-PROJECT__",
        "123456",
        "__HPC-QUOTA__",
        "Disk quotas for prj 123456 (pid 123456):",
        "     Filesystem  kbytes   quota   limit   grace   files   quota   limit   grace",
        "/scratch-calder  182648832  1073741824  1181116006  -  235436  0  1000000  -",
        "__HPC-VOLUME-END:1__",
        "__HPC-VOLUME:2__",
        "__HPC-TRIED__",
        "/flash-calder/users/abcd1234",
        "/flash-calder/abcd1234",
        "__HPC-VOLUME-END:2__",
        "=====HPC-STATUS:storage:0=====",
    ])
    calder_config = SSHConfig(host="calder", username="abcd1234", hostname="calder.leeds.ac.uk",
                              use_jump_host=False, jump_hostname=None, control_path=None,
                              jump_control_path=None, timeout=5)
    snap = assemble_snapshot(calder_config, ClusterInfo("calder", "Calder"), calder_volumes,
                             "now", calder_output, None, False)
    check("calder errors", snap.errors == [], snap.errors)
    check("calder warnings", snap.warnings == [], snap.warnings)
    check("calder cluster", snap.cluster == ClusterInfo("calder", "Calder"), snap.cluster)
    check("calder remote host", snap.remote.host == "calder.leeds.ac.uk"
          and snap.remote.user == "abcd1234", snap.remote)
    check("calder storage labels", [s.label for s in snap.storage] == ["Home", "Scratch"],
          [s.label for s in snap.storage])
    check("calder partitions", [p.time_limit for p in snap.partitions] == ["2-00:00:00", "2-00:00:00"],
          snap.partitions)
    check("calder node gpus", len(snap.nodes) == 1 and snap.nodes[0].gpu_total == 8
          and snap.nodes[0].gpu_idle == 3, snap.nodes)
    if len(snap.storage) == 2:
        home_row, scratch_row = snap.storage
        check("calder home", home_row.quota_type == "nfs" and home_row.source == "quota"
              and home_row.limit_gb == 65.0 and home_row.mount == "/users"
              and home_row.path == "/users/abcd1234" and home_row.project_id is None, home_row)
        check("calder scratch", scratch_row.quota_type == "lustre-project"
              and scratch_row.project_id == 123456 and scratch_row.source == "lfs quota"
              and scratch_row.path == "/scratch-calder/users/abcd1234"
              and scratch_row.mount == "/scratch-calder"
              and scratch_row.filesystem == "10.20.0.1@o2ib:/scratch"
              and scratch_row.quota_gb == 1024.0 and scratch_row.file_limit == 1_000_000
              and scratch_row.available_gb is not None and scratch_row.available_gb > 900, scratch_row)
        check("calder scratch percent", scratch_row.used_percent is not None
              and 15.0 < scratch_row.used_percent < 16.0, scratch_row.used_percent)
        entry = asdict(scratch_row)
        check("storage json keys", list(entry) == [
            "label", "path", "filesystem", "source", "used_gb", "quota_gb", "limit_gb",
            "available_gb", "used_percent", "file_count", "file_quota", "file_limit",
            "over_quota", "quota_type", "project_id", "mount", "unavailable_reason"], list(entry))
        check("readable row has no unavailable reason", entry["unavailable_reason"] is None, entry)

    # --- quota tool missing -> df fallback with source "df" and a warning;
    #     lfs user quota (project 0) -> lustre-user; storage failure is a
    #     warning only; timeout after complete core sections is a warning ---
    aire_volumes, _ = parse_storage_spec(AIRE_SPEC)
    aire_storage = "\n".join([
        "__HPC-VOLUME:0__", "__HPC-PATH__", "/users/abcd1234", "__HPC-DF__",
        "Filesystem 1024-blocks Used Available Capacity Mounted on",
        "10.10.0.15:/export/users 104857600 52428800 52428800 50% /users",
        "__HPC-MOUNT__", "/users", "__HPC-QUOTA__", "__HPC-VOLUME-END:0__",
        "__HPC-VOLUME:1__", "__HPC-PATH__", "/mnt/scratch/abcd1234", "__HPC-DF__",
        "Filesystem 1024-blocks Used Available Capacity Mounted on",
        "10.1.0.1@o2ib:/scratch 3972844748800 2000000000000 1972844748800 51% /mnt/scratch",
        "__HPC-MOUNT__", "/mnt/scratch", "__HPC-PROJECT__", "0", "__HPC-QUOTA__",
        "Disk quotas for usr abcd1234 (uid 1234):",
        "     Filesystem  kbytes   quota   limit   grace   files   quota   limit   grace",
        "/mnt/scratch 3605893120 0 4294967296 - 3182119 0 5000000 -",
        "__HPC-VOLUME-END:1__",
        "__HPC-VOLUME:2__", "__HPC-TRIED__", "/flash-aire/users/abcd1234", "__HPC-VOLUME-END:2__",
    ])
    aire_rows, aire_warnings = parse_storage(aire_storage, aire_volumes)
    check("aire rows", [r.label for r in aire_rows] == ["Home", "Scratch"], aire_rows)
    if len(aire_rows) == 2:
        check("aire home df fallback", aire_rows[0].source == "df" and aire_rows[0].quota_type == "df"
              and aire_rows[0].used_gb == 50.0 and aire_rows[0].limit_gb == 100.0, aire_rows[0])
        check("aire scratch user", aire_rows[1].quota_type == "lustre-user"
              and aire_rows[1].project_id is None and aire_rows[1].limit_gb == 4096.0
              and aire_rows[1].file_limit == 5_000_000, aire_rows[1])
    check("aire fallback warning", len(aire_warnings) == 1 and "Home" in aire_warnings[0], aire_warnings)

    truncated = calder_output.split("=====HPC-SECTION:storage=====")[0] + (
        "=====HPC-SECTION:storage=====\n__HPC-VOLUME:0__\n__HPC-PATH__\n/users/abcd1234\n__HPC-DF__\n"
    )
    timed = assemble_snapshot(calder_config, ClusterInfo("calder", "Calder"), calder_volumes,
                              "now", truncated, "Timed out after 50s: snapshot collection", True)
    check("timeout core complete", timed.errors == [] and len(timed.partitions) == 2
          and any("Timed out" in w for w in timed.warnings)
          and any("storage" in w for w in timed.warnings), (timed.errors, timed.warnings))
    check("timeout storage rows", [r.label for r in timed.storage] == ["Home", "Scratch"]
          and timed.storage[1].source == "unavailable", timed.storage)
    # Home was cut off right after its PATH line: no df totals exist, so it
    # is "unavailable" (keeping the resolved path), not a df row of nulls.
    if timed.storage:
        check("timeout cut volume unavailable", timed.storage[0].source == "unavailable"
              and timed.storage[0].path == "/users/abcd1234" and timed.storage[0].used_gb is None,
              timed.storage[0])
    check("timeout no df claim", not any("showing filesystem totals" in w for w in timed.warnings)
          and any("no usage figures" in w and "Home" in w for w in timed.warnings), timed.warnings)
    early = calder_output.split("=====HPC-SECTION:partitions=====")[0]
    timed_early = assemble_snapshot(calder_config, ClusterInfo("calder", "Calder"), calder_volumes,
                                    "now", early, "Timed out after 50s: snapshot collection", True)
    check("timeout core incomplete", any("Timed out" in e for e in timed_early.errors), timed_early.errors)
    check("no storage section", timed_early.storage == [], timed_early.storage)
    failed = assemble_snapshot(calder_config, ClusterInfo("calder", "Calder"), calder_volumes,
                               "now", "", "Command failed with exit 255: snapshot collection", False)
    check("failed round trip", failed.errors == ["Command failed with exit 255: snapshot collection"]
          and failed.storage == [] and failed.warnings == [], (failed.errors, failed.warnings))

    # --- generated remote script, executed by the local /bin/sh with stubs ---
    _run_remote_script_locally(check)

    # --- lenient decoding of every ssh invocation ---
    if os.path.exists("/bin/sh"):
        decoded = run_captured(["/bin/sh", "-c", "printf 'caf\\351\\n'"], 10).stdout
        check("run_captured latin-1", decoded == "caf\ufffd\n", repr(decoded))

    # --- collect_snapshot end to end through a stub ssh ---
    _run_collector_with_stub_ssh(check, calder_output)

    # --- CLI: hidden --aire-hostname alias, defaults ---
    legacy_args = parse_args(["--username", "u", "--aire-hostname", "aire.leeds.ac.uk"])
    check("cli aire-hostname alias", legacy_args.hostname == "aire.leeds.ac.uk", legacy_args)
    new_args = parse_args(["--cluster-id", "calder", "--hostname", "calder.leeds.ac.uk"])
    check("cli hostname", new_args.hostname == "calder.leeds.ac.uk" and new_args.cluster_id == "calder",
          new_args)
    check("cli timeout default", new_args.timeout == DEFAULT_TIMEOUT, new_args.timeout)
    for bad_timeout in ("0", "-5", "ten"):
        try:
            positive_int(bad_timeout)
            check(f"cli timeout {bad_timeout!r} refused", False, "accepted")
        except argparse.ArgumentTypeError:
            check(f"cli timeout {bad_timeout!r} refused", True)
    check("cli cluster name default", default_cluster_name("calder") == "Calder"
          and default_cluster_name("aire") == "AIRE" and default_cluster_name("x1") == "X1", "names")
    hostile = SSHConfig(host="aire", username="u", hostname="-oProxyCommand=evil", use_jump_host=False,
                        jump_hostname=None, control_path=None, jump_control_path=None, timeout=5)
    check("cli refuses option-like host", build_ssh_command(hostile, "true")[0] is None, "accepted")
    jump_cmd, jump_error = build_ssh_command(
        SSHConfig(host="calder", username="u", hostname="calder.leeds.ac.uk", use_jump_host=True,
                  jump_hostname="rash.leeds.ac.uk", control_path="/tmp/t.sock",
                  jump_control_path="/tmp/j.sock", timeout=5),
        "true",
    )
    check("cli jump command", jump_error is None and jump_cmd is not None
          and jump_cmd[-2] == "calder.leeds.ac.uk"
          and any("ControlPath=/tmp/j.sock" in part for part in jump_cmd)
          and "ControlMaster=auto" not in " ".join(jump_cmd), jump_cmd)

    # --- squeue --json parsing (plain ints and {set, number} wrappers) ---
    now = datetime(2026, 7, 19, 12, 0, 0)
    start_epoch = int(now.timestamp()) - 3600
    jobs_json = json.dumps(
        {
            "jobs": [
                {
                    "job_id": 101,
                    "name": "train",
                    "partition": "gpu",
                    "user_name": "u",
                    "job_state": ["RUNNING"],
                    "start_time": {"set": True, "infinite": False, "number": start_epoch},
                    "submit_time": start_epoch - 60,
                    "end_time": 0,
                    "time_limit": {"set": True, "infinite": False, "number": 120},
                    "node_count": {"set": True, "number": 1},
                    "nodes": "gpu001",
                    "state_reason": "None",
                    "current_working_directory": "/home/u",
                    "command": "/home/u/run.sh --lr=0.1",
                    "standard_output": "/home/u/out.log",
                    "standard_error": "/home/u/err.log",
                    "batch_host": "gpu001",
                    "cpus": {"set": True, "number": 8},
                    "tasks": 1,
                    "tres_req_str": "cpu=8,mem=32G",
                    "tres_alloc_str": "cpu=8,gres/gpu=1",
                    "tres_per_node": "gres/gpu:1",
                    "array_job_id": {"set": False, "number": 0},
                    "array_task_id": {"set": False, "number": 0},
                },
                {
                    "job_id": 205,
                    "name": "sweep",
                    "partition": "gpu",
                    "user_name": "u",
                    "job_state": "PENDING",
                    "state_reason": "Priority",
                    "time_limit": {"set": False, "infinite": True},
                    "node_count": 1,
                    "nodes": "",
                    "array_job_id": {"set": True, "number": 200},
                    "array_task_id": {"set": True, "number": 5},
                },
            ]
        }
    )
    parsed = parse_jobs_json(jobs_json, now=now)
    check("json jobs count", parsed is not None and len(parsed) == 2, parsed)
    if parsed and len(parsed) == 2:
        running, pending = parsed
        check("json job id", running.job_id == "101", running)
        check("json elapsed", running.elapsed == "1:00:00", running)
        check("json time limit", running.time_limit == "2:00:00", running)
        check("json nodes", running.reason_or_node_list == "gpu001", running)
        check("json cpus", running.num_cpus == 8, running)
        check("json command", running.command == "/home/u/run.sh --lr=0.1", running)
        check("json array id", pending.job_id == "200_5", pending)
        check("json reason", pending.reason_or_node_list == "(Priority)", pending)
        check("json unlimited", pending.time_limit == "UNLIMITED", pending)
    check("json garbage", parse_jobs_json("not json") is None, "expected None")
    check("json no jobs key", parse_jobs_json("{}") is None, "expected None")

    # --- node parsing with gres fallback when details are missing ---
    node_line = "gpu001|gpu|mix|8/40/0/48|512000|gpu:l40s:3(S:0-1)|l40s|none"
    nodes = parse_nodes(node_line)
    check("node gres fallback", len(nodes) == 1 and nodes[0].gpu_total == 3, nodes)
    h200_line = "calder-h200-05|calder-gpu-hopper|idle+drain|0/128/0/128|1546664|gpu:nvidia_h200:8(S:0-1)|(null)|Kill task failed"
    h200_nodes = parse_nodes(h200_line)
    check("node h200 fallback", len(h200_nodes) == 1 and h200_nodes[0].gpu_total == 8
          and h200_nodes[0].reason == "Kill task failed", h200_nodes)

    # --- duration formatting ---
    check("duration days", format_duration(90061) == "1-01:01:01", format_duration(90061))
    check("duration min", format_duration(125) == "2:05", format_duration(125))

    if failures:
        for failure in failures:
            print(f"SELF-TEST FAIL {failure}", file=sys.stderr)
        print(f"{len(failures)} of {checks[0]} self-test check(s) failed", file=sys.stderr)
        return 1
    print(f"All {checks[0]} self-tests passed")
    return 0


def main() -> int:
    args = parse_args()
    if args.self_test:
        return run_self_test()

    cluster = ClusterInfo(
        id=args.cluster_id,
        name=args.cluster_name or default_cluster_name(args.cluster_id),
    )
    hostname = args.hostname
    if args.username and not hostname:
        hostname = KNOWN_CLUSTER_HOSTNAMES.get(args.cluster_id.lower())
    config = SSHConfig(
        host=args.host or args.cluster_id,
        username=args.username,
        hostname=hostname,
        use_jump_host=args.use_jump_host and not args.no_jump_host,
        jump_hostname=args.jump_hostname,
        control_path=args.control_path,
        jump_control_path=args.jump_control_path,
        timeout=args.timeout,
    )

    volumes, spec_error = parse_storage_spec(args.storage_spec)
    if spec_error:
        # Configuration bug, not a cluster problem: report it without
        # spending an SSH round trip on the shared login node.
        snapshot = empty_snapshot(
            config, cluster, datetime.now(timezone.utc).isoformat(), spec_error
        )
    else:
        try:
            snapshot = collect_snapshot(config, cluster, volumes)
        except Exception as exc:  # noqa: BLE001 - last line of defence
            # A collector bug must still produce JSON: with no stdout the app
            # can only say "snapshot script produced no output". The
            # traceback goes to stderr for debugging.
            traceback.print_exc(file=sys.stderr)
            snapshot = empty_snapshot(
                config,
                cluster,
                datetime.now(timezone.utc).isoformat(),
                f"Collector internal error: {type(exc).__name__}: {exc}",
            )

    indent = 2 if args.pretty else None
    payload = json.dumps(asdict(snapshot), indent=indent, ensure_ascii=False) + "\n"
    # Always UTF-8 (what the app decodes), whatever the caller's locale: a
    # non-UTF-8 locale must not turn a non-ASCII job name or a U+FFFD from
    # lenient decoding into a UnicodeEncodeError and an empty stdout.
    sys.stdout.buffer.write(payload.encode("utf-8"))
    sys.stdout.flush()
    return 1 if snapshot.errors else 0


if __name__ == "__main__":
    sys.exit(main())
