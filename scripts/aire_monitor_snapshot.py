#!/usr/bin/env python3
"""Collect a read-only Slurm snapshot from AIRE over SSH.

This script is intentionally local-only: it does not install anything on the
server, write remote files, submit jobs, or cancel jobs. It only runs read-only
Slurm commands through the existing SSH host alias.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from typing import Iterable


DEFAULT_HOST = "aire"
FIELD_SEPARATOR = "|"


@dataclass(frozen=True)
class SSHConfig:
    host: str
    username: str | None
    aire_hostname: str | None
    jump_hostname: str | None
    control_path: str | None
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


@dataclass(frozen=True)
class ClusterSnapshot:
    collected_at: str
    remote: RemoteInfo
    jobs: list[Job]
    partitions: list[PartitionSummary]
    nodes: list[NodeSummary]
    storage: list[StorageSummary]
    errors: list[str]


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
        help="Jump host used with --username. Defaults to rash.leeds.ac.uk.",
    )
    parser.add_argument(
        "--control-path",
        help="OpenSSH ControlPath for a persistent local master connection. Example: .runtime/ssh-control/%%C",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=20,
        help="Timeout in seconds for each SSH command. Defaults to 20.",
    )
    parser.add_argument(
        "--pretty",
        action="store_true",
        help="Pretty-print JSON output.",
    )
    return parser.parse_args()


def run_ssh(config: SSHConfig, remote_command: str) -> tuple[str, str | None]:
    command = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        f"ConnectTimeout={min(config.timeout, 20)}",
        "-o",
        "ServerAliveInterval=30",
        "-o",
        "ServerAliveCountMax=6",
    ]
    if config.control_path:
        command.extend(
            [
                "-o",
                "ControlMaster=auto",
                "-o",
                "ControlPersist=2h",
                "-o",
                f"ControlPath={config.control_path}",
            ]
        )

    if config.username:
        if not config.aire_hostname or not config.jump_hostname:
            return "", "--username requires --aire-hostname and --jump-hostname"
        command.extend(
            [
                "-o",
                f"User={config.username}",
                "-o",
                f"ProxyJump={config.username}@{config.jump_hostname}",
                config.aire_hostname,
                remote_command,
            ]
        )
    else:
        command.extend([config.host, remote_command])

    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=config.timeout,
        )
    except subprocess.TimeoutExpired:
        return "", f"Timed out after {config.timeout}s: {remote_command}"

    stdout = completed.stdout.strip()
    stderr = completed.stderr.strip()
    if completed.returncode != 0:
        message = f"Command failed with exit {completed.returncode}: {remote_command}"
        if stderr:
            message = f"{message}; stderr={stderr}"
        return stdout, message

    return stdout, None


def split_fields(line: str, expected: int) -> list[str] | None:
    fields = [part.strip() for part in line.split(FIELD_SEPARATOR)]
    if len(fields) != expected:
        return None
    return fields


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


def parse_size_to_gb(value: str) -> float | None:
    value = value.strip()
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


def parse_key_values(line: str) -> dict[str, str]:
    result: dict[str, str] = {}
    current_key: str | None = None
    current_value: list[str] = []
    for token in line.split():
        if "=" in token:
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
        fields = split_fields(line, 9)
        if not fields:
            continue
        details = details_by_job.get(fields[0], {})
        jobs.append(
            Job(
                job_id=fields[0],
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
    details: dict[str, dict[str, str]] = {}
    for line in nonempty_lines(output):
        values = parse_key_values(line)
        raw_job_id = values.get("JobId")
        if not raw_job_id:
            continue
        job_id = raw_job_id.split("_", 1)[0].split(".", 1)[0]
        details[job_id] = values
    return details


def clean_optional(value: str | None) -> str | None:
    if value is None:
        return None
    value = value.strip()
    if not value or value in {"N/A", "n/a", "(null)", "Unknown"}:
        return None
    return value


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
    result: dict[str, object] = {}
    if not lines:
        return result
    for index, line in enumerate(lines):
        if "/export/users" not in line:
            continue
        result["filesystem_text"] = line.strip()
        quota_line = lines[index + 1] if index + 1 < len(lines) else ""
        fields = quota_line.split()
        if len(fields) >= 6:
            result["used_gb"] = parse_size_to_gb(fields[0])
            result["quota_gb"] = parse_size_to_gb(fields[1])
            result["limit_gb"] = parse_size_to_gb(fields[2])
            file_offset = 4 if len(fields) >= 7 else 3
            result["file_count_int"] = parse_count(fields[file_offset])
            result["file_quota_int"] = parse_count(fields[file_offset + 1])
            result["file_limit_int"] = parse_count(fields[file_offset + 2])
        break
    return result


def parse_lfs_quota(lines: list[str] | None) -> dict[str, object]:
    result: dict[str, object] = {}
    if not lines:
        return result
    for line in lines:
        fields = line.split()
        if len(fields) < 8 or fields[0] != "/mnt/scratch":
            continue
        result["used_gb"] = parse_size_to_gb(fields[1])
        result["quota_gb"] = parse_size_to_gb(fields[2])
        result["limit_gb"] = parse_size_to_gb(fields[3])
        result["file_count_int"] = parse_count(fields[5])
        result["file_quota_int"] = parse_count(fields[6])
        result["file_limit_int"] = parse_count(fields[7])
        break
    return result


def parse_count(value: str) -> int | None:
    value = value.strip()
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


def collect_snapshot(config: SSHConfig) -> ClusterSnapshot:
    errors: list[str] = []

    commands = {
        "remote": (
            "printf '%s|%s|%s|%s\\n' "
            "\"$(hostname -f 2>/dev/null || hostname)\" "
            "\"$(whoami)\" "
            "\"$PWD\" "
            "\"$(date -Iseconds 2>/dev/null || date)\""
        ),
        "jobs": 'squeue -u "$USER" -h -o "%i|%P|%j|%u|%T|%M|%l|%D|%R"',
        "job_details": (
            'job_ids=$(squeue -u "$USER" -h -o "%i" | tr "\\n" " "); '
            'if [ -n "$job_ids" ]; then scontrol show job -o $job_ids; fi'
        ),
        "partitions": 'sinfo -h -o "%P|%a|%D|%t|%G|%c|%m|%f"',
        "nodes": 'sinfo -N -h -o "%N|%P|%t|%C|%m|%G|%f|%E"',
        "node_details": "scontrol show node -o",
        "storage": (
            'printf "__HOME_PATH__\\n%s\\n" "$HOME"; '
            'printf "__HOME_DF__\\n"; df -Pk "$HOME" 2>/dev/null || true; '
            'printf "__HOME_QUOTA__\\n"; quota -s 2>/dev/null || true; '
            'printf "__SCRATCH_DF__\\n"; df -Pk /mnt/scratch 2>/dev/null || true; '
            'printf "__SCRATCH_QUOTA__\\n"; '
            'if command -v lfs >/dev/null 2>&1; then lfs quota -h -u "$USER" /mnt/scratch 2>/dev/null || true; fi'
        ),
    }

    outputs: dict[str, str] = {}
    for key, command in commands.items():
        output, error = run_ssh(config, command)
        outputs[key] = output
        if error:
            errors.append(error)

    return ClusterSnapshot(
        collected_at=datetime.now(timezone.utc).isoformat(),
        remote=parse_remote_info(config.host, outputs.get("remote", "")),
        jobs=parse_jobs(outputs.get("jobs", ""), outputs.get("job_details", "")),
        partitions=parse_partitions(outputs.get("partitions", "")),
        nodes=parse_nodes(outputs.get("nodes", ""), outputs.get("node_details", "")),
        storage=parse_storage(outputs.get("storage", "")),
        errors=errors,
    )


def main() -> int:
    args = parse_args()
    snapshot = collect_snapshot(
        SSHConfig(
            host=args.host,
            username=args.username,
            aire_hostname=args.aire_hostname,
            jump_hostname=args.jump_hostname,
            control_path=args.control_path,
            timeout=args.timeout,
        )
    )
    indent = 2 if args.pretty else None
    print(json.dumps(asdict(snapshot), indent=indent, ensure_ascii=False))
    return 1 if snapshot.errors else 0


if __name__ == "__main__":
    sys.exit(main())
