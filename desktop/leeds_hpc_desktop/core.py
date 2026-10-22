from __future__ import annotations

import json
import math
import re
import threading
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


def _profile(cluster_id: str, color_name: str, color: str, storage_spec: str) -> Profile:
    # The name and login host come from the collector's cluster table and the
    # storage spec from its AIRE_SPEC/CALDER_SPEC. CollectorContractTests
    # (Swift) checks both against the macOS app's catalogue and
    # ClusterProfile.swift, so the three apps cannot drift apart; only the
    # colours are this app's own.
    return Profile(
        cluster_id,
        collector.KNOWN_CLUSTER_NAMES[cluster_id],
        collector.KNOWN_CLUSTER_HOSTNAMES[cluster_id],
        color_name,
        color,
        storage_spec,
    )


PROFILES = (
    _profile("aire", "green", "#36c99c", collector.AIRE_SPEC),
    _profile("calder", "violet", "#aa94f6", collector.CALDER_SPEC),
)
USERNAME = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$")


def validate_username(value: str) -> str:
    """The username in its canonical, lower-case spelling.

    Leeds usernames are lower case, and the clusters' SSSD/AD lookup is
    case-insensitive, so "AB12CDE" signs in as "ab12cde" and the collector's
    whoami reports "ab12cde". Lower-casing here keeps one spelling for the
    sign-in, the saved password, the cache file and the snapshot check (a
    Windows file system would otherwise treat two spellings as one file).
    """
    value = value.strip()
    if not USERNAME.fullmatch(value):
        raise ValueError("Enter your university username, not an email address.")
    return value.lower()


def same_account(reported: Any, username: str) -> bool:
    """Whether the account a cluster reports is username, ignoring case (see
    validate_username)."""
    return isinstance(reported, str) and reported.casefold() == username.casefold()


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def validate_snapshot(data: Any, cluster_id: str, username: str) -> dict:
    if (
        not isinstance(data, dict)
        or not isinstance(data.get("cluster"), dict)
        or data["cluster"].get("id") != cluster_id
    ):
        raise ValueError("Snapshot belongs to a different cluster.")
    if not isinstance(data.get("remote"), dict) or not same_account(data["remote"].get("user"), username):
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
# settings.json key: the accounts whose saved password a server rejected
# (login.SavedPasswordGuard). Usernames only, never a password.
REJECTED_SAVED_PASSWORDS = "saved_password_rejected"
# settings.json key, present only after a settings file whose flags could not
# be read (cut short by a power cut, edited by hand) was replaced. Which
# accounts were flagged is then unknown, so every account counts as rejected
# except the ones listed here: those whose typed password a server has
# accepted since (SavedPasswordGuard.verified lifts them one at a time).
REJECTED_UNKNOWN_EXCEPT = "saved_password_rejected_unknown_except"


class LocalStore:
    def __init__(self, root: Path | None = None):
        self.root = root or platform_support.data_dir()
        platform_support.make_private_dir(self.root)
        # settings.json is changed from the UI thread (username, route) and
        # from the sign-in worker (the rejected flags): one read-modify-write
        # at a time, so neither loses the other's change.
        self._settings_lock = threading.Lock()

    def update_settings(self, **changes: Any) -> None:
        """Merge changes into settings.json, keeping every other key."""
        with self._settings_lock:
            settings = self._settings_to_update()
            settings.update(changes)
            self.write(SETTINGS_FILE, settings)

    def _settings_to_update(self) -> dict:
        """settings.json for a read-modify-write (call with _settings_lock).

        A file that exists but cannot be read, or whose rejected flags are
        unreadable, must not be replaced by one without them: that would
        quietly lift the fail-closed answer saved_password_rejected gives
        for it, and the next empty-field Connect would resend a saved
        password a server may already have refused (another lockout
        attempt). So its flags become "unknown": every account stays
        rejected until a typed password is accepted (REJECTED_UNKNOWN_EXCEPT).
        """
        try:
            text = (self.root / SETTINGS_FILE).read_text(encoding="utf-8")
        except FileNotFoundError:
            return {}
        except OSError:
            text = None
        settings = None
        if text is not None:
            try:
                settings = json.loads(text)
            except ValueError:
                pass
        if not isinstance(settings, dict):
            return {REJECTED_UNKNOWN_EXCEPT: []}
        if not isinstance(settings.get(REJECTED_SAVED_PASSWORDS, []), list):
            settings.pop(REJECTED_SAVED_PASSWORDS)
            settings.setdefault(REJECTED_UNKNOWN_EXCEPT, [])
        if REJECTED_UNKNOWN_EXCEPT in settings and not isinstance(settings[REJECTED_UNKNOWN_EXCEPT], list):
            # Nobody known to be cleared: every account stays rejected.
            settings[REJECTED_UNKNOWN_EXCEPT] = []
        return settings

    def saved_password_rejected(self, username: str) -> bool:
        """Whether a server rejected this account's saved password.

        Fails closed: a settings file that exists but cannot be read or
        parsed counts as "rejected", because wrongly answering "no" would
        send a password that may already have been refused. So does an
        account not cleared since such a file was replaced
        (REJECTED_UNKNOWN_EXCEPT).
        """
        try:
            text = (self.root / SETTINGS_FILE).read_text(encoding="utf-8")
        except FileNotFoundError:
            return False
        except OSError:
            return True
        try:
            settings = json.loads(text)
        except ValueError:
            return True
        if not isinstance(settings, dict):
            return True
        names = settings.get(REJECTED_SAVED_PASSWORDS, [])
        if not isinstance(names, list):
            return True
        if any(same_account(name, username) for name in names):
            return True
        if REJECTED_UNKNOWN_EXCEPT not in settings:
            return False
        cleared = settings[REJECTED_UNKNOWN_EXCEPT]
        return not isinstance(cleared, list) or not any(same_account(name, username) for name in cleared)

    def set_saved_password_rejected(self, username: str, rejected: bool) -> None:
        with self._settings_lock:
            settings = self._settings_to_update()
            names = [
                n
                for n in settings.get(REJECTED_SAVED_PASSWORDS, [])
                if isinstance(n, str) and not same_account(n, username)
            ]
            if rejected:
                names.append(username.lower())
            if names:
                settings[REJECTED_SAVED_PASSWORDS] = sorted(names)
            else:
                settings.pop(REJECTED_SAVED_PASSWORDS, None)
            if REJECTED_UNKNOWN_EXCEPT in settings:
                # Flags lost with an unreadable file: lifting this account's
                # leaves every other account rejected.
                cleared = [
                    n
                    for n in settings[REJECTED_UNKNOWN_EXCEPT]
                    if isinstance(n, str) and not same_account(n, username)
                ]
                if not rejected:
                    cleared.append(username.lower())
                settings[REJECTED_UNKNOWN_EXCEPT] = sorted(cleared)
            self.write(SETTINGS_FILE, settings)

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
        username = validate_username(username)
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
