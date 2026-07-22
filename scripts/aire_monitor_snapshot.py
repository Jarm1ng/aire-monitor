#!/usr/bin/env python3
"""Collect a read-only Slurm snapshot from AIRE over SSH.

This script is intentionally local-only: it does not install anything on the
server, write remote files, submit jobs, or cancel jobs. It only runs read-only
Slurm commands through the existing SSH host alias.

All remote commands are batched into a single SSH round-trip: a small POSIX
shell script prints section-delimited output which is parsed locally. Each
section carries its own exit status so one failing command does not discard
the rest of the snapshot.

Run with --self-test to exercise the parsers against embedded fixtures.
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Iterable


DEFAULT_HOST = "aire"
FIELD_SEPARATOR = "|"
SECTION_MARKER_PREFIX = "=====AIRE-SECTION:"
STATUS_MARKER_PREFIX = "=====AIRE-STATUS:"
MARKER_SUFFIX = "====="


@dataclass(frozen=True)
class SSHConfig:
    host: str
    username: str | None
    aire_hostname: str | None
    use_jump_host: bool
    jump_hostname: str | None
    control_path: str | None
    jump_control_path: str | None
    timeout: int


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
    path: str
    filesystem: str
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


@dataclass(frozen=True)
class ClusterSnapshot:
    collected_at: str
    remote: RemoteInfo
    jobs: list[Job]
    partitions: list[PartitionSummary]
    nodes: list[NodeSummary]
    storage: list[StorageSummary]
    errors: list[str]
    # Non-fatal issues (enrichment sections that failed); consumers must
    # never treat these as a failed refresh. Swift's Codable ignores the
    # extra key, so older app builds are unaffected.
    warnings: list[str] = field(default_factory=list)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Collect a read-only JSON monitoring snapshot from AIRE."
    )
    parser.add_argument(
        "--host",
        default=DEFAULT_HOST,
        help="SSH host alias to use when --username is not supplied. Defaults to 'aire'.",
    )
    parser.add_argument(
        "--username",
        help="Remote username. When supplied, the script uses --aire-hostname and --jump-hostname instead of the SSH alias.",
    )
    parser.add_argument(
        "--aire-hostname",
        default="aire.leeds.ac.uk",
        help="AIRE login hostname used with --username. Defaults to aire.leeds.ac.uk.",
    )
    parser.add_argument(
        "--jump-hostname",
        default="rash.leeds.ac.uk",
        help="Jump host used with --username and --use-jump-host. Defaults to rash.leeds.ac.uk.",
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
        help="Connect directly to the AIRE host in explicit username mode.",
    )
    parser.add_argument(
        "--control-path",
        help="OpenSSH ControlPath for a persistent local master connection. Example: .runtime/ssh-control/%%C",
    )
    parser.add_argument(
        "--jump-control-path",
        help="OpenSSH ControlPath for a persistent jump-host master connection.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=20,
        help="Timeout in seconds for the SSH connection. Defaults to 20.",
    )
    parser.add_argument(
        "--pretty",
        action="store_true",
        help="Pretty-print JSON output.",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run the embedded parser self-tests and exit (no SSH).",
    )
    return parser.parse_args()


def build_ssh_command(config: SSHConfig, remote_command: str) -> tuple[list[str] | None, str | None]:
    command = [
        "ssh",
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
        f"ConnectTimeout={min(config.timeout, 20)}",
        "-o",
        "ServerAliveInterval=30",
        "-o",
        "ServerAliveCountMax=10",
        "-o",
        "TCPKeepAlive=yes",
        "-o",
        "ExitOnForwardFailure=yes",
    ]
    if config.control_path:
        command.extend(
            [
                "-o",
                "ControlMaster=auto",
                "-o",
                f"ControlPath={config.control_path}",
            ]
        )

    if config.username:
        if not config.aire_hostname:
            return None, "--username requires --aire-hostname"
        command.extend(["-o", f"User={config.username}"])
        if config.use_jump_host:
            if not config.jump_hostname:
                return None, "--use-jump-host requires --jump-hostname"
            if not config.control_path:
                return None, "--use-jump-host requires --control-path so refreshes can reuse the authenticated AIRE master"
            if not config.jump_control_path:
                return None, "--use-jump-host requires --jump-control-path so refreshes can reuse the authenticated jump host"
            jump_proxy = [
                "ssh",
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
                f"ConnectTimeout={min(config.timeout, 20)}",
                "-o",
                "ServerAliveInterval=30",
                "-o",
                "ServerAliveCountMax=10",
                "-o",
                "TCPKeepAlive=yes",
                "-o",
                "ControlMaster=auto",
                "-o",
                f"ControlPath={config.jump_control_path}",
                "-o",
                f"User={config.username}",
                "-W",
                "%h:%p",
                config.jump_hostname,
            ]
            command.extend(["-o", f"ProxyCommand={shlex.join(jump_proxy)}"])
        else:
            command.extend(["-o", "ProxyCommand=none", "-o", "ProxyJump=none"])
        command.extend([config.aire_hostname, remote_command])
    else:
        command.extend([config.host, remote_command])
    return command, None


def run_ssh(
    config: SSHConfig,
    remote_command: str,
    run_timeout: int | None = None,
) -> tuple[str, str | None]:
    command, error = build_ssh_command(config, remote_command)
    if command is None:
        return "", error

    effective_timeout = run_timeout if run_timeout is not None else config.timeout
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=effective_timeout,
        )
    except subprocess.TimeoutExpired:
        return "", f"Timed out after {effective_timeout}s: snapshot collection"

    stdout = completed.stdout.strip()
    stderr = completed.stderr.strip()
    if completed.returncode != 0:
        message = f"Command failed with exit {completed.returncode}: snapshot collection"
        if stderr:
            message = f"{message}; stderr={stderr}"
        return stdout, message

    return stdout, None


def probe_master(config: SSHConfig) -> str | None:
    """Return a 'connection lost' error when the control master is definitely dead.

    Returns None when the master is alive or its state cannot be determined
    (e.g. alias mode without an explicit --control-path).
    """
    if not config.control_path:
        return None
    target = config.aire_hostname if config.username else config.host
    command = [
        "ssh",
        "-o",
        f"ControlPath={config.control_path}",
        "-O",
        "check",
        target,
    ]
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
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


def parse_size_to_gb(value: str) -> float | None:
    value, _ = strip_quota_markers(value)
    if not value or value in {"N/A", "n/a", "(null)", "-"}:
        return None
    number = value
    suffix = ""
    if value[-1].isalpha():
        number = value[:-1]
        suffix = value[-1].lower()
    try:
        amount = float(number)
    except ValueError:
        return None
    if suffix == "k":
        return amount / 1024 / 1024
    if suffix == "m":
        return amount / 1024
    if suffix == "g" or not suffix:
        return amount
    if suffix == "t":
        return amount * 1024
    if suffix == "p":
        return amount * 1024 * 1024
    return amount


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

    Handles typed gres and socket/index suffixes, e.g. 'gpu:l40s:3(S:0-1)',
    'gpu:4(IDX:0-3)', and comma-joined lists like 'gpu:a100:4,mps:400'.
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
    partitions: list[PartitionSummary] = []
    for line in nonempty_lines(output):
        fields = split_fields(line, 8)
        if not fields:
            continue
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


def parse_storage(output: str) -> list[StorageSummary]:
    sections: dict[str, list[str]] = {}
    current = ""
    for line in output.splitlines():
        if line.startswith("__") and line.endswith("__"):
            current = line.strip("_").lower()
            sections[current] = []
        elif current:
            sections[current].append(line)

    home_path = first_nonempty(sections.get("home_path", [])) or "/users/$USER"
    home_df = parse_df_block(sections.get("home_df", []))
    scratch_df = parse_df_block(sections.get("scratch_df", []))
    home_quota = parse_home_quota(sections.get("home_quota", []))
    scratch_quota = parse_lfs_quota(sections.get("scratch_quota", []))

    home_limit = home_quota.get("limit_gb") or home_quota.get("quota_gb")
    home_used = home_quota.get("used_gb") or home_df.get("used_gb")
    home_available = None
    if home_limit is not None and home_used is not None:
        home_available = max(home_limit - home_used, 0)
    elif home_df.get("available_gb") is not None:
        home_available = home_df.get("available_gb")

    scratch_limit = scratch_quota.get("limit_gb") or scratch_quota.get("quota_gb")
    scratch_used = scratch_quota.get("used_gb") or scratch_df.get("used_gb")
    scratch_available = None
    if scratch_limit is not None and scratch_used is not None:
        scratch_available = max(scratch_limit - scratch_used, 0)
    elif scratch_df.get("available_gb") is not None:
        scratch_available = scratch_df.get("available_gb")

    return [
        StorageSummary(
            label="Home",
            path=home_path,
            filesystem=home_df.get("filesystem_text") or home_quota.get("filesystem_text") or "",
            source="quota",
            used_gb=home_used,
            quota_gb=home_quota.get("quota_gb"),
            limit_gb=home_limit,
            available_gb=home_available,
            used_percent=storage_percent(home_used, home_limit, home_df.get("used_percent")),
            file_count=home_quota.get("file_count_int"),
            file_quota=home_quota.get("file_quota_int"),
            file_limit=home_quota.get("file_limit_int"),
            over_quota=bool(home_quota.get("over_quota", False)),
        ),
        StorageSummary(
            label="Scratch",
            path="/mnt/scratch",
            filesystem=scratch_df.get("filesystem_text") or "/mnt/scratch",
            source="lfs quota",
            used_gb=scratch_used,
            quota_gb=scratch_quota.get("quota_gb"),
            limit_gb=scratch_limit,
            available_gb=scratch_available,
            used_percent=storage_percent(scratch_used, scratch_limit, scratch_df.get("used_percent")),
            file_count=scratch_quota.get("file_count_int"),
            file_quota=scratch_quota.get("file_quota_int"),
            file_limit=scratch_quota.get("file_limit_int"),
            over_quota=bool(scratch_quota.get("over_quota", False)),
        ),
    ]


def first_nonempty(lines: list[str]) -> str | None:
    for line in lines:
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
        break
    return result


def parse_home_quota(lines: list[str] | None) -> dict[str, object]:
    """Parse `quota -s` output for the home filesystem.

    Handles both layouts: the wrapped form (device on its own line, values on
    the next) and the single-line form (device and values on one line).
    """
    result: dict[str, object] = {}
    if not lines:
        return result
    for index, line in enumerate(lines):
        if "/export/users" not in line:
            continue
        fields = line.split()
        result["filesystem_text"] = fields[0] if fields else line.strip()
        value_fields = fields[1:]
        if len(value_fields) < 6:
            next_line = lines[index + 1] if index + 1 < len(lines) else ""
            value_fields = next_line.split()
        if len(value_fields) >= 6:
            result["used_gb"] = parse_size_to_gb(value_fields[0])
            result["quota_gb"] = parse_size_to_gb(value_fields[1])
            result["limit_gb"] = parse_size_to_gb(value_fields[2])
            file_offset = 4 if len(value_fields) >= 7 else 3
            result["file_count_int"] = parse_count(value_fields[file_offset])
            result["file_quota_int"] = parse_count(value_fields[file_offset + 1])
            result["file_limit_int"] = parse_count(value_fields[file_offset + 2])
            result["over_quota"] = any(
                strip_quota_markers(field)[1] for field in value_fields[:file_offset + 3]
            )
        break
    return result


def parse_lfs_quota(lines: list[str] | None) -> dict[str, object]:
    """Parse `lfs quota -h` output for /mnt/scratch.

    Handles both the single-line layout and the wrapped layout where the
    filesystem sits on its own line with values on the next.
    """
    result: dict[str, object] = {}
    if not lines:
        return result
    for index, line in enumerate(lines):
        fields = line.split()
        if not fields or fields[0] != "/mnt/scratch":
            continue
        values = fields[1:]
        if len(values) < 7:
            values = lines[index + 1].split() if index + 1 < len(lines) else []
        if len(values) >= 7:
            result["used_gb"] = parse_size_to_gb(values[0])
            result["quota_gb"] = parse_size_to_gb(values[1])
            result["limit_gb"] = parse_size_to_gb(values[2])
            result["file_count_int"] = parse_count(values[4])
            result["file_quota_int"] = parse_count(values[5])
            result["file_limit_int"] = parse_count(values[6])
            result["over_quota"] = any(
                strip_quota_markers(value)[1] for value in values[:7]
            )
        break
    return result


def parse_count(value: str) -> int | None:
    value, _ = strip_quota_markers(value)
    if not value or value in {"-", "0"}:
        return None if value == "-" else 0
    suffix = value[-1].lower()
    multiplier = 1
    number = value
    if suffix == "k":
        multiplier = 1_000
        number = value[:-1]
    elif suffix == "m":
        multiplier = 1_000_000
        number = value[:-1]
    try:
        return int(float(number) * multiplier)
    except ValueError:
        return None


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
# failures.
REMOTE_SNAPSHOT_SCRIPT = r"""
section() { printf '\n=====AIRE-SECTION:%s=====\n' "$1"; }
finish() { printf '\n=====AIRE-STATUS:%s:%s=====\n' "$1" "$2"; }

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
sinfo -h -o '%P|%a|%D|%t|%G|%c|%m|%f'
finish partitions $?

section nodes
sinfo -N -h -o '%N|%P|%t|%C|%m|%G|%f|%E'
finish nodes $?

section node_details
scontrol show node -o
finish node_details $?

section storage
printf '__HOME_PATH__\n%s\n' "$HOME"
printf '__HOME_DF__\n'; df -Pk "$HOME" 2>/dev/null || true
printf '__HOME_QUOTA__\n'; quota -s 2>/dev/null || true
printf '__SCRATCH_DF__\n'; df -Pk /mnt/scratch 2>/dev/null || true
printf '__SCRATCH_QUOTA__\n'
if command -v lfs >/dev/null 2>&1; then lfs quota -h -u "$USER" /mnt/scratch 2>/dev/null || true; fi
finish storage 0
"""

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


def empty_remote_info(config: SSHConfig) -> RemoteInfo:
    host = config.host if not config.username else (config.aire_hostname or config.host)
    return RemoteInfo(host=host, hostname="", user="", cwd="", remote_time="")


def collect_snapshot(config: SSHConfig) -> ClusterSnapshot:
    errors: list[str] = []
    warnings: list[str] = []
    collected_at = datetime.now(timezone.utc).isoformat()

    probe_error = probe_master(config)
    if probe_error:
        return ClusterSnapshot(
            collected_at=collected_at,
            remote=empty_remote_info(config),
            jobs=[],
            partitions=[],
            nodes=[],
            storage=[],
            errors=[probe_error],
        )

    batch_timeout = config.timeout * 2 + 10
    output, error = run_ssh(config, REMOTE_SNAPSHOT_SCRIPT, run_timeout=batch_timeout)
    sections, statuses = split_sections(output)
    if error:
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

    return ClusterSnapshot(
        collected_at=collected_at,
        remote=parse_remote_info(
            config.host if not config.username else (config.aire_hostname or config.host),
            sections.get("remote", ""),
        ),
        jobs=jobs,
        partitions=parse_partitions(sections.get("partitions", "")),
        nodes=parse_nodes(sections.get("nodes", ""), sections.get("node_details", "")),
        storage=parse_storage(sections.get("storage", "")),
        errors=errors,
        warnings=warnings,
    )


# ---------------------------------------------------------------------------
# Self-tests
# ---------------------------------------------------------------------------


def run_self_test() -> int:
    failures: list[str] = []

    def check(name: str, condition: bool, detail: object = "") -> None:
        if not condition:
            failures.append(f"{name}: {detail}")

    # --- gres GPU totals (socket/index suffixes, typed gres, lists) ---
    check("gres l40s", parse_gres_gpu_total("gpu:l40s:3(S:0-1)") == 3,
          parse_gres_gpu_total("gpu:l40s:3(S:0-1)"))
    check("gres idx", parse_gres_gpu_total("gpu:4(IDX:0-3)") == 4,
          parse_gres_gpu_total("gpu:4(IDX:0-3)"))
    check("gres list", parse_gres_gpu_total("gpu:a100:4,mps:400") == 4,
          parse_gres_gpu_total("gpu:a100:4,mps:400"))
    check("gres null", parse_gres_gpu_total("(null)") is None,
          parse_gres_gpu_total("(null)"))
    check("gres bare", parse_gres_gpu_total("gpu") == 1, parse_gres_gpu_total("gpu"))

    # --- over-quota markers ---
    check("size star", parse_size_to_gb("12.5G*") == 12.5, parse_size_to_gb("12.5G*"))
    check("size plus", parse_size_to_gb("12.5G+") == 12.5, parse_size_to_gb("12.5G+"))
    check("size tb", parse_size_to_gb("1T") == 1024, parse_size_to_gb("1T"))
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

    # --- lfs quota with over-quota marker ---
    lfs = [
        "Disk quotas for usr u (uid 12345):",
        "     Filesystem  used   quota   limit   grace   files   quota   limit   grace",
        "   /mnt/scratch  500G*     1T    1.5T       -  100000  200000  300000       -",
    ]
    lq = parse_lfs_quota(lfs)
    check("lfs used", lq.get("used_gb") == 500, lq)
    check("lfs files", lq.get("file_count_int") == 100_000, lq)
    check("lfs over", lq.get("over_quota") is True, lq)

    # --- section splitting ---
    sample = (
        "\n=====AIRE-SECTION:remote=====\n"
        "host|user|/home/u|2026-07-19T10:00:00\n"
        "\n=====AIRE-STATUS:remote:0=====\n"
        "\n=====AIRE-SECTION:jobs=====\n"
        "\n=====AIRE-STATUS:jobs:1=====\n"
    )
    sections, statuses = split_sections(sample)
    check("sections remote", sections.get("remote") == "host|user|/home/u|2026-07-19T10:00:00",
          sections)
    check("statuses", statuses == {"remote": 0, "jobs": 1}, statuses)

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

    # --- duration formatting ---
    check("duration days", format_duration(90061) == "1-01:01:01", format_duration(90061))
    check("duration min", format_duration(125) == "2:05", format_duration(125))

    if failures:
        for failure in failures:
            print(f"SELF-TEST FAIL {failure}", file=sys.stderr)
        print(f"{len(failures)} self-test failure(s)", file=sys.stderr)
        return 1
    print("All self-tests passed")
    return 0


def main() -> int:
    args = parse_args()
    if args.self_test:
        return run_self_test()
    snapshot = collect_snapshot(
        SSHConfig(
            host=args.host,
            username=args.username,
            aire_hostname=args.aire_hostname,
            use_jump_host=args.use_jump_host and not args.no_jump_host,
            jump_hostname=args.jump_hostname,
            control_path=args.control_path,
            jump_control_path=args.jump_control_path,
            timeout=args.timeout,
        )
    )
    indent = 2 if args.pretty else None
    print(json.dumps(asdict(snapshot), indent=indent, ensure_ascii=False))
    return 1 if snapshot.errors else 0


if __name__ == "__main__":
    sys.exit(main())
