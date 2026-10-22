from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import hpc_snapshot as collector

from . import platform_support


@dataclass(frozen=True)
class Profile:
    id: str
    name: str
    host: str
    # The Trends legend names each cluster's line by colour ("AIRE = green").
    # There is deliberately no GPU model here: headings come from the GPU
    # pools a snapshot reports (rules.GPUFleet), because one scheduler can
    # host several models (Calder also runs AIRE's L40 node).
    color_name: str
    color: str
    storage_spec: str

    @property
    def volumes(self) -> list[collector.StorageVolume]:
        volumes, error = collector.parse_storage_spec(self.storage_spec)
        if error:
            raise ValueError(error)
        return volumes


PROFILES = (
    Profile("aire", "AIRE", "aire.leeds.ac.uk", "green", "#36c99c", collector.AIRE_SPEC),
    Profile("calder", "Calder", "calder.leeds.ac.uk", "violet", "#aa94f6", collector.CALDER_SPEC),
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
    # storage is None when it was not collected this time (skipped between
    # storage refreshes, an earlier df/quota/lfs still stuck, or a round trip
    # that ended before the section); [] is "collected, no volumes". None is
    # kept as it is: rules.StorageTracker.receive then keeps the previous rows,
    # instead of an empty list wiping them on screen and in the cache.
    storage_rows = data.get("storage")
    if storage_rows is not None and not isinstance(storage_rows, list):
        raise ValueError("Invalid snapshot field: storage")
    # Set by rules.StorageTracker.receive when the rows are older than the snapshot.
    stamp = data.get("storage_collected_at")
    if stamp is not None:
        if not isinstance(stamp, str):
            raise ValueError("Invalid storage timestamp.")
        datetime.fromisoformat(stamp)
    for key in ("jobs", "nodes", "partitions", "errors", "warnings"):
        if not isinstance(data.get(key), list):
            raise ValueError(f"Invalid snapshot field: {key}")
    sections = {key: data[key] for key in ("jobs", "nodes", "partitions")}
    sections["storage"] = storage_rows or []
    for key, rows in sections.items():
        if not all(isinstance(row, dict) for row in rows):
            raise ValueError(f"Invalid snapshot rows: {key}")
    for key in ("errors", "warnings"):
        if not all(isinstance(row, str) for row in data[key]):
            raise ValueError(f"Invalid snapshot messages: {key}")
    for row in data["jobs"]:
        if not isinstance(row.get("job_id"), str) or not isinstance(row.get("state"), str):
            raise ValueError("Invalid job row")
        if row.get("array_pending_tasks") is not None and not isinstance(row["array_pending_tasks"], str):
            raise ValueError("Invalid job row")
    for row in sections["storage"]:
        if not isinstance(row.get("label"), str) or not isinstance(row.get("source"), str):
            raise ValueError("Invalid storage row")
    numeric_fields = {
        "jobs": ("array_job_id", "pending_task_count"),
        "nodes": (
            "gpu_total",
            "gpu_idle",
            "gpu_allocated",
            "cpu_total",
            "cpu_idle",
            "cpu_allocated",
            "cpu_other",
            "memory_mb",
        ),
        "storage": (
            "used_gb",
            "quota_gb",
            "limit_gb",
            "available_gb",
            "used_percent",
            "file_count",
            "file_quota",
            "file_limit",
        ),
    }
    for section, keys in numeric_fields.items():
        for row in sections[section]:
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


# File names inside the data folder. Existing installs already have files
# with these names, so they are part of the on-disk format.
SETTINGS_FILE = "settings.json"
KNOWN_HOSTS_FILE = "known_hosts"


class LocalStore:
    def __init__(self, root: Path | None = None):
        self.root = root or platform_support.data_dir()
        platform_support.make_private_dir(self.root)

    def read(self, name: str, default: Any = None) -> Any:
        try:
            return json.loads((self.root / name).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return default

    def write(self, name: str, value: Any) -> None:
        target = self.root / name
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
        # Before the rename, so the final name never exists with looser modes.
        platform_support.make_private_file(temporary)
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
