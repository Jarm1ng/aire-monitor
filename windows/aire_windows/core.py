from __future__ import annotations

import json
import math
import os
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import hpc_snapshot as collector


@dataclass(frozen=True)
class Profile:
    id: str
    name: str
    host: str
    gpu: str
    color: str
    storage_spec: str

    @property
    def volumes(self) -> list[collector.StorageVolume]:
        volumes, error = collector.parse_storage_spec(self.storage_spec)
        if error:
            raise ValueError(error)
        return volumes


PROFILES = (
    Profile("aire", "AIRE", "aire.leeds.ac.uk", "L40S", "#36c99c", collector.AIRE_SPEC),
    Profile("calder", "Calder", "calder.leeds.ac.uk", "H200", "#aa94f6", collector.CALDER_SPEC),
)
USERNAME = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$")


def validate_username(value: str) -> str:
    value = value.strip()
    if not USERNAME.fullmatch(value):
        raise ValueError("Enter your university username, not an email address.")
    return value


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def validate_snapshot(data: Any, cluster_id: str, username: str) -> dict:
    if (
        not isinstance(data, dict)
        or not isinstance(data.get("cluster"), dict)
        or data["cluster"].get("id") != cluster_id
    ):
        raise ValueError("Snapshot belongs to a different cluster.")
    if not isinstance(data.get("remote"), dict) or data["remote"].get("user") != username:
        raise ValueError("Snapshot belongs to a different account.")
    if not isinstance(data.get("collected_at"), str):
        raise ValueError("Invalid snapshot timestamp.")
    datetime.fromisoformat(data["collected_at"])
    for key in ("jobs", "nodes", "partitions", "storage", "errors", "warnings"):
        if not isinstance(data.get(key), list):
            raise ValueError(f"Invalid snapshot field: {key}")
    for key in ("jobs", "nodes", "partitions", "storage"):
        if not all(isinstance(row, dict) for row in data[key]):
            raise ValueError(f"Invalid snapshot rows: {key}")
    for key in ("errors", "warnings"):
        if not all(isinstance(row, str) for row in data[key]):
            raise ValueError(f"Invalid snapshot messages: {key}")
    for row in data["jobs"]:
        if not isinstance(row.get("job_id"), str) or not isinstance(row.get("state"), str):
            raise ValueError("Invalid job row")
    for row in data["storage"]:
        if not isinstance(row.get("label"), str) or not isinstance(row.get("source"), str):
            raise ValueError("Invalid storage row")
    numeric_fields = {
        "nodes": (
            "gpu_total",
            "gpu_idle",
            "gpu_allocated",
            "cpu_total",
            "cpu_idle",
            "cpu_allocated",
            "memory_mb",
        ),
        "storage": ("used_gb", "quota_gb", "limit_gb", "used_percent", "file_count", "file_quota"),
    }
    for section, keys in numeric_fields.items():
        for row in data[section]:
            for key in keys:
                value = row.get(key)
                if value is not None and (
                    type(value) not in (int, float) or not math.isfinite(value) or value < 0
                ):
                    raise ValueError(f"Invalid numeric field: {section}.{key}")
    for row in data["nodes"]:
        if not isinstance(row.get("state", ""), str):
            raise ValueError("Invalid node state")
    return data


def clean_history(history: Any) -> list:
    if not isinstance(history, list):
        return []
    clean = []
    for row in history[-8640:]:
        if not isinstance(row, dict):
            continue
        try:
            datetime.fromisoformat(row["time"]).timestamp()
            if all(
                value is None or isinstance(value, (int, float)) and math.isfinite(value)
                for key, value in row.items()
                if key != "time"
            ):
                clean.append(row)
        except (KeyError, TypeError, ValueError, OverflowError, OSError):
            pass
    return clean


def metrics(snapshot: dict) -> dict:
    nodes = snapshot.get("nodes", [])
    usable = [
        n
        for n in nodes
        if not any(
            state in n.get("state", "").lower()
            for state in ("down", "drain", "fail", "maint", "unknown", "not_resp", "no_resp")
        )
        and not any(mark in n.get("state", "") for mark in ("*", "~", "#", "!", "%"))
    ]
    # Unknown allocation must never be advertised as free capacity.
    gpu = [n.get("gpu_idle") for n in usable if n.get("gpu_total")]
    cpu = [n.get("cpu_idle") for n in usable]
    return {
        "running": sum(j.get("state") == "RUNNING" for j in snapshot.get("jobs", [])),
        "pending": sum(j.get("state") == "PENDING" for j in snapshot.get("jobs", [])),
        "gpu_idle": sum(gpu) if gpu and all(v is not None for v in gpu) else None,
        "cpu_idle": sum(cpu) if cpu and all(v is not None for v in cpu) else None,
        "unavailable": len(nodes) - len(usable),
    }


class LocalStore:
    def __init__(self, root: Path | None = None):
        self.root = root or Path(os.environ.get("LOCALAPPDATA", Path.home())) / "LeedsHPCMonitor"
        self.root.mkdir(parents=True, exist_ok=True)

    def read(self, name: str, default: Any = None) -> Any:
        try:
            return json.loads((self.root / name).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return default

    def write(self, name: str, value: Any) -> None:
        target = self.root / name
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
        temporary.replace(target)

    def cache_name(self, username: str, cluster_id: str) -> str:
        validate_username(username)
        if cluster_id not in {p.id for p in PROFILES}:
            raise ValueError("Unknown cluster")
        return f"{username}-{cluster_id}.json"

    def load(self, username: str, cluster_id: str) -> tuple[dict | None, list]:
        try:
            saved = self.read(self.cache_name(username, cluster_id), {})
            snapshot = validate_snapshot(saved["snapshot"], cluster_id, username)
            return snapshot, clean_history(saved.get("history", []))
        except (KeyError, TypeError, ValueError, AttributeError):
            return None, []

    def save(self, username: str, cluster_id: str, snapshot: dict, history: list) -> None:
        validate_snapshot(snapshot, cluster_id, username)
        self.write(
            self.cache_name(username, cluster_id),
            {
                "snapshot": snapshot,
                "history": history[-8640:],
            },
        )
