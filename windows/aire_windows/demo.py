"""Explicitly synthetic, offline examples; never used for live monitoring."""

from datetime import datetime, timedelta, timezone

from .core import PROFILES, now_iso


def snapshots():
    result = {}
    for index, p in enumerate(PROFILES):
        count = 3 if index == 0 else 8
        nodes = [
            {
                "node": f"{p.id}-gpu-0{i + 1}",
                "partitions": ["gpu" if index == 0 else "calder-gpu-hopper"],
                "state": "mix" if i == 0 else "idle",
                "cpu_allocated": 16 if i == 0 else 0,
                "cpu_idle": 32 if i == 0 else 48,
                "cpu_total": 48,
                "memory_mb": 512000,
                "gpu_total": count,
                "gpu_allocated": 1 if i == 0 else 0,
                "gpu_idle": count - 1 if i == 0 else count,
                "reason": "none",
                "gres": f"gpu:{p.gpu}:{count}",
            }
            for i in range(3)
        ]
        result[p.id] = {
            "collected_at": now_iso(),
            "cluster": {"id": p.id, "name": p.name},
            "remote": {"host": p.host, "hostname": p.host, "user": "demo", "cwd": "/users/demo"},
            "jobs": [
                {
                    "job_id": str(7100 + index),
                    "name": "example-training",
                    "state": "RUNNING",
                    "partition": nodes[0]["partitions"][0],
                    "elapsed": "1:24:03",
                    "time_limit": "12:00:00",
                    "nodes": "1",
                    "reason_or_node_list": nodes[0]["node"],
                    "work_dir": "/users/demo/project",
                    "stdout_path": "/users/demo/project/train.log",
                },
                {
                    "job_id": str(8100 + index),
                    "name": "example-evaluation",
                    "state": "PENDING",
                    "partition": nodes[0]["partitions"][0],
                    "elapsed": "0:00",
                    "time_limit": "2:00:00",
                    "nodes": "1",
                    "reason_or_node_list": "(Priority)",
                },
            ],
            "nodes": nodes,
            "partitions": [
                {
                    "partition": nodes[0]["partitions"][0],
                    "availability": "up",
                    "node_count": 3,
                    "state": "mix",
                    "gres": f"gpu:{p.gpu}:{count}",
                    "time_limit": "2-00:00:00",
                    "cpus_per_node": 48,
                    "memory_mb_per_node": 512000,
                }
            ],
            "storage": [
                {
                    "label": "Home",
                    "path": "/users/demo",
                    "used_gb": 18.2,
                    "quota_gb": 100,
                    "limit_gb": 110,
                    "used_percent": 18.2,
                    "source": "quota",
                    "quota_type": "nfs",
                    "file_count": 2450,
                    "file_quota": 100000,
                },
                {
                    "label": "Scratch",
                    "path": f"/scratch-{p.id}/users/demo",
                    "used_gb": 436,
                    "quota_gb": 1000,
                    "limit_gb": 1100,
                    "used_percent": 43.6,
                    "source": "lfs quota",
                    "quota_type": "lustre-user",
                    "file_count": 18320,
                    "file_quota": 1000000,
                },
            ],
            "errors": [],
            "warnings": [],
        }
    return result


def history(index):
    now = datetime.now(timezone.utc)
    return [
        {
            "time": (now - timedelta(minutes=60 - i)).isoformat(),
            "gpu_idle": (i // 8 + index * 7) % 12 + 2,
            "running": 1,
            "pending": 2 + i % 3,
            "cpu_idle": 96 + i % 20,
            "unavailable": 0,
        }
        for i in range(60)
    ]
