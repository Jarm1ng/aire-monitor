"""Explicitly synthetic, offline examples; never used for live monitoring.

The examples carry the cases the overview's rules exist for, so the demo
shows them: an idle GPU stranded on a node whose CPUs are full, a draining
node and a maintenance reservation (no free capacity), a second GPU model on
Calder (its own pool, never summed into the H200 figure), CPU-only nodes
(the CPU figure), a job array's pending remainder (counted per task), and a
volume near its file limit (a storage warning).
"""

from datetime import datetime, timedelta, timezone

from .core import PROFILES, now_iso


def _node(name, partition, state, cpu_total, cpu_allocated, gres="(null)", gpus=None, gpus_allocated=None):
    return {
        "node": name,
        "partitions": [partition],
        "state": state,
        "cpu_allocated": cpu_allocated,
        "cpu_idle": cpu_total - cpu_allocated,
        "cpu_other": 0,
        "cpu_total": cpu_total,
        "memory_mb": 512000,
        "gres": gres,
        "features": "",
        "reason": "none",
        "gpu_total": gpus,
        "gpu_allocated": gpus_allocated,
        "gpu_idle": gpus - gpus_allocated if gpus is not None and gpus_allocated is not None else None,
    }


def _aire_nodes():
    l40s = "gpu:l40s:3(S:0-1)"
    return [
        _node("gpu001", "gpu", "mix", 24, 10, l40s, 3, 1),
        # Every CPU taken: its idle GPU is stranded, not startable.
        _node("gpu002", "gpu", "alloc", 24, 24, l40s, 3, 2),
        _node("gpu003", "gpu", "idle", 24, 0, l40s, 3, 0),
        # Being drained for maintenance: its idle GPUs accept no work.
        _node("gpu004", "gpu", "drng", 24, 8, l40s, 3, 1),
        _node("node001", "nodes", "mix", 168, 120),
        _node("node002", "nodes", "idle", 168, 0),
    ]


def _calder_nodes():
    h200 = "gpu:nvidia_h200:8(S:0-1)"
    return [
        _node("calder-h200-01", "calder-gpu-hopper", "mix-", 128, 64, h200, 8, 5),
        _node("calder-h200-02", "calder-gpu-hopper", "mix", 128, 96, h200, 8, 8),
        # In a maintenance reservation ("$"): idle, but not free.
        _node("calder-h200-03", "calder-gpu-hopper", "idle$", 128, 0, h200, 8, 0),
        # A second GPU model on the same scheduler, drained and not
        # responding, with no allocation reported.
        _node("gpu028", "aire-gpu-lovelace", "drain*", 24, 0, "gpu:nvidia_l40:3", 3, None),
        _node("calder-cpu001", "calder-cpu-turin", "mix", 128, 100),
        # Powered down to save energy ("~"): the scheduler resumes it on
        # demand, so it still counts.
        _node("calder-cpu002", "calder-cpu-turin", "idle~", 128, 0),
    ]


def _job(job_id, state, partition, reason, elapsed="0:00", limit="2:00:00", **extra):
    return {
        "job_id": job_id,
        "name": "example-training" if state == "RUNNING" else "example-evaluation",
        "user": "demo",
        "state": state,
        "partition": partition,
        "elapsed": elapsed,
        "time_limit": limit,
        "nodes": "1",
        "reason_or_node_list": reason,
        **extra,
    }


def _partition(name, state, node_count, gres, cpus):
    return {
        "partition": name,
        "availability": "up",
        "node_count": node_count,
        "state": state,
        "gres": gres,
        "time_limit": "2-00:00:00",
        "cpus_per_node": cpus,
        "memory_mb_per_node": 512000,
        "features": "",
    }


def _storage(label, path, used, quota, files, file_limit, source, quota_type):
    return {
        "label": label,
        "path": path,
        "filesystem": "demo",
        "source": source,
        "used_gb": used,
        "quota_gb": quota,
        "limit_gb": quota * 1.1,
        "available_gb": quota - used,
        "used_percent": round(used / quota * 100, 1),
        "file_count": files,
        "file_quota": None,
        "file_limit": file_limit,
        "over_quota": False,
        "quota_type": quota_type,
        "project_id": None,
        "mount": "",
        "unavailable_reason": None,
        "optional": False,
    }


def snapshots():
    home = _storage("Home", "/users/demo", 18.2, 100, 2450, 100000, "quota", "nfs")
    nodes = {"aire": _aire_nodes(), "calder": _calder_nodes()}
    jobs = {
        "aire": [
            _job(
                "7100",
                "RUNNING",
                "gpu",
                "gpu001",
                elapsed="1:24:03",
                limit="12:00:00",
                work_dir="/users/demo/project",
                stdout_path="/users/demo/project/train.log",
            ),
            _job("8100", "PENDING", "gpu", "(Priority)"),
        ],
        "calder": [
            _job(
                "7101",
                "RUNNING",
                "calder-gpu-hopper",
                "calder-h200-01",
                elapsed="1:24:03",
                limit="12:00:00",
                work_dir="/users/demo/project",
                stdout_path="/users/demo/project/train.log",
            ),
            # One row standing for 8 queued array tasks: 8 pending jobs.
            _job(
                "8101",
                "PENDING",
                "calder-gpu-hopper",
                "(Resources)",
                array_job_id=8101,
                array_pending_tasks="2-9",
                pending_task_count=8,
            ),
        ],
    }
    partitions = {
        "aire": [
            _partition("gpu", "mix", 3, "gpu:l40s:3(S:0-1)", 24),
            _partition("gpu", "drng", 1, "gpu:l40s:3(S:0-1)", 24),
            _partition("nodes", "mix", 2, "(null)", 168),
        ],
        "calder": [
            _partition("calder-gpu-hopper", "mix", 2, "gpu:nvidia_h200:8(S:0-1)", 128),
            _partition("calder-gpu-hopper", "idle$", 1, "gpu:nvidia_h200:8(S:0-1)", 128),
            _partition("aire-gpu-lovelace", "drain*", 1, "gpu:nvidia_l40:3", 24),
            _partition("calder-cpu-turin", "mix", 2, "(null)", 128),
        ],
    }
    storage = {
        "aire": [
            home,
            _storage(
                "Scratch", "/scratch-aire/users/demo", 436, 1000, 18320, 1000000, "lfs quota", "lustre-user"
            ),
        ],
        "calder": [
            home,
            # 12 % of the space but 81 % of the files: a warning.
            _storage(
                "Scratch",
                "/scratch-calder/users/demo",
                120,
                1024,
                812000,
                1000000,
                "lfs quota",
                "lustre-user",
            ),
        ],
    }
    return {
        p.id: {
            "collected_at": now_iso(),
            "cluster": {"id": p.id, "name": p.name},
            "remote": {"host": p.host, "hostname": p.host, "user": "demo", "cwd": "/users/demo"},
            "jobs": jobs[p.id],
            "nodes": nodes[p.id],
            "partitions": partitions[p.id],
            "storage": storage[p.id],
            "errors": [],
            "warnings": [],
        }
        for p in PROFILES
    }


def history(index):
    """An hour of plausible points: AIRE has 12 L40S GPUs, Calder 27 GPUs."""
    now = datetime.now(timezone.utc)
    pool = (6, 8)[index]
    return [
        {
            "time": (now - timedelta(minutes=60 - i)).isoformat(),
            "gpu_idle": (i // 8 + index * 3) % pool + 1,
            "gpu_unknown": 0,
            "gpu_total": (12, 27)[index],
            "running": 1,
            "pending": (1, 8)[index] + i % 3,
            "held": 0,
            "cpu_idle": (200, 140)[index] + i % 20,
            "unavailable": 1,
        }
        for i in range(60)
    ]
