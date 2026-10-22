"""The macOS app's domain rules, ported for the desktop app.

The originals live in Sources/HPCCore (SlurmStates.swift, GPUAccounting.swift,
JobLogic.swift, OverviewSummaries.swift, DashboardsPresentation.swift,
TimeFormatting.swift) and in the macOS app's storage rules (ClusterSession,
FoundationRefreshRules.swift). Each port names its Swift original, and
tests/test_domain.py runs the Swift test tables against them, so both front
ends show the same figures for one snapshot: node availability, GPU pools per
model, job queue counts, storage pressure and cadence, and cluster times.

Standard library only (plus the collector, itself stdlib-only), so the rules
and their tests run on any machine.
"""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from datetime import datetime, timezone, tzinfo
from typing import Iterable

import hpc_snapshot as collector

from .core import Profile


# ---------------------------------------------------------------------------
# Reading snapshot fields defensively
# ---------------------------------------------------------------------------
# validate_snapshot checks the fields every screen depends on; the rules
# below also run on partial rows (tests, older caches), so they read every
# field through these helpers and treat anything unexpected as missing.


def _text(value: object) -> str:
    return value if isinstance(value, str) else ""


def _whole(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return None


def _number(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(value) else None


# ---------------------------------------------------------------------------
# Times (HPCCore TimeFormatting.swift, SlurmTimestamp)
# ---------------------------------------------------------------------------


def cluster_zone() -> tzinfo | None:
    """The zone of Slurm's zone-less times: Europe/London (or HPC_CLUSTER_TZ).

    Taken from the collector, which renders squeue --json epochs in this
    same zone, so a time it writes and a time read here always agree. Without
    a time-zone database the collector falls back to the machine's own zone
    (None here), and so does parse_slurm_time.
    """
    zone = collector._cluster_zone()
    return zone if isinstance(zone, tzinfo) else None


# The two zone-less shapes Slurm and the collector print.
_PLAIN_TIME_FORMATS = ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S")


def parse_slurm_time(raw: object) -> datetime | None:
    """An aware datetime for a collector or Slurm timestamp, or None.

    Timestamps with a zone ("...+00:00", "...Z") are taken as they are.
    Zone-less ones ("2026-10-13T11:41:38", Slurm's submit/start/end times)
    are cluster wall-clock time, never this computer's: both clusters are in
    Leeds, and a user abroad would otherwise read them hours off.
    """
    text = _text(raw).strip()
    if not text:
        return None
    for pattern in _PLAIN_TIME_FORMATS:
        try:
            naive = datetime.strptime(text, pattern)
            zone = cluster_zone()
            return naive.replace(tzinfo=zone) if zone is not None else naive.astimezone()
        except (ValueError, OverflowError, OSError):
            # Not this shape (or, on Windows, a date the OS cannot place).
            continue
    try:
        stamp = datetime.fromisoformat(text[:-1] + "+00:00" if text.endswith("Z") else text)
    except ValueError:
        return None
    return stamp if stamp.tzinfo is not None else None


def local_time_text(raw: object, pattern: str = "%d %b %Y %H:%M:%S %Z") -> str:
    """raw in this computer's time zone, e.g. "13 Oct 2026 12:41:38 BST".

    Every time the app shows goes through here (or is already local, like
    the Trends axis), so a table never mixes UTC, cluster and local times.
    Anything unparsable is shown as it came.
    """
    stamp = parse_slurm_time(raw)
    if stamp is None:
        return _text(raw)
    try:
        return stamp.astimezone().strftime(pattern)
    except (ValueError, OverflowError, OSError):
        return _text(raw)


def slurm_duration_text(seconds: int) -> str:
    """A length of time in words: "45 s", "3 h 5 min", "2 days 1 h"
    (HPCCore slurmDurationText). Seconds only under an hour."""
    total = max(0, int(seconds))
    days, hours, minutes, rest = total // 86_400, total % 86_400 // 3600, total % 3600 // 60, total % 60
    parts = []
    if days:
        parts.append("1 day" if days == 1 else f"{days} days")
    if hours:
        parts.append(f"{hours} h")
    if minutes:
        parts.append(f"{minutes} min")
    if rest and not days and not hours:
        parts.append(f"{rest} s")
    return " ".join(parts) or "0 min"


# ---------------------------------------------------------------------------
# Node states (HPCCore SlurmStates.swift, NodeStateInfo)
# ---------------------------------------------------------------------------

# Compact sinfo %t flags: trailing symbols, possibly several.
NODE_FLAG_SYMBOLS = "*$-~#%!@^"

_NODE_BASES = {
    "idle": "idle",
    "mix": "mixed",
    "mixed": "mixed",
    "alloc": "allocated",
    "allocated": "allocated",
    "comp": "completing",
    "completing": "completing",
    "plnd": "planned",
    "planned": "planned",
    "drng": "draining",
    "draining": "draining",
    "drain": "drained",
    "drained": "drained",
    "down": "down",
    "failg": "failing",
    "failing": "failing",
    "fail": "failed",
    "failed": "failed",
    "maint": "maintenance",
    "resv": "reserved",
    "reserved": "reserved",
    "futr": "future",
    "future": "future",
    "blocked": "blocked",
    "inval": "invalid",
    "invalid": "invalid",
    "boot": "booting",
    "booting": "booting",
    "reboot": "rebooting",
    "reboot_issued": "rebooting",
    "reboot_requested": "rebooting",
    "pow_dn": "powered_down",
    "powered_down": "powered_down",
    "power_down": "powered_down",
    "powering_down": "powered_down",
    # sinfo abbreviates UNKNOWN as "unk"; both read as the plain word.
    "unk": "unknown",
    "unknown": "unknown",
}
# The only bases on which the scheduler can start new work. An allow-list,
# so an unfamiliar state never counts as free capacity.
AVAILABLE_NODE_BASES = frozenset({"idle", "mixed", "allocated", "completing", "planned"})
_NODE_LABELS = {
    "idle": "Idle",
    "mixed": "Mixed",
    "allocated": "Allocated",
    "completing": "Completing",
    "planned": "Idle (planned)",
    "draining": "Draining",
    "drained": "Drained",
    "down": "Down",
    "failing": "Failing",
    "failed": "Failed",
    "maintenance": "Maintenance",
    "reserved": "Reserved",
    "future": "Future",
    "blocked": "Blocked",
    "invalid": "Invalid",
    "booting": "Booting",
    "rebooting": "Rebooting",
    "powered_down": "Powered down",
}


@dataclass(frozen=True)
class NodeState:
    """A Slurm node state from sinfo %t (compact: "mix-", "drain*", "idle$")
    or %T/scontrol (long: "MIXED+PLANNED", "IDLE+DRAIN")."""

    raw: str
    base: str
    # "*": the node is not responding.
    not_responding: bool = False
    # "$": the node is in a maintenance reservation.
    maintenance_reservation: bool = False
    # "-": planned by the backfill scheduler for a higher-priority job.
    planned_by_backfill: bool = False
    # "~" powered off (the scheduler can resume it), "#" powering up.
    power_saving: bool = False
    # "%" powering down, "!" pending power down.
    powering_down: bool = False
    # "@" reboot pending, "^" reboot issued.
    reboot_pending: bool = False

    @classmethod
    def parse(cls, raw: object) -> NodeState:
        raw_text = _text(raw)
        text = raw_text.strip().lower()
        symbols = set()
        while text and text[-1] in NODE_FLAG_SYMBOLS:
            symbols.add(text[-1])
            text = text[:-1]
        # Long forms combine a base with "+FLAG" parts (empty parts ignored,
        # as Swift's split does).
        parts = [part for part in text.split("+") if part]
        head = parts[0] if parts else ""
        flags = set(parts[1:])
        base = _NODE_BASES.get(head, "unknown")
        if "drain" in flags:
            base = "drained" if base in ("idle", "down", "planned") else "draining"
        elif "fail" in flags:
            # Compact "fail" (nothing running) and "failg" (work still on it).
            base = "failed" if base in ("idle", "down", "planned") else "failing"
        elif ("reserved" in flags or "resv" in flags) and base == "idle":
            # An idle node in an advanced reservation is compact "resv".
            base = "reserved"
        planned = "-" in symbols
        if "planned" in flags or "plnd" in flags:
            planned = True
            if base == "idle":
                base = "planned"
        # Same split as the compact codes: POWERED_DOWN ("~") and POWERING_UP
        # ("#") are power saving the scheduler can resume; POWERING_DOWN ("%")
        # and POWER_DOWN (pending power down, "!") take the node away.
        return cls(
            raw=raw_text,
            base=base,
            not_responding="*" in symbols or bool(flags & {"not_responding", "no_respond"}),
            maintenance_reservation="$" in symbols or "maint" in flags,
            planned_by_backfill=planned,
            power_saving=bool(symbols & {"~", "#"}) or bool(flags & {"powered_down", "powering_up"}),
            powering_down=bool(symbols & {"%", "!"}) or bool(flags & {"powering_down", "power_down"}),
            reboot_pending=bool(symbols & {"@", "^"}) or bool(flags & {"reboot_requested", "reboot_issued"}),
        )

    @property
    def available(self) -> bool:
        """Whether the scheduler can start new work on the node."""
        return self.base in AVAILABLE_NODE_BASES and not (
            self.not_responding or self.maintenance_reservation or self.reboot_pending or self.powering_down
        )

    @property
    def label(self) -> str:
        """Plain-language state: "Mixed", "Drained", ..."""
        if self.base in _NODE_LABELS:
            return _NODE_LABELS[self.base]
        # An unfamiliar state is shown as Slurm spelled it rather than
        # guessed; Slurm's own UNKNOWN (and the empty string) is a word.
        stripped = self.raw.strip()
        head = re.match(r"[^\W\d]*", stripped.lower())
        word = head.group(0) if head else ""
        return "Unknown" if word in ("", "unk", "unknown") else stripped.upper()

    @property
    def flag_descriptions(self) -> list[str]:
        """What the trailing flags mean, in a fixed order."""
        descriptions = []
        if self.not_responding:
            descriptions.append("not responding")
        if self.maintenance_reservation:
            descriptions.append("in a maintenance reservation")
        if self.planned_by_backfill:
            descriptions.append("planned by backfill for a queued job")
        if self.power_saving:
            descriptions.append("powered down to save energy")
        if self.powering_down:
            descriptions.append("powering down")
        if self.reboot_pending:
            descriptions.append("reboot pending")
        return descriptions

    @property
    def description(self) -> str:
        """The label with its flags, e.g. "Down (in a maintenance reservation)"."""
        flags = self.flag_descriptions
        return f"{self.label} ({', '.join(flags)})" if flags else self.label


def node_available(state: object) -> bool:
    return NodeState.parse(state).available


# ---------------------------------------------------------------------------
# GRES and per-node GPU facts (HPCCore GPUAccounting.swift)
# ---------------------------------------------------------------------------


def _split_outside_parentheses(text: str, separator: str = ",") -> list[str]:
    parts = []
    current = ""
    depth = 0
    for character in text:
        if character == "(":
            depth += 1
        elif character == ")":
            depth = max(depth - 1, 0)
        if character == separator and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += character
    if current:
        parts.append(current)
    return parts


def _gres_pieces(entry: str) -> list[str]:
    # Drop a parenthesised suffix such as (S:0-1) or (IDX:0,2); empty pieces
    # are ignored, as Swift's split does.
    core = entry.strip().split("(", 1)[0]
    return [piece for piece in core.split(":") if piece]


def slurm_gpu_total(gres: object) -> int:
    """GPUs in a sinfo %G string: "gpu:4", "gpu:l40s:3" (AIRE),
    "gpu:nvidia_h200:8(S:0-1)" (Calder), "gpu:a100:4(S:0,2),mps:400", a bare
    "gpu" (one GPU), and "(null)"."""
    trimmed = _text(gres).strip()
    if not trimmed or trimmed.lower() == "(null)":
        return 0
    total = 0
    for entry in _split_outside_parentheses(trimmed):
        pieces = _gres_pieces(entry)
        if not pieces or pieces[0].lower() != "gpu":
            continue
        if len(pieces) == 1:
            total += 1
            continue
        digits = re.match(r"\d+", pieces[-1])
        if digits:
            total += int(digits.group(0))
    return total


def slurm_gpu_model(gres: object) -> str | None:
    """Raw gres type: "l40s" for "gpu:l40s:3(S:0-1)", "nvidia_h200" for
    "gpu:nvidia_h200:8"; None for "gpu:4" or "(null)". An identifier: show it
    through gpu_model_display_name."""
    for entry in _split_outside_parentheses(_text(gres)):
        pieces = _gres_pieces(entry)
        if len(pieces) >= 3 and pieces[0].lower() == "gpu":
            return pieces[1]
    return None


def gpu_model_display_name(raw_model: str) -> str:
    """ "l40s" -> "L40S", "nvidia_h200" -> "H200", "a100_80g" -> "A100 80G"."""
    model = raw_model.strip()
    for prefix in ("nvidia_", "nvidia-", "amd_", "amd-"):
        if model.lower().startswith(prefix):
            model = model[len(prefix) :]
    return model.replace("_", " ").upper()


def slurm_gpu_model_display_name(gres: object) -> str | None:
    model = slurm_gpu_model(gres)
    return gpu_model_display_name(model) if model is not None else None


def node_gpu_count(node: dict) -> int:
    """Configured GPUs: the TRES count when the collector had node details,
    otherwise the gres string."""
    total = _whole(node.get("gpu_total"))
    return total if total is not None else slurm_gpu_total(node.get("gres"))


def known_gpu_allocated(node: dict) -> int | None:
    """Allocated GPUs, or None when unknown: without node details "nothing
    reported" cannot be told apart from "nothing allocated", and unknown is
    never treated as idle."""
    allocated = _whole(node.get("gpu_allocated"))
    if allocated is not None:
        return allocated
    count = node_gpu_count(node)
    idle = _whole(node.get("gpu_idle"))
    if idle is not None:
        return max(count - idle, 0)
    return 0 if count == 0 else None


def cpus_full(node: dict) -> bool:
    """Whether every CPU is taken, so no new job can start here even when a
    GPU is idle (a "stranded" GPU)."""
    idle = _whole(node.get("cpu_idle"))
    if idle is not None:
        return idle <= 0
    total = _whole(node.get("cpu_total"))
    allocated = _whole(node.get("cpu_allocated"))
    if total is not None and allocated is not None:
        return total - allocated - (_whole(node.get("cpu_other")) or 0) <= 0
    return False


# ---------------------------------------------------------------------------
# GPU pools (HPCCore GPUAccounting.swift GPUFleet, OverviewSummaries.swift)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class GPUPool:
    """All GPUs of one model on one cluster. GPU models are separate pools:
    an idle L40 is not an idle H200, so pools are never summed into one
    "free" figure without naming each model."""

    # Display name ("H200"); None for GPUs whose gres names no model.
    model: str | None
    partitions: tuple[str, ...] = ()
    node_count: int = 0
    total: int = 0
    # Known allocated GPUs, on any node (draining nodes included).
    allocated: int = 0
    # Idle GPUs a new job could start on now: available node, free CPU.
    idle: int = 0
    # Idle GPUs on available nodes whose CPUs are all taken.
    stranded: int = 0
    # Idle (or unreported) GPUs on nodes that accept no work.
    unavailable: int = 0
    # GPUs on available nodes whose allocation is unknown.
    unknown: int = 0
    # GPU nodes that accept no new work.
    unavailable_nodes: int = 0

    @property
    def label(self) -> str:
        return self.model or "GPU"

    @property
    def idle_is_unknown(self) -> bool:
        """Nothing is known to be idle, but only because the allocation of
        some GPUs is unknown: that is not a full pool."""
        return self.idle == 0 and self.unknown > 0

    @property
    def idle_figure(self) -> str:
        """The idle count, or "?" while idle_is_unknown: a bare "0" would
        claim a full pool. With some GPUs known idle the count stands (a
        floor; the caption names the unknown ones)."""
        return "?" if self.idle_is_unknown else str(self.idle)

    @property
    def idle_summary(self) -> str:
        """ "1 of 84 L40S idle", "0 of 4 GPUs idle"."""
        if self.model:
            return f"{self.idle} of {self.total} {self.model} idle"
        return f"{self.idle} of {self.total} GPU{'' if self.total == 1 else 's'} idle"

    @property
    def idle_figure_summary(self) -> str:
        """idle_summary with idle_figure in it: "? of 84 L40S idle"."""
        if not self.idle_is_unknown:
            return self.idle_summary
        if self.model:
            return f"? of {self.total} {self.model} idle"
        return f"? of {self.total} GPU{'' if self.total == 1 else 's'} idle"

    @property
    def breakdown_summary(self) -> str:
        """ "77 in use · 1 stranded · 6 unavailable". Zero parts are left out,
        except "in use" — unless unknown GPUs stand in for it: never a definite
        "0 in use" for GPUs nobody reported on."""
        parts = []
        if self.allocated > 0 or self.unknown == 0:
            parts.append(f"{self.allocated} in use")
        if self.stranded > 0:
            parts.append(f"{self.stranded} stranded")
        if self.unavailable > 0:
            parts.append(f"{self.unavailable} unavailable")
        if self.unknown > 0:
            parts.append(f"{self.unknown} unknown")
        return " · ".join(parts)

    @property
    def in_use_caption(self) -> str:
        if self.unknown == 0:
            return f"{self.allocated} in use"
        if self.allocated == 0:
            return f"{self.unknown} unknown"
        return f"{self.allocated} in use · {self.unknown} unknown"

    @property
    def is_wholly_unavailable(self) -> bool:
        """Every node of the pool accepts no new work."""
        return self.node_count > 0 and self.unavailable_nodes == self.node_count

    @property
    def capacity_caption(self) -> str:
        """The line under a pool's idle figure: every GPU that is not idle,
        by why. A pool none of whose nodes accept work reads "all 3
        unavailable"."""
        if self.is_wholly_unavailable and self.allocated == 0 and self.unknown == 0:
            return f"all {self.total} unavailable"
        return self.breakdown_summary

    @property
    def idle_tone(self) -> str:
        """ "normal" while some GPU can start a job now; "warning" when the
        pool is known to be full (busy, not a fault, so never critical);
        "unavailable" when every node is out of service or idle is unknown."""
        if self.total == 0 or self.is_wholly_unavailable or self.idle_is_unknown:
            return "unavailable"
        return "normal" if self.idle > 0 else "warning"


# GPUPool's counters, tallied per model by GPUFleet.from_nodes.
_POOL_COUNTS = (
    "node_count",
    "total",
    "allocated",
    "idle",
    "stranded",
    "unavailable",
    "unknown",
    "unavailable_nodes",
)


@dataclass(frozen=True)
class GPUFleet:
    """Every GPU pool of one cluster snapshot, largest first: the one place
    idle, stranded, unavailable and unknown GPUs are defined."""

    pools: tuple[GPUPool, ...] = ()

    @classmethod
    def from_nodes(cls, nodes: Iterable[dict]) -> GPUFleet:
        # Per model display name ("" for untyped GPUs). Dicts keep insertion
        # order, which is the first-seen order the final sort falls back to
        # for pools of equal size.
        tallies: dict[str, dict[str, int]] = {}
        partitions_by_model: dict[str, list[str]] = {}
        for node in nodes:
            if not isinstance(node, dict):
                continue
            total = node_gpu_count(node)
            if total <= 0:
                continue
            key = slurm_gpu_model_display_name(node.get("gres")) or ""
            tally = tallies.setdefault(key, dict.fromkeys(_POOL_COUNTS, 0))
            tally["node_count"] += 1
            tally["total"] += total
            seen = partitions_by_model.setdefault(key, [])
            partitions = node.get("partitions")
            for partition in partitions if isinstance(partitions, list) else []:
                if isinstance(partition, str) and partition not in seen:
                    seen.append(partition)
            available = node_available(node.get("state"))
            if not available:
                tally["unavailable_nodes"] += 1
            allocated = known_gpu_allocated(node)
            if allocated is not None:
                allocated_here = min(allocated, total)
                idle_here = total - allocated_here
                tally["allocated"] += allocated_here
                if not available:
                    tally["unavailable"] += idle_here
                elif cpus_full(node):
                    tally["stranded"] += idle_here
                else:
                    tally["idle"] += idle_here
            elif available:
                tally["unknown"] += total
            else:
                tally["unavailable"] += total
        pools = [
            GPUPool(model=key or None, partitions=tuple(partitions_by_model[key]), **tally)
            for key, tally in tallies.items()
        ]
        # sorted is stable, so equal totals keep first-seen order.
        return cls(tuple(sorted(pools, key=lambda pool: -pool.total)))

    @property
    def total(self) -> int:
        return sum(pool.total for pool in self.pools)

    @property
    def allocated(self) -> int:
        return sum(pool.allocated for pool in self.pools)

    @property
    def idle(self) -> int:
        """Startable idle GPUs across ALL models. Only for trend lines; what
        the user reads per cluster names each model (pools)."""
        return sum(pool.idle for pool in self.pools)

    @property
    def stranded(self) -> int:
        return sum(pool.stranded for pool in self.pools)

    @property
    def unavailable(self) -> int:
        return sum(pool.unavailable for pool in self.pools)

    @property
    def unknown(self) -> int:
        return sum(pool.unknown for pool in self.pools)

    @property
    def unavailable_nodes(self) -> int:
        return sum(pool.unavailable_nodes for pool in self.pools)

    @property
    def node_count(self) -> int:
        return sum(pool.node_count for pool in self.pools)

    @property
    def has_unknown_allocation(self) -> bool:
        return self.unknown > 0

    @property
    def primary(self) -> GPUPool | None:
        """The largest pool, e.g. Calder's H200s next to a few L40s."""
        return self.pools[0] if self.pools else None

    @property
    def model_label(self) -> str | None:
        """ "H200", "H200 + L40", "H200 + L40 + more"."""
        names = [pool.label for pool in self.pools]
        if not names:
            return None
        named = " + ".join(names[:2])
        return named + " + more" if len(names) > 2 else named

    @property
    def pools_with_idle(self) -> list[GPUPool]:
        return [pool for pool in self.pools if pool.idle > 0]

    @property
    def primary_idle_text(self) -> str | None:
        """The largest pool's idle phrase, then how many other models there
        are: "0 of 56 H200 idle · +1 more model" ("+1" straight after "idle"
        would read as one more idle GPU)."""
        primary = self.primary
        if primary is None:
            return None
        others = len(self.pools) - 1
        if others <= 0:
            return primary.idle_figure_summary
        return f"{primary.idle_figure_summary} · +{others} more model{'' if others == 1 else 's'}"


def gpu_fleet(snapshot: dict) -> GPUFleet:
    nodes = snapshot.get("nodes")
    return GPUFleet.from_nodes(nodes if isinstance(nodes, list) else [])


# ---------------------------------------------------------------------------
# Job states and job rows (HPCCore SlurmStates.swift JobState, JobLogic.swift,
# DashboardsPresentation.swift SlurmPendingReason)
# ---------------------------------------------------------------------------

_JOB_KINDS = {
    "PENDING": "pending",
    "PD": "pending",
    "RUNNING": "running",
    "R": "running",
    "SUSPENDED": "suspended",
    "S": "suspended",
    "STOPPED": "suspended",
    "ST": "suspended",
    "COMPLETING": "completing",
    "CG": "completing",
    "CONFIGURING": "configuring",
    "CF": "configuring",
    # Requeued or held for requeue: waiting to run again.
    "REQUEUED": "requeued",
    "RQ": "requeued",
    "REQUEUE_HOLD": "requeued",
    "RH": "requeued",
    "REQUEUE_FED": "requeued",
    "RF": "requeued",
}
_FINISHED_JOB_STATES = frozenset(
    {
        "COMPLETED",
        "CD",
        "CANCELLED",
        "CA",
        "FAILED",
        "F",
        "TIMEOUT",
        "TO",
        "NODE_FAIL",
        "NF",
        "PREEMPTED",
        "PR",
        "BOOT_FAIL",
        "BF",
        "DEADLINE",
        "DL",
        "OUT_OF_MEMORY",
        "OOM",
        "REVOKED",
        "RV",
        "SPECIAL_EXIT",
        "SE",
    }
)
_JOB_LABELS = {
    "pending": "Pending",
    "running": "Running",
    "suspended": "Suspended",
    "completing": "Completing",
    "configuring": "Configuring",
    "requeued": "Requeued",
}


@dataclass(frozen=True)
class JobState:
    """A Slurm job state, long ("RUNNING") or compact ("R"); flags after "+"
    or a space are ignored. Parsed by word, never by substring: a substring
    match once counted SUSPENDED jobs as pending ("pend")."""

    # pending, running, suspended, completing, configuring, requeued,
    # finished or other.
    kind: str
    base: str

    @classmethod
    def parse(cls, raw: object) -> JobState:
        base = re.split(r"[+ ]", _text(raw).strip().upper(), maxsplit=1)[0]
        if base in _JOB_KINDS:
            return cls(_JOB_KINDS[base], base)
        return cls("finished" if base in _FINISHED_JOB_STATES else "other", base)

    @property
    def is_running(self) -> bool:
        return self.kind == "running"

    @property
    def is_pending(self) -> bool:
        """Waiting in the queue, requeued jobs included."""
        return self.kind in ("pending", "requeued")

    @property
    def occupies_nodes(self) -> bool:
        """Running, completing or still configuring: holding nodes now."""
        return self.kind in ("running", "completing", "configuring")

    @property
    def is_finished(self) -> bool:
        return self.kind == "finished"

    @property
    def label(self) -> str:
        if self.kind in _JOB_LABELS:
            return _JOB_LABELS[self.kind]
        return self.base.capitalize().replace("_", " ") if self.base else "Unknown"


def pending_reason(job: dict) -> str | None:
    """Why a pending job waits, from squeue's %R ("(Priority)" -> "Priority");
    None when it is not pending or Slurm gives no reason. For a running job
    the same column is its node list, which is not a reason."""
    if not JobState.parse(job.get("state")).is_pending:
        return None
    text = _text(job.get("reason_or_node_list")).strip()
    if text.startswith("(") and text.endswith(")"):
        text = text[1:-1].strip()
    if not text or text.lower() in ("none", "(null)"):
        return None
    return text


def is_held(job: dict) -> bool:
    """Held by the user or an administrator (JobHeldUser, JobHeldAdmin,
    JobHoldMaxRequeue, ...): it will not start until released, however much
    capacity frees up, so it is never counted as pending."""
    reason = pending_reason(job)
    return reason is not None and ("held" in reason.lower() or "hold" in reason.lower())


def is_array_remainder(job: dict) -> bool:
    """The pending remainder of a job array: one squeue row standing for
    every task still queued. Cancelling it by its bare id would cancel the
    WHOLE array, running tasks included."""
    return job.get("array_pending_tasks") is not None and "_" not in _text(job.get("job_id"))


def task_multiplicity(job: dict) -> int:
    """How many jobs this row stands for in queue counts."""
    if not is_array_remainder(job):
        return 1
    count = _whole(job.get("pending_task_count"))
    return max(count if count is not None else 1, 1)


def display_job_id(job: dict) -> str:
    """ "8248307_[2-5]" for an array remainder, the plain id otherwise."""
    job_id = _text(job.get("job_id"))
    tasks = _text(job.get("array_pending_tasks"))
    if is_array_remainder(job) and tasks:
        return f"{job_id}_[{tasks}]"
    return job_id


def job_display_rank(job: dict) -> int:
    """0 running, 1 pending on resources or priority, 2 on a dependency,
    3 held, 4 anything else."""
    state = JobState.parse(job.get("state"))
    if state.occupies_nodes:
        return 0
    if state.is_pending:
        reason = _text(job.get("reason_or_node_list")).lower()
        if "held" in reason or "hold" in reason:
            return 3
        if "dependency" in reason:
            return 2
        return 1
    return 4


def _natural_key(text: str) -> tuple[tuple[int, str], ...]:
    # Digit runs compare as numbers (9 before 10). re.split alternates text
    # and digits, so equal positions always hold the same kind.
    return tuple(
        (int(part), "") if index % 2 else (0, part.lower())
        for index, part in enumerate(re.split(r"(\d+)", text))
    )


def job_sort_key(job: dict) -> tuple:
    """One job order for every surface: running first, then pending on
    resources or priority, then dependencies, then held, then the rest; ties
    by id in natural order."""
    return (job_display_rank(job), _natural_key(_text(job.get("job_id"))))


@dataclass(frozen=True)
class JobQueueCounts:
    """How many of the user's jobs are in each queue state. An array's
    pending remainder counts as every task it stands for, as `squeue -r`
    would show."""

    # Running, completing or still configuring: holding nodes now.
    running: int = 0
    # Waiting for resources, priority or a dependency.
    pending: int = 0
    # Waiting but held; will not start until released.
    held: int = 0
    # Suspended, finished or a state this build does not know.
    other: int = 0

    @classmethod
    def from_jobs(cls, jobs: Iterable[dict]) -> JobQueueCounts:
        counts = {"running": 0, "pending": 0, "held": 0, "other": 0}
        for job in jobs:
            if not isinstance(job, dict):
                continue
            weight = task_multiplicity(job)
            state = JobState.parse(job.get("state"))
            if state.occupies_nodes:
                counts["running"] += weight
            elif is_held(job):
                counts["held"] += weight
            elif state.is_pending:
                counts["pending"] += weight
            else:
                counts["other"] += weight
        return cls(**counts)

    @property
    def waiting(self) -> int:
        return self.pending + self.held

    @property
    def total(self) -> int:
        return self.running + self.pending + self.held + self.other

    def summary(self, other_label: str = "other") -> str:
        """ "1 running · 13 pending · 2 held": zero parts other than running
        are left out so the line stays short; held jobs are always named on
        their own, never as pending."""
        parts = [f"{self.running} running"]
        if self.pending > 0 or (self.held == 0 and self.other == 0):
            parts.append(f"{self.pending} pending")
        if self.held > 0:
            parts.append(f"{self.held} held")
        if self.other > 0:
            parts.append(f"{self.other} {other_label}")
        return " · ".join(parts)


def job_change_messages(previous: Iterable[dict], current: Iterable[dict]) -> list[str]:
    """Starts, then endings, between two job lists, as notification lines
    (see job_changes). Not bounded by how old previous is: job_notice_lines
    applies that rule."""
    started, ended = job_changes(previous, current)
    return started + ended


def job_changes(previous: Iterable[dict], current: Iterable[dict]) -> tuple[list[str], list[str]]:
    """(started, ended): starts (pending -> running) and endings (a terminal
    state, or the job left squeue) between two refreshes, as notification
    lines (JobStateDiff.compute in the macOS app). Endings are in job id
    order.

    Job arrays: the pending remainder ("123", tasks "0-58") sheds one "123_N"
    row per task that starts, so a running task whose array had a pending
    remainder counts as started, and a remainder that vanishes while the
    array still has tasks on the queue (its last task started, or its
    pending tasks were cancelled) is not an ending.
    """
    old_jobs = [job for job in previous if isinstance(job, dict)]
    new_jobs = [job for job in current if isinstance(job, dict)]
    old_by_id = {_text(job.get("job_id")): job for job in old_jobs}
    new_ids = {_text(job.get("job_id")) for job in new_jobs}
    arrays_on_queue = {job.get("array_job_id") for job in new_jobs if job.get("array_job_id") is not None}
    remainder_states = {
        job.get("array_job_id"): _text(job.get("state"))
        for job in old_jobs
        if is_array_remainder(job)
        and job.get("array_job_id") is not None
        and JobState.parse(job.get("state")).is_pending
    }
    started: list[str] = []
    ended: list[tuple[tuple, str]] = []
    reported: set[str] = set()
    for job in new_jobs:
        job_id = _text(job.get("job_id"))
        state_text = _text(job.get("state"))
        state = JobState.parse(state_text)
        old = old_by_id.get(job_id)
        if old is not None:
            old_state = _text(old.get("state"))
            if old_state == state_text:
                continue
            if state.is_finished:
                ended.append((_natural_key(job_id), f"{display_job_id(job)}: {old_state} → {state_text}"))
            elif JobState.parse(old_state).is_pending and state.is_running and job_id not in reported:
                # Only a queued job starting is news: a SUSPENDED job
                # resuming is not.
                reported.add(job_id)
                started.append(f"{display_job_id(job)}: {old_state} → {state_text}")
        elif state.is_running and job.get("array_job_id") in remainder_states and job_id not in reported:
            reported.add(job_id)
            started.append(f"{job_id}: {remainder_states[job.get('array_job_id')]} → {state_text}")
    for job_id, old in old_by_id.items():
        if job_id in new_ids or JobState.parse(old.get("state")).is_finished:
            continue
        if is_array_remainder(old) and old.get("array_job_id") in arrays_on_queue:
            continue
        ended.append(
            (_natural_key(job_id), f"{display_job_id(old)}: left the active queue (final status unknown)")
        )
    return started, [message for _, message in sorted(ended, key=lambda item: item[0])]


# When job changes are announced (JobStateDiff.plan). The baseline is the
# snapshot on screen, which after a restart is the cached one and after a
# Disconnect the last one before it: possibly days old. Compared as it is,
# every job that ended meanwhile would be announced as if it had just left
# the queue.
#
# A baseline up to this old (seconds) is compared job by job: a couple of
# missed refreshes, a short VPN blip.
JOB_NOTICE_INDIVIDUAL_WINDOW = 10 * 60
# Up to this old, one catch-up summary instead of a burst. Older than this a
# comparison would mostly report long-resolved jobs, so the new snapshot just
# becomes the baseline, silently.
JOB_NOTICE_SUMMARY_WINDOW = 24 * 60 * 60


def _instant(raw: object) -> datetime | None:
    """A snapshot's collected_at as an aware datetime, or None. Zone-less
    values are UTC, as the cards' "snapshot ... ago" reads them."""
    try:
        stamp = datetime.fromisoformat(_text(raw))
    except ValueError:
        return None
    return stamp if stamp.tzinfo is not None else stamp.replace(tzinfo=timezone.utc)


def job_change_delivery(
    previous_collected_at: object, current_collected_at: object
) -> tuple[str, float] | None:
    """How to announce the job changes between two snapshots of one
    account, from the time between them (JobStateDiff.plan):
    ("individual", gap) up to 10 minutes, ("summary", gap) up to 24 hours,
    and None beyond that or when either time cannot be read: with no bound
    on how old the baseline is, re-seeding is safer than replaying it."""
    previous, current = _instant(previous_collected_at), _instant(current_collected_at)
    if previous is None or current is None:
        return None
    gap = (current - previous).total_seconds()
    if gap > JOB_NOTICE_SUMMARY_WINDOW:
        return None
    return ("summary" if gap > JOB_NOTICE_INDIVIDUAL_WINDOW else "individual"), gap


def job_notice_lines(cluster_name: str, previous: dict, current: dict) -> list[str]:
    """The notification lines for the job changes from previous to current
    (two snapshots of one account), within job_change_delivery's windows.

    After a short gap, one line per start or ending, as they happen. After a
    longer one, a heading first ("While AIRE was not watched (3 h): 2 jobs
    ended or left the queue, 1 started", the macOS catch-up summary), then
    the endings and starts, so a tray that shows only the first lines still
    says what happened. After more than a day, nothing.
    """
    delivery = job_change_delivery(previous.get("collected_at"), current.get("collected_at"))
    if delivery is None:
        return []
    kind, gap = delivery
    started, ended = job_changes(previous.get("jobs") or [], current.get("jobs") or [])
    if kind == "individual" or not (started or ended):
        return started + ended
    counts = []
    if ended:
        counts.append(f"{len(ended)} job{'' if len(ended) == 1 else 's'} ended or left the queue")
    if started:
        counts.append(f"{len(started)} started")
    heading = f"While {cluster_name} was not watched ({slurm_duration_text(int(gap))}): {', '.join(counts)}"
    return [heading, *ended, *started]


# ---------------------------------------------------------------------------
# Storage (HPCCore DashboardsPresentation.swift, Catalog.swift StatusTone;
# the macOS app's ClusterSession storage cadence and mergeStorage)
# ---------------------------------------------------------------------------

STORAGE_WARNING_PERCENT = 75
STORAGE_CRITICAL_PERCENT = 90
# Storage (df, quota, lfs) changes slowly and is the slowest, most
# hang-prone part of a collection, so most refreshes skip it: it is
# collected on the first refresh after sign-in, on a manual refresh, and
# otherwise once the rows on screen are this old (seconds).
STORAGE_REFRESH_INTERVAL = 300
# After a refresh asked for storage and got none (an earlier df/quota/lfs
# still stuck, or the budget ran out before the section), automatic
# refreshes wait this long before asking again.
STORAGE_RETRY_AFTER_MISS = 60
# How long after the last complete storage collection a row cut short may
# still show its previous figures: long enough to ride out a retry or two,
# short enough that a volume that keeps failing shows as unreadable rather
# than as stale figures.
STORAGE_CARRY_LIMIT = 600

_UNAVAILABLE_STORAGE_TEXT = {
    "missing": "not found on the login node",
    "no-figures": "no figures in time",
    "not-collected": "not reached this refresh",
}


def usage_tone(percent: float | None) -> str:
    """Usage tone: warning from 75 %, critical from 90 %, unavailable
    without a figure."""
    if percent is None:
        return "unavailable"
    if percent >= STORAGE_CRITICAL_PERCENT:
        return "critical"
    if percent >= STORAGE_WARNING_PERCENT:
        return "warning"
    return "normal"


def storage_file_used_percent(row: dict) -> float | None:
    """File-count use against the hard file limit (or the soft quota when
    there is no limit); None without figures."""
    count = _number(row.get("file_count"))
    limit = _number(row.get("file_limit"))
    if limit is None:
        limit = _number(row.get("file_quota"))
    if count is None or limit is None or limit <= 0:
        return None
    return count / limit * 100


def storage_pressure_percent(row: dict) -> float | None:
    """Whichever of space and file count is closer to its limit: a volume
    with 10 % of its space used but 96 % of its files is nearly full."""
    space = _number(row.get("used_percent"))
    files = storage_file_used_percent(row)
    if space is None and files is None:
        return None
    return max(space or 0.0, files or 0.0)


def storage_file_count_dominates(row: dict) -> bool:
    files = storage_file_used_percent(row)
    return files is not None and files > (_number(row.get("used_percent")) or 0.0)


def storage_tone(row: dict) -> str:
    """One tone per volume on every screen: over quota (lfs '*', the soft
    quota exceeded with its grace period running) is critical, otherwise the
    75/90 thresholds on storage_pressure_percent."""
    if row.get("over_quota") is True:
        return "critical"
    return usage_tone(storage_pressure_percent(row))


def storage_is_cut_short(row: dict) -> bool:
    """A row the collector could not finish: the round trip ended before
    the volume ("not-collected"), or its filesystem gave no figures in time
    ("no-figures"). Unlike "missing" it says nothing about the volume."""
    return row.get("source") == "unavailable" and row.get("unavailable_reason") in (
        "not-collected",
        "no-figures",
    )


def merge_storage(
    previous: list[dict] | None,
    incoming: list[dict] | None,
    labels_with_figures: set[str],
    carry_cut_rows: bool = False,
) -> list[dict] | None:
    """The storage rows to show after a refresh.

    None (not collected) keeps the previous rows; [] means collected, no
    volumes. An optional volume whose row was cut short ("not-collected") is
    shown only when its label has had real figures, so AIRE's absent Flash
    stays hidden. With carry_cut_rows, a row cut short keeps the previous row
    of its label when that one had figures, so one slow df/lfs does not wipe
    good figures while the next refresh retries.
    """
    if incoming is None:
        return previous
    kept: dict[str, dict] = {}
    if carry_cut_rows:
        for row in previous or []:
            label = _text(row.get("label"))
            if row.get("source") != "unavailable" and label not in kept:
                kept[label] = row
    merged = []
    for row in incoming:
        label = _text(row.get("label"))
        if storage_is_cut_short(row) and label in kept:
            merged.append(kept[label])
            continue
        cut_optional = (
            row.get("optional") is True
            and row.get("source") == "unavailable"
            and row.get("unavailable_reason") == "not-collected"
        )
        if not cut_optional or label in labels_with_figures:
            merged.append(row)
    return merged


def storage_carries_earlier_rows(incoming: list[dict] | None, merged: list[dict] | None) -> bool:
    """True when merged shows a row carried over in place of one this
    refresh cut short, i.e. not every row on screen is from this refresh."""
    if incoming is None or merged is None:
        return False
    cut_labels = {_text(row.get("label")) for row in incoming if storage_is_cut_short(row)}
    return any(_text(row.get("label")) in cut_labels and not storage_is_cut_short(row) for row in merged)


def storage_rows_time(snapshot: dict | None) -> str | None:
    """When the storage rows of a snapshot were collected: the refresh that
    carried them over keeps the older time, so it never passes them off as
    fresh. None when no rows were ever collected."""
    if not snapshot or snapshot.get("storage") is None:
        return None
    stamp = snapshot.get("storage_collected_at")
    return stamp if isinstance(stamp, str) else _text(snapshot.get("collected_at")) or None


class StorageTracker:
    """One cluster's storage bookkeeping: when to ask for storage, and how
    a refresh's rows merge with the ones on screen (the macOS app's
    ClusterSession wantsStorage / noteStorageAttempt / mergeStorage).

    Times are time.monotonic() seconds, passed in so tests control them.
    """

    def __init__(self) -> None:
        # The first refresh (after start or a change of account) collects.
        self.due = True
        self.last_collection: float | None = None
        self.last_miss: float | None = None
        # Labels that have had a row with real figures: an optional volume
        # cut short is shown only for these.
        self.labels_with_figures: set[str] = set()

    def note_cached(self, snapshot: dict | None) -> None:
        """A snapshot read back from the cache: its rows had figures."""
        self.note_rows((snapshot or {}).get("storage"))

    def note_rows(self, rows: list[dict] | None) -> None:
        for row in rows or []:
            if row.get("source") != "unavailable":
                self.labels_with_figures.add(_text(row.get("label")))

    def wants_storage(self, manual: bool, now: float) -> bool:
        """Whether this refresh should collect storage; everything else
        passes skip_storage and keeps the previous rows."""
        if manual or self.due:
            return True
        if self.last_miss is not None and now - self.last_miss < STORAGE_RETRY_AFTER_MISS:
            # An earlier df/quota/lfs is probably still stuck: asking again
            # every 10 s would only add load to a struggling filesystem.
            return False
        if self.last_collection is None:
            return True
        return now - self.last_collection >= STORAGE_REFRESH_INTERVAL

    def note_attempt(self, rows: list[dict] | None, requested: bool, now: float) -> None:
        """A requested section that came back complete is the new baseline.
        One that did not come back, or came back with rows cut short, is a
        miss retried a minute later: a cut section is not a collection, or
        its empty rows would stand for five minutes."""
        if rows is not None and not any(storage_is_cut_short(row) for row in rows):
            self.last_collection = now
            self.last_miss = None
            self.due = False
        elif requested or rows is not None:
            self.last_miss = now
            self.due = False

    def may_carry_cut_rows(self, now: float) -> bool:
        return self.last_collection is not None and now - self.last_collection < STORAGE_CARRY_LIMIT

    def receive(self, previous: dict | None, incoming: dict, requested: bool, now: float) -> dict:
        """incoming (an accepted, validated snapshot) with its storage merged
        into the rows on screen. "storage_collected_at" is set when the rows
        are older than the snapshot (kept, or carried over), so the rows'
        age survives a restart through the cache."""
        rows = incoming.get("storage")
        self.note_attempt(rows, requested, now)
        merged = merge_storage(
            (previous or {}).get("storage"), rows, self.labels_with_figures, self.may_carry_cut_rows(now)
        )
        if rows is not None and not storage_carries_earlier_rows(rows, merged):
            rows_time = incoming.get("collected_at")
        else:
            rows_time = storage_rows_time(previous)
        self.note_rows(rows)
        result = {**incoming, "storage": merged}
        if merged is None or rows_time is None or rows_time == incoming.get("collected_at"):
            result.pop("storage_collected_at", None)
        else:
            result["storage_collected_at"] = rows_time
        return result

    def keep_with_storage(
        self, kept: dict | None, incoming: dict, requested: bool, now: float
    ) -> dict | None:
        """A refresh that reached the login node but whose Slurm sections
        failed (the macOS app's scheduler error, see reached_login_node):
        its storage still counts, as on the Mac (noteStorageAttempt, then
        the storage rows merged into what is shown).

        So the schedule records the attempt like any other: otherwise a
        Slurm outage leaves the cluster "due" and every 10 s refresh runs
        df/quota/lfs on the shared filesystems again, and throws the rows
        away. kept (the snapshot on screen, which stays: its jobs and nodes
        are the last good ones) is returned with this refresh's storage
        merged in and the rows' own collection time.

        Without a kept snapshot there is nowhere to show the rows, so a
        requested section counts only as a miss (asked again a minute
        later): recording it as a collection would leave the first good
        refresh after the outage without storage for five minutes.
        """
        if kept is None:
            self.note_attempt(None, requested, now)
            return None
        merged = self.receive(kept, incoming, requested, now)
        result = {**kept, "storage": merged["storage"]}
        rows_time = storage_rows_time(merged)
        if result["storage"] is None or rows_time is None or rows_time == kept.get("collected_at"):
            result.pop("storage_collected_at", None)
        else:
            # Newer than kept's own time when this refresh collected them.
            result["storage_collected_at"] = rows_time
        return result


def reached_login_node(snapshot: dict | None) -> bool:
    """Whether a refresh's round trip worked: the collector's `remote`
    section answered with the login node's hostname. A snapshot with errors
    that did is a Slurm failure over a healthy connection; one that did not
    is a transport failure (RefreshClassification.classify)."""
    remote = (snapshot or {}).get("remote")
    return isinstance(remote, dict) and bool(_text(remote.get("hostname")).strip())


# ---------------------------------------------------------------------------
# Cluster figures (the macOS app's OverviewClusterStats and TrendPoint)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ClusterFigures:
    counts: JobQueueCounts
    fleet: GPUFleet
    # Cores on available non-GPU nodes only: GPU nodes' CPUs are meant to
    # feed their GPUs, and the GPU partitions usually reject CPU-only jobs,
    # so counting them would overstate where a CPU job can run.
    cpu_idle: int
    cpu_total: int
    cpu_nodes: int
    node_count: int
    # Nodes that accept no new work (NodeState allow-list).
    unavailable_nodes: int


def cluster_figures(snapshot: dict) -> ClusterFigures:
    nodes = [node for node in snapshot.get("nodes") or [] if isinstance(node, dict)]
    cpu_idle = cpu_total = cpu_nodes = unavailable = 0
    for node in nodes:
        available = node_available(node.get("state"))
        if not available:
            unavailable += 1
        total = _whole(node.get("cpu_total"))
        if not available or node_gpu_count(node) != 0 or total is None:
            continue
        idle = _whole(node.get("cpu_idle"))
        if idle is None:
            # One missing idle figure is estimated, not allowed to blank
            # the whole cluster's count.
            idle = max(
                total - (_whole(node.get("cpu_allocated")) or 0) - (_whole(node.get("cpu_other")) or 0), 0
            )
        cpu_total += total
        cpu_idle += idle
        cpu_nodes += 1
    return ClusterFigures(
        counts=JobQueueCounts.from_jobs(snapshot.get("jobs") or []),
        fleet=GPUFleet.from_nodes(nodes),
        cpu_idle=cpu_idle,
        cpu_total=cpu_total,
        cpu_nodes=cpu_nodes,
        node_count=len(nodes),
        unavailable_nodes=unavailable,
    )


def history_point(snapshot: dict) -> dict:
    """One Trends point. gpu_idle is the startable idle GPUs of every model
    together: the one place models are summed, for a per-cluster line (as
    the macOS Trends do); per-model figures stay on the overview."""
    figures = cluster_figures(snapshot)
    fleet = figures.fleet
    return {
        "time": snapshot["collected_at"],
        "gpu_idle": fleet.idle if fleet.total else None,
        # GPUs whose allocation was unknown: gpu_idle then counts only the
        # GPUs known to be idle, a floor rather than a figure.
        "gpu_unknown": fleet.unknown,
        "gpu_total": fleet.total,
        "cpu_idle": figures.cpu_idle if figures.cpu_nodes else None,
        "running": figures.counts.running,
        "pending": figures.counts.pending,
        "held": figures.counts.held,
        "unavailable": figures.unavailable_nodes,
    }


def trend_gpu_value(point: dict) -> float | None:
    """A point's idle GPUs for the chart; None (a gap) when any GPU's
    allocation was unknown, since a line through a floor would read as GPUs
    filling up."""
    idle = _number(point.get("gpu_idle"))
    if idle is None or (_number(point.get("gpu_unknown")) or 0) > 0:
        return None
    return idle


def trend_points(history: Iterable[object]) -> list[tuple[float, float]]:
    """(POSIX time, idle GPUs) for the Trends chart, skipping the gaps."""
    points = []
    for point in history:
        if not isinstance(point, dict):
            continue
        value = trend_gpu_value(point)
        if value is None:
            continue
        try:
            stamp = datetime.fromisoformat(point["time"]).timestamp()
        except (KeyError, TypeError, ValueError, OverflowError, OSError):
            continue
        points.append((stamp, value))
    return points


def history_gpu_text(point: dict) -> str:
    """A point's idle GPUs in words: never a figure it does not have."""
    idle = _whole(point.get("gpu_idle"))
    if idle is None:
        return "—"
    if (_whole(point.get("gpu_unknown")) or 0) > 0:
        return f"at least {idle}" if idle > 0 else "unknown"
    return str(idle)


# ---------------------------------------------------------------------------
# Wording for the overview and the tables
# ---------------------------------------------------------------------------


def card_heading(profile: Profile, fleet: GPUFleet) -> str:
    """ "Calder  /  H200 + L40 GPUs": the models the snapshot reports."""
    models = fleet.model_label
    return f"{profile.name}  /  {models} GPUs" if models else profile.name


def card_summary(figures: ClusterFigures) -> str:
    gpus = figures.fleet.primary_idle_text or "no GPU nodes reported"
    return f"{figures.counts.summary()}   /   {gpus}"


def pool_lines(fleet: GPUFleet) -> list[str]:
    """ "H200: 11 of 24 idle · 5 in use · 8 unavailable", one per model."""
    return [
        f"{pool.label}: {pool.idle_figure} of {pool.total} idle · {pool.capacity_caption}"
        for pool in fleet.pools
    ]


def cpu_summary(figures: ClusterFigures) -> str:
    nodes = f"{figures.unavailable_nodes} of {figures.node_count} nodes accept no work"
    if not figures.cpu_nodes:
        return f"No CPU-only nodes reported · {nodes}"
    return f"{figures.cpu_idle:,} of {figures.cpu_total:,} CPUs idle on CPU nodes · {nodes}"


def _gib(value: float | None) -> str:
    return "—" if value is None else f"{value:,.1f}"


def storage_status(row: dict) -> str:
    if row.get("over_quota") is True:
        return "Over quota"
    return {"critical": "Critical", "warning": "Warning", "normal": "OK"}.get(
        storage_tone(row), "Unavailable"
    )


def storage_row_text(row: dict) -> str:
    """ "Scratch: 120.0 / 1,024.0 GiB · 96% of file limit · CRITICAL"."""
    label = _text(row.get("label")) or "Storage"
    if row.get("source") == "unavailable":
        reason = _text(row.get("unavailable_reason"))
        detail = _UNAVAILABLE_STORAGE_TEXT.get(reason, reason)
        return f"{label}: unavailable" + (f" ({detail})" if detail else "")
    quota = _number(row.get("quota_gb"))
    if quota is None:
        quota = _number(row.get("limit_gb"))
    text = f"{label}: {_gib(_number(row.get('used_gb')))} / {_gib(quota)} GiB"
    if row.get("source") == "df":
        text += " (df: whole filesystem)"
    pressure = storage_pressure_percent(row)
    if pressure is not None:
        text += f" · {pressure:.0f}% {'of file limit' if storage_file_count_dominates(row) else 'used'}"
    status = storage_status(row)
    if status in ("Over quota", "Critical", "Warning"):
        text += f" · {status.upper()}"
    return text


def storage_summary(snapshot: dict) -> str:
    rows = snapshot.get("storage")
    if rows is None:
        return "Storage: not collected yet"
    if not rows:
        return "Storage: no volumes reported"
    stamp = storage_rows_time(snapshot)
    when = f" (collected {local_time_text(stamp, '%H:%M:%S')})" if stamp else ""
    return f"Storage{when}: " + "  ·  ".join(storage_row_text(row) for row in rows)


def node_display_fields(node: dict) -> dict:
    """Extra columns for the Nodes table. "GPUs startable" is what a new job
    could use now (GPUFleet's idle), 0 on nodes that accept no work or whose
    CPUs are full; "?" where the allocation is unknown."""
    state = NodeState.parse(node.get("state"))
    count = node_gpu_count(node)
    fields: dict[str, object] = {
        "state_label": state.description,
        "accepts_work": "Yes" if state.available else "No",
        "gpu_model": (slurm_gpu_model_display_name(node.get("gres")) or "GPU") if count else None,
        "gpu_count": count or None,
        "gpu_unallocated": None,
        "gpu_startable": None,
    }
    if count:
        allocated = known_gpu_allocated(node)
        if allocated is None:
            fields["gpu_unallocated"] = "?"
            fields["gpu_startable"] = "?" if state.available else 0
        else:
            idle = count - min(allocated, count)
            fields["gpu_unallocated"] = idle
            fields["gpu_startable"] = idle if state.available and not cpus_full(node) else 0
    return fields


def partition_display_fields(row: dict) -> dict:
    return {"state_label": NodeState.parse(row.get("state")).description}


def job_display_fields(job: dict) -> dict:
    state = JobState.parse(job.get("state"))
    return {
        "display_id": display_job_id(job),
        "state_label": "Held" if is_held(job) else state.label,
        "jobs": task_multiplicity(job),
    }


def storage_display_fields(row: dict) -> dict:
    pressure = storage_pressure_percent(row)
    return {
        "status": storage_status(row),
        "pressure_percent": round(pressure, 1) if pressure is not None else None,
        "over_quota_text": "Yes" if row.get("over_quota") is True else "No",
        # Read by the table to colour the row; never shown.
        "_tone": storage_tone(row),
    }


JOB_TIME_FIELDS = ("submit_time", "start_time", "end_time")


def job_details_text(job: dict) -> str:
    """The job-details dialog: the job's fields, with Slurm's zone-less
    cluster times converted to this computer's zone and labelled."""
    details = {key: value for key, value in job.items() if not key.startswith("_")}
    for key in JOB_TIME_FIELDS:
        if isinstance(details.get(key), str) and details[key]:
            details[key] = local_time_text(details[key])
    note = "Times are in this computer's time zone."
    return note + "\n" + json.dumps(details, indent=2, ensure_ascii=False)
