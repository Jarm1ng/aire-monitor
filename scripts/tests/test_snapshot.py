#!/usr/bin/env python3
"""Unit tests for scripts/hpc_snapshot.py, the Slurm snapshot collector.

Run (from anywhere):
    python3 scripts/tests/test_snapshot.py                 all tests
    python3 scripts/tests/test_snapshot.py -k Array        a subset (unittest -k)
    python3 scripts/hpc_snapshot.py --self-test            the same, via the collector
    python3 scripts/tests/test_snapshot.py --write-fixture regenerate the contract fixtures

The Swift test target runs this file too (CollectorContractTests.swift), so
`Tests/AIREMonitorAppTests/run_tests.sh` covers the collector.

Nothing here runs ssh or touches ~/.ssh. Three layers are covered:
  * the parsers, against canned Slurm/df/quota/lfs output modelled on what
    AIRE and Calder really print (usernames and paths anonymised);
  * the generated remote shell script, executed by the LOCAL /bin/sh (and
    dash, bash, zsh where installed) against stub squeue/sinfo/scontrol/df/
    quota/lfs/timeout/ps commands in a temp directory;
  * collect_snapshot end to end, with a stub in place of the ssh client.

The contract fixtures under Tests/Fixtures/ are generated from the canned
round trip below (CANNED_*), and test_fixture_is_current fails when the
collector's output drifts from them, so a schema change can never reach the
app without the Swift contract test decoding it first.
"""

from __future__ import annotations

import argparse
import contextlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from dataclasses import asdict
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
PROJECT_ROOT = os.path.dirname(SCRIPTS)
COLLECTOR_PATH = os.path.join(SCRIPTS, "hpc_snapshot.py")
FIXTURE_DIR = os.path.join(PROJECT_ROOT, "Tests", "Fixtures")
SNAPSHOT_FIXTURE = os.path.join(FIXTURE_DIR, "collector_snapshot.json")
CONTRACT_FIXTURE = os.path.join(FIXTURE_DIR, "collector_contract.json")


def load_collector():
    """Import scripts/hpc_snapshot.py by path (works under `python3 -I`)."""
    # Never leave a scripts/__pycache__ behind in the checkout.
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("hpc_snapshot", COLLECTOR_PATH)
    module = importlib.util.module_from_spec(spec)
    # dataclasses resolve string annotations through sys.modules.
    sys.modules["hpc_snapshot"] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


hs = load_collector()


# ---------------------------------------------------------------------------
# Canned data: one Calder refresh, as the remote side would print it
# ---------------------------------------------------------------------------

USER = "abcd1234"
OTHER_USER = "efgh5678"

# The collector's own constants: the Windows and Linux apps build their
# cluster profiles from them, so they must stay public and parse.
AIRE_SPEC = hs.AIRE_SPEC
CALDER_SPEC = hs.CALDER_SPEC

# The fixture's reference time: running jobs' elapsed time is computed
# against it, and the canned epochs are relative to it.
FIXTURE_NOW = datetime(2026, 10, 12, 12, 0, 0, tzinfo=timezone.utc)
NOW_EPOCH = int(FIXTURE_NOW.timestamp())


def _num(value, *, is_set=True, infinite=False):
    """Slurm data_parser v0.0.40+ number wrapper."""
    return {"set": is_set, "infinite": infinite, "number": value}


def _job_record(**overrides):
    """A squeue --json job with the fields Slurm 23.11/24.05 always prints
    (a representative subset, including a job_resources block the collector
    must ignore)."""
    record = {
        "account": "arc-users",
        "array_job_id": _num(0),
        "array_task_id": _num(0, is_set=False),
        "array_max_tasks": _num(0),
        "array_task_string": "",
        "batch_host": "",
        "command": "",
        "cpus": _num(12),
        "current_working_directory": f"/users/{USER}/runs",
        "end_time": _num(0),
        "job_resources": {},
        "job_state": ["PENDING"],
        "name": "",
        "node_count": _num(1),
        "nodes": "",
        "partition": "calder-gpu-hopper",
        "standard_error": "",
        "standard_output": "",
        "start_time": _num(0),
        "state_reason": "None",
        "submit_time": _num(NOW_EPOCH - 86400),
        "tasks": _num(1),
        "time_limit": _num(1440),
        "tres_alloc_str": "",
        "tres_per_node": "gres/gpu:nvidia_h200:1",
        "tres_req_str": "cpu=12,mem=180G,node=1,billing=12,gres/gpu=1",
        "user_name": USER,
    }
    record.update(overrides)
    return record


def _running_resources(node):
    return {
        "nodes": {
            "count": 1, "select_type": ["AVAILABLE"], "list": node, "whole": False,
            "allocation": [{"index": 0, "name": node, "cpus": {"count": 12, "used": 0},
                            "memory": {"used": 0, "allocated": 184320},
                            "sockets": [{"index": 0, "cores": [{"index": 0, "status": ["ALLOCATED"]}]}]}],
        },
        "cpus": 12,
        "threads_per_core": _num(1),
    }


CANNED_JOBS = [
    # An ordinary running GPU job.
    _job_record(
        job_id=40188, name="train-h200", job_state=["RUNNING"],
        nodes="calder-h200-01", batch_host="calder-h200-01",
        command=f"/users/{USER}/runs/train.sh --lr=0.1", job_resources=_running_resources("calder-h200-01"),
        start_time=_num(NOW_EPOCH - (3 * 3600 + 25 * 60 + 10)), end_time=_num(NOW_EPOCH + 86400),
        time_limit=_num(2880), submit_time=_num(NOW_EPOCH - 4 * 3600),
        standard_output=f"/users/{USER}/runs/logs/train-h200_40188.out",
        standard_error=f"/users/{USER}/runs/logs/train-h200_40188.err",
        tres_alloc_str="cpu=12,mem=180G,node=1,billing=12,gres/gpu=1,gres/gpu:nvidia_h200=1",
    ),
    # Two running tasks of array 35796 (their own job ids are 35797/35798).
    _job_record(
        job_id=35797, name="sweep", job_state=["RUNNING"], array_job_id=_num(35796),
        array_task_id=_num(1), array_max_tasks=_num(4), nodes="calder-h200-03",
        batch_host="calder-h200-03", start_time=_num(NOW_EPOCH - 1800),
        command=f"/users/{USER}/runs/sweep.sh", job_resources=_running_resources("calder-h200-03"),
        standard_output=f"/users/{USER}/runs/logs/sweep_35796_1.out",
        tres_alloc_str="cpu=12,mem=180G,node=1,billing=12,gres/gpu=1,gres/gpu:nvidia_h200=1",
    ),
    _job_record(
        job_id=35798, name="sweep", job_state=["RUNNING"], array_job_id=_num(35796),
        array_task_id=_num(2), array_max_tasks=_num(4), nodes="calder-h200-03",
        batch_host="calder-h200-03", start_time=_num(NOW_EPOCH - 600),
        command=f"/users/{USER}/runs/sweep.sh", job_resources=_running_resources("calder-h200-03"),
        standard_output=f"/users/{USER}/runs/logs/sweep_35796_2.out",
        tres_alloc_str="cpu=12,mem=180G,node=1,billing=12,gres/gpu=1,gres/gpu:nvidia_h200=1",
    ),
    # The array's pending remainder: ONE meta-record for tasks 3-58,
    # throttled to 4 at a time. Its output path carries Slurm's NO_VAL task
    # id because no task has been chosen yet.
    _job_record(
        job_id=35796, name="sweep", array_job_id=_num(35796),
        array_task_id=_num(0, is_set=False), array_max_tasks=_num(4),
        array_task_string="3-58%4", state_reason="JobArrayTaskLimit",
        command=f"/users/{USER}/runs/sweep.sh",
        standard_output=f"/users/{USER}/runs/logs/sweep_35796_4294967294.out",
    ),
    # A held ordinary job.
    _job_record(
        job_id=9918, name="c3-c09-dump", state_reason="JobHeldUser", time_limit=_num(720),
        tres_req_str="cpu=8,mem=64G,node=1,billing=8,gres/gpu=1",
    ),
    # Someone else's job: older Slurm ignores -u with --json, so the
    # collector filters on user_name itself.
    _job_record(job_id=41000, name="not-mine", user_name=OTHER_USER, state_reason="Priority"),
]

CANNED_JOBS_PAYLOAD = {
    "jobs": CANNED_JOBS,
    "last_backfill": _num(NOW_EPOCH - 30),
    "last_update": _num(NOW_EPOCH - 2),
    "meta": {"plugin": {"type": "openapi/slurmctld", "name": "Slurm OpenAPI slurmctld",
                        "data_parser": "data_parser/v0.0.40", "accounting_storage": "accounting_storage/slurmdbd"},
             "client": {"source": "/dev/pts/0", "user": USER, "group": "arc-users"},
             "command": ["squeue", "-u", USER, "--json"],
             "slurm": {"version": {"major": "24", "micro": "5", "minor": "05"}, "release": "24.05.5",
                       "cluster": "calder"}},
    "errors": [],
    "warnings": [],
}

# squeue pretty-prints; the remote script strips every line's indentation.
CANNED_JOBS_JSON_PRETTY = json.dumps(CANNED_JOBS_PAYLOAD, indent=2)
CANNED_JOBS_JSON = "\n".join(line.lstrip() for line in CANNED_JOBS_JSON_PRETTY.splitlines())

# The same queue as the pipe-format fallback prints it (squeue %i shows the
# remainder as '35796_[3-58%4]'), and the scontrol records it joins.
CANNED_JOBS_PIPE = "\n".join([
    f"40188|calder-gpu-hopper|train-h200|{USER}|RUNNING|3:25:10|2-00:00:00|1|calder-h200-01",
    f"35796_1|calder-gpu-hopper|sweep|{USER}|RUNNING|30:00|1-00:00:00|1|calder-h200-03",
    f"35796_2|calder-gpu-hopper|sweep|{USER}|RUNNING|10:00|1-00:00:00|1|calder-h200-03",
    f"35796_[3-58%4]|calder-gpu-hopper|sweep|{USER}|PENDING|0:00|1-00:00:00|1|(JobArrayTaskLimit)",
    f"9918|calder-gpu-hopper|c3-c09-dump|{USER}|PENDING|0:00|12:00:00|1|(JobHeldUser)",
])
CANNED_JOB_DETAILS = "\n".join([
    f"JobId=40188 JobName=train-h200 UserId={USER}(1234) JobState=RUNNING Reason=None "
    "SubmitTime=2026-10-12T08:00:00 StartTime=2026-10-12T08:34:50 EndTime=2026-10-13T12:00:00 "
    "Partition=calder-gpu-hopper NodeList=calder-h200-01 BatchHost=calder-h200-01 NumNodes=1 NumCPUs=12 "
    "NumTasks=1 ReqTRES=cpu=12,mem=180G,node=1,billing=12,gres/gpu=1 "
    "AllocTRES=cpu=12,mem=180G,node=1,billing=12,gres/gpu=1,gres/gpu:nvidia_h200=1 "
    f"Command=/users/{USER}/runs/train.sh --lr=0.1 WorkDir=/users/{USER}/runs "
    f"StdErr=/users/{USER}/runs/logs/train-h200_40188.err StdOut=/users/{USER}/runs/logs/train-h200_40188.out "
    "TresPerNode=gres/gpu:nvidia_h200:1",
    f"JobId=35797 ArrayJobId=35796 ArrayTaskId=1 ArrayTaskThrottle=4 JobName=sweep UserId={USER}(1234) "
    "JobState=RUNNING NodeList=calder-h200-03 NumCPUs=12 ReqTRES=cpu=12,mem=180G,node=1,billing=12,gres/gpu=1 "
    f"Command=/users/{USER}/runs/sweep.sh WorkDir=/users/{USER}/runs TresPerNode=gres/gpu:nvidia_h200:1",
    f"JobId=35798 ArrayJobId=35796 ArrayTaskId=2 ArrayTaskThrottle=4 JobName=sweep UserId={USER}(1234) "
    "JobState=RUNNING NodeList=calder-h200-03 NumCPUs=12 ReqTRES=cpu=12,mem=180G,node=1,billing=12,gres/gpu=1 "
    f"Command=/users/{USER}/runs/sweep.sh WorkDir=/users/{USER}/runs TresPerNode=gres/gpu:nvidia_h200:1",
    f"JobId=35796 ArrayJobId=35796 ArrayTaskId=3-58%4 ArrayTaskThrottle=4 JobName=sweep UserId={USER}(1234) "
    "JobState=PENDING Reason=JobArrayTaskLimit NumCPUs=12 ReqTRES=cpu=12,mem=180G,node=1,billing=12,gres/gpu=1 "
    f"Command=/users/{USER}/runs/sweep.sh WorkDir=/users/{USER}/runs "
    f"StdOut=/users/{USER}/runs/logs/sweep_35796_4294967294.out TresPerNode=gres/gpu:nvidia_h200:1",
    f"JobId=9918 JobName=c3-c09-dump UserId={USER}(1234) JobState=PENDING Reason=JobHeldUser NumCPUs=8 "
    f"ReqTRES=cpu=8,mem=64G,node=1,billing=8,gres/gpu=1 WorkDir=/users/{USER}/runs TresPerNode=gres/gpu:nvidia_h200:1",
])

CANNED_PARTITIONS = "\n".join([
    "calder-cpu-turin*|up|98|mix|(null)|128|772480|(null)|2-00:00:00",
    "calder-gpu-hopper|up|7|mix|gpu:nvidia_h200:8(S:0-1)|128|1546664|(null)|2-00:00:00",
    "calder-gpu-lovelace|up|2|mix|gpu:l40s:4(S:0,2),mps:400|64|512000|(null)|1-00:00:00",
])
NHC_REASON = "NHC: check_cmd_output: 'nvidia-smi -L | wc -l' returned 7"
CANNED_NODES = "\n".join([
    "calder-h200-01|calder-gpu-hopper|mix|64/64/0/128|1546664|gpu:nvidia_h200:8(S:0-1)|(null)|none",
    "calder-h200-02|calder-gpu-hopper|idle|0/128/0/128|1546664|gpu:nvidia_h200:8(S:0-1)|(null)|none",
    f"calder-h200-05|calder-gpu-hopper|drain|0/0/128/128|1546664|gpu:nvidia_h200:8(S:0-1)|(null)|{NHC_REASON}",
    "calder-l40-01|calder-gpu-lovelace|mix|16/48/0/64|512000|gpu:l40s:4(S:0,2),mps:400|(null)|none",
    "calder-cpu001|calder-cpu-turin|mix|100/28/0/128|772480|(null)|(null)|none",
    "calder-cpu001|nodes|mix|100/28/0/128|772480|(null)|(null)|none",
])
CANNED_NODE_DETAILS = "\n".join([
    "NodeName=calder-h200-01 Arch=x86_64 CPUAlloc=64 CPUTot=128 CPULoad=63.20 RealMemory=1546664 "
    "AllocMem=983040 FreeMem=401234 State=MIXED Partitions=calder-gpu-hopper "
    "CfgTRES=cpu=128,mem=1546664M,billing=128,gres/gpu=8,gres/gpu:nvidia_h200=8 "
    "AllocTRES=cpu=64,mem=960G,gres/gpu=5,gres/gpu:nvidia_h200=5 CurrentWatts=2310 AveWatts=1980",
    # Idle: AllocTRES lists nothing at all, which means 0 GPUs in use.
    "NodeName=calder-h200-02 Arch=x86_64 CPUAlloc=0 CPUTot=128 CPULoad=0.04 RealMemory=1546664 "
    "AllocMem=0 FreeMem=1501000 State=IDLE Partitions=calder-gpu-hopper "
    "CfgTRES=cpu=128,mem=1546664M,billing=128,gres/gpu=8,gres/gpu:nvidia_h200=8 AllocTRES= "
    "CurrentWatts=640 AveWatts=655",
    "NodeName=calder-h200-05 Arch=x86_64 CPUAlloc=0 CPUTot=128 CPULoad=0.01 RealMemory=1546664 "
    "AllocMem=0 FreeMem=1500000 State=IDLE+DRAIN Partitions=calder-gpu-hopper "
    "CfgTRES=cpu=128,mem=1546664M,billing=128,gres/gpu=8,gres/gpu:nvidia_h200=8 AllocTRES= "
    f"CurrentWatts=0 AveWatts=0 Reason={NHC_REASON} [root@2026-10-11T22:14:03]",
    # GPUs not accounted as TRES on this node: allocation is unknowable.
    "NodeName=calder-l40-01 Arch=x86_64 CPUAlloc=16 CPUTot=64 CPULoad=15.80 RealMemory=512000 "
    "AllocMem=131072 FreeMem=350000 State=MIXED Partitions=calder-gpu-lovelace "
    "CfgTRES=cpu=64,mem=512000M,billing=64 AllocTRES=cpu=16,mem=128G CurrentWatts=0 AveWatts=0",
    "NodeName=calder-cpu001 Arch=x86_64 CPUAlloc=100 CPUTot=128 CPULoad=99.12 RealMemory=772480 "
    "AllocMem=614400 FreeMem=120000 State=MIXED Partitions=calder-cpu-turin,nodes "
    "CfgTRES=cpu=128,mem=772480M,billing=128 AllocTRES=cpu=100,mem=600G CurrentWatts=0 AveWatts=0",
])
CANNED_STORAGE = "\n".join([
    "__HPC-VOLUME:0__",
    "__HPC-PATH__",
    f"/users/{USER}",
    "__HPC-DF__",
    "Filesystem              1024-blocks        Used   Available Capacity Mounted on",
    "10.10.0.15:/export/users 104857600000 70000000000 34857600000      67% /users",
    "__HPC-MOUNT__",
    "/users",
    "__HPC-QUOTA__",
    f"Disk quotas for user {USER} (uid 1234):",
    "     Filesystem   space   quota   limit   grace   files   quota   limit   grace",
    "10.10.0.15:/export/users  45455M  66560M  66560M            294k  1500k  1500k",
    "__HPC-VOLUME-END:0__",
    "__HPC-VOLUME:1__",
    "__HPC-PATH__",
    f"/scratch-calder/users/{USER}",
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
    f"/flash-calder/users/{USER}",
    f"/flash-calder/{USER}",
    "__HPC-VOLUME-END:2__",
])
CANNED_REMOTE = f"calder-login-1.arc.leeds.ac.uk|{USER}|/users/{USER}|2026-10-12T13:00:00+01:00"

# Remote clock for the TIME markers: (section, seconds after the start).
CANNED_CLOCK_START = 1760270400.0
CANNED_STEPS = {
    "prelude": 0.012, "remote": 0.030, "partitions": 0.085, "nodes": 0.140, "jobs_json": 0.357,
    "jobs": 0.050, "node_details": 0.120, "job_details": 0.210, "storage": 0.450,
}


def round_trip_output(
    *,
    jobs_json=CANNED_JOBS_JSON,
    jobs_json_status=0,
    pipe_jobs=None,
    job_details=CANNED_JOB_DETAILS,
    nodes=CANNED_NODES,
    node_details=CANNED_NODE_DETAILS,
    node_details_status=0,
    storage=CANNED_STORAGE,
    include_storage=True,
    remote=CANNED_REMOTE,
):
    """The remote script's stdout for one refresh, in the real section
    order with STATUS and TIME markers. pipe_jobs adds the fallback 'jobs'
    and 'job_details' sections, as the script does when the JSON failed."""
    clock = [CANNED_CLOCK_START]
    lines = [f"=====HPC-TIME:start:{clock[0]:.9f}====="]

    def tick(name):
        clock[0] += CANNED_STEPS[name]
        lines.append(f"=====HPC-TIME:{name}:{clock[0]:.9f}=====")

    def section(name, body, status=0):
        lines.append(f"=====HPC-SECTION:{name}=====")
        if body:
            lines.append(body)
        lines.append(f"=====HPC-STATUS:{name}:{status}=====")
        tick(name)

    tick("prelude")
    section("remote", remote)
    section("partitions", CANNED_PARTITIONS)
    section("nodes", nodes)
    section("jobs_json", jobs_json if jobs_json_status == 0 else "", jobs_json_status)
    if pipe_jobs is not None:
        section("jobs", pipe_jobs)
    section("node_details", node_details, node_details_status)
    if pipe_jobs is not None:
        section("job_details", job_details)
    if include_storage:
        section("storage", storage)
    return "\n".join(lines) + "\n"


def calder_config(**overrides):
    values = dict(host="calder", username=USER, hostname="calder.leeds.ac.uk", use_jump_host=False,
                  jump_hostname=None, control_path=None, jump_control_path=None, timeout=5)
    values.update(overrides)
    return hs.SSHConfig(**values)


CALDER = hs.ClusterInfo("calder", "Calder")


def calder_volumes():
    volumes, error = hs.parse_storage_spec(CALDER_SPEC)
    assert error is None, error
    return volumes


def assemble(output, *, error=None, timed_out=False, **kwargs):
    kwargs.setdefault("now", FIXTURE_NOW)
    return hs.assemble_snapshot(calder_config(), CALDER, calder_volumes(), "now", output, error, timed_out,
                                **kwargs)


def _tzset():
    """time.tzset() where it exists: Windows has none, and there the
    collector reads only HPC_CLUSTER_TZ, never the process zone."""
    if hasattr(time, "tzset"):
        time.tzset()


@contextlib.contextmanager
def pinned_timezone(name="UTC"):
    """Epoch -> cluster time conversions depend on the zone; the fixture must
    not. Pins both the process TZ and the collector's cluster zone."""
    previous = {key: os.environ.get(key) for key in ("TZ", "HPC_CLUSTER_TZ")}
    os.environ["TZ"] = name
    os.environ["HPC_CLUSTER_TZ"] = name
    _tzset()
    try:
        yield
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        _tzset()


# ---------------------------------------------------------------------------
# Contract fixtures
# ---------------------------------------------------------------------------


def build_snapshot_fixture():
    """The JSON the collector prints for the canned Calder refresh."""
    with pinned_timezone("UTC"):
        snapshot = hs.assemble_snapshot(
            calder_config(), CALDER, calder_volumes(),
            "2026-10-12T12:00:01.250000+00:00", round_trip_output(), None, False,
            now=FIXTURE_NOW,
            started_at="2026-10-12T12:00:00+00:00",
            duration_ms=1250,
            local_timings={"probe": 8, "round_trip": 1240},
        )
        return hs.snapshot_payload(snapshot)


def build_contract_constants():
    """Values the Swift side must agree with (CollectorContractTests)."""
    return {
        "schema_version": hs.SCHEMA_VERSION,
        "default_timeout": hs.DEFAULT_TIMEOUT,
        "default_jump_hostname": hs.DEFAULT_JUMP_HOSTNAME,
        "known_clusters": {
            cluster_id: {"name": hs.KNOWN_CLUSTER_NAMES[cluster_id],
                         "hostname": hs.KNOWN_CLUSTER_HOSTNAMES.get(cluster_id)}
            for cluster_id in hs.KNOWN_CLUSTER_NAMES
        },
        "storage_unavailable_reasons": ["missing", "no-figures", "not-collected"],
    }


def fixture_text(payload):
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def write_fixtures():
    os.makedirs(FIXTURE_DIR, exist_ok=True)
    for path, payload in ((SNAPSHOT_FIXTURE, build_snapshot_fixture()),
                          (CONTRACT_FIXTURE, build_contract_constants())):
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(fixture_text(payload))
        print(f"wrote {os.path.relpath(path, PROJECT_ROOT)}")


# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------


class GresAndTRESTests(unittest.TestCase):
    def test_gres_totals(self):
        for gres, expected in (
            ("gpu:l40s:3(S:0-1)", 3),
            ("gpu:l40s:3", 3),
            ("gpu:nvidia_h200:8(S:0-1)", 8),
            ("gpu:4(IDX:0-3)", 4),
            ("gpu:a100:4,mps:400", 4),
            ("gpu", 1),
            ("(null)", None),
            ("", None),
            # Commas inside socket/index lists (the old parser split first
            # and read '...(S:0' -> 0 GPUs).
            ("gpu:a100:4(S:0,2)", 4),
            ("gpu:4(IDX:0,2-3)", 4),
            ("gpu:a100:4(S:0,2),mps:400", 4),
            ("gpu:l40s:4(S:0,2),gpu:a100:2(S:1)", 6),
            ("gpumem:40G", None),
        ):
            with self.subTest(gres=gres):
                self.assertEqual(hs.parse_gres_gpu_total(gres), expected)

    def test_tres_gpu_count(self):
        for tres, expected in (
            ("cpu=128,mem=1546664M,billing=128,gres/gpu=8,gres/gpu:nvidia_h200=8", 8),
            ("cpu=64,gres/gpu:l40s=2", 2),
            ("cpu=64,gres/gpu:l40s=2,gres/gpu:a100=1", 3),
            ("cpu=64,mem=512000M", None),
            ("", None),
            ("cpu=8,gres/gpumem=40G", None),
            ("gres/gpu=0", 0),
        ):
            with self.subTest(tres=tres):
                self.assertEqual(hs.parse_tres_gpu_count(tres), expected)

    def test_node_gpu_figures(self):
        gpu_cfg = "cpu=24,mem=256656M,gres/gpu=3,gres/gpu:l40s=3"
        # Empty AllocTRES on a node that accounts GPUs: 0 in use, all idle.
        self.assertEqual(hs.node_gpu_figures({"CfgTRES": gpu_cfg, "AllocTRES": ""}, "gpu:l40s:3"), (3, 0, 3))
        self.assertEqual(hs.node_gpu_figures({"CfgTRES": gpu_cfg, "AllocTRES": "cpu=8,gres/gpu=2"}, "gpu:l40s:3"),
                         (3, 2, 1))
        # No details record: allocation unknown, never assumed idle.
        self.assertEqual(hs.node_gpu_figures(None, "gpu:l40s:3(S:0-1)"), (3, None, None))
        # A site without GPU TRES: AllocTRES can never list GPUs, so 0 would be a lie.
        self.assertEqual(hs.node_gpu_figures({"CfgTRES": "cpu=24", "AllocTRES": "cpu=8"}, "gpu:l40s:3"),
                         (3, None, None))
        # Allocation can never exceed what is idle-able.
        self.assertEqual(hs.node_gpu_figures({"CfgTRES": gpu_cfg, "AllocTRES": "gres/gpu=5"}, ""), (3, 5, 0))
        self.assertEqual(hs.node_gpu_figures(None, "(null)"), (None, None, None))


class KeyValueTests(unittest.TestCase):
    def test_command_arguments_are_not_keys(self):
        kv = hs.parse_key_values("JobId=123 Command=/home/u/run.sh --lr=0.1 --batch=32 WorkDir=/home/u")
        self.assertEqual(kv.get("Command"), "/home/u/run.sh --lr=0.1 --batch=32")
        self.assertEqual(kv.get("WorkDir"), "/home/u")

    def test_lowercase_assignments_stay_in_the_value(self):
        # scontrol keys are CamelCase; 'lr=0.1' is an argument of Command.
        kv = hs.parse_key_values("JobId=123 Command=run.sh lr=0.1 batch=32 WorkDir=/home/u")
        self.assertEqual(kv.get("Command"), "run.sh lr=0.1 batch=32")
        self.assertNotIn("lr", kv)

    def test_node_reason_keeps_brackets(self):
        details = hs.parse_node_details(CANNED_NODE_DETAILS)
        self.assertEqual(details["calder-h200-05"]["Reason"], f"{NHC_REASON} [root@2026-10-11T22:14:03]")
        self.assertEqual(details["calder-h200-02"]["AllocTRES"], "")


class SizeAndCountTests(unittest.TestCase):
    def test_sizes(self):
        self.assertEqual(hs.parse_size_to_gb("12.5G*"), 12.5)
        self.assertEqual(hs.parse_size_to_gb("12.5G+"), 12.5)
        self.assertEqual(hs.parse_size_to_gb("1T"), 1024)
        self.assertEqual(hs.parse_size_to_gb("1073741824"), 1024)
        self.assertEqual(hs.parse_size_to_gb("4k"), 4 / 1024 / 1024)

    def test_counts(self):
        self.assertEqual(hs.parse_count("100k*"), 100_000)
        self.assertIsNone(hs.parse_count("-"))
        self.assertEqual(hs.parse_count("0"), 0)

    def test_durations(self):
        self.assertEqual(hs.format_duration(90061), "1-01:01:01")
        self.assertEqual(hs.format_duration(125), "2:05")
        self.assertEqual(hs.format_duration(3600), "1:00:00")


class RemoteInfoTests(unittest.TestCase):
    def test_plain(self):
        info = hs.parse_remote_info("calder.leeds.ac.uk", CANNED_REMOTE)
        self.assertEqual((info.hostname, info.user, info.cwd, info.remote_time),
                         ("calder-login-1.arc.leeds.ac.uk", USER, f"/users/{USER}", "2026-10-12T13:00:00+01:00"))

    def test_pipe_in_working_directory(self):
        info = hs.parse_remote_info("h", "login1|u|/home/u/a|b|2026-10-12T13:00:00+01:00")
        self.assertEqual((info.user, info.cwd, info.remote_time), ("u", "/home/u/a|b", "2026-10-12T13:00:00+01:00"))

    def test_malformed(self):
        self.assertEqual(hs.parse_remote_info("h", "only|two").user, "")
        self.assertEqual(hs.parse_remote_info("h", "").host, "h")


class PartitionAndNodeTests(unittest.TestCase):
    def test_partitions(self):
        partitions = hs.parse_partitions(
            "calder-cpu-turin*|up|98|mix|(null)|128|772480|(null)|2-00:00:00\n"
            "calder-gpu-hopper|up|7|mix|gpu:nvidia_h200:8(S:0-1)|128|1546664|(null)|2-00:00:00\n"
            "nodes|up|52|mix|(null)|168|768000|(null)|infinite\n"
            "legacy|up|1|idle|(null)|8|1000|none\n"
        )
        self.assertEqual(len(partitions), 4)
        cpu, gpu, aire_nodes, legacy = partitions
        self.assertEqual(cpu.partition, "calder-cpu-turin")
        self.assertEqual((cpu.time_limit, gpu.time_limit), ("2-00:00:00", "2-00:00:00"))
        self.assertEqual(aire_nodes.time_limit, "infinite")
        self.assertEqual((hs.parse_gres_gpu_total(gpu.gres), gpu.memory_mb_per_node), (8, 1546664))
        self.assertIsNone(legacy.time_limit)
        self.assertEqual(legacy.features, "none")

    def test_unreadable_lines_are_reported(self):
        rejects = []
        self.assertEqual(hs.parse_partitions("garbage-without-separators", rejects), [])
        self.assertEqual(rejects, ["garbage-without-separators"])

    def test_gres_fallback_without_details(self):
        nodes = hs.parse_nodes("gpu001|gpu|mix|8/40/0/48|512000|gpu:l40s:3(S:0-1)|l40s|none")
        self.assertEqual(len(nodes), 1)
        self.assertEqual((nodes[0].gpu_total, nodes[0].gpu_allocated, nodes[0].gpu_idle), (3, None, None))

    def test_h200_reason(self):
        nodes = hs.parse_nodes("calder-h200-05|calder-gpu-hopper|idle+drain|0/128/0/128|1546664|"
                               "gpu:nvidia_h200:8(S:0-1)|(null)|Kill task failed")
        self.assertEqual((nodes[0].gpu_total, nodes[0].reason), (8, "Kill task failed"))

    def test_pipe_in_reason_keeps_the_node(self):
        line = f"gpu014|gpu|drain|0/24/0/24|256656|gpu:l40s:3|(null)|{NHC_REASON}"
        nodes = hs.parse_nodes(line)
        self.assertEqual(len(nodes), 1)
        self.assertEqual(nodes[0].reason, NHC_REASON)

    def test_canned_nodes(self):
        nodes = {node.node: node for node in hs.parse_nodes(CANNED_NODES, CANNED_NODE_DETAILS)}
        self.assertEqual(sorted(nodes), ["calder-cpu001", "calder-h200-01", "calder-h200-02",
                                         "calder-h200-05", "calder-l40-01"])
        busy, idle, drained, l40 = (nodes[name] for name in
                                    ("calder-h200-01", "calder-h200-02", "calder-h200-05", "calder-l40-01"))
        self.assertEqual((busy.gpu_total, busy.gpu_allocated, busy.gpu_idle), (8, 5, 3))
        self.assertEqual((idle.gpu_total, idle.gpu_allocated, idle.gpu_idle), (8, 0, 8))
        self.assertEqual((drained.gpu_allocated, drained.reason), (0, NHC_REASON))
        self.assertEqual((l40.gpu_total, l40.gpu_allocated, l40.gpu_idle), (4, None, None))
        self.assertEqual(nodes["calder-cpu001"].partitions, ["calder-cpu-turin", "nodes"])
        self.assertEqual((busy.memory_free_mb, busy.cpu_load, busy.current_watts), (401234, 63.2, 2310))


# ---------------------------------------------------------------------------
# Jobs and job arrays
# ---------------------------------------------------------------------------


class ArrayTaskTests(unittest.TestCase):
    def test_count(self):
        for tasks, expected in (
            ("0-58", 59), ("1-9:2", 5), ("1,3,5-7", 5), ("7", 1), ("0-0", 1),
            ("", None), ("1,3,5...", None), ("5-1", None), ("a-b", None), ("1-9:0", None),
        ):
            with self.subTest(tasks=tasks):
                self.assertEqual(hs.count_array_tasks(tasks), expected)

    def test_spec(self):
        self.assertEqual(hs.parse_array_task_spec("0-58%4"), ("0-58", 4, 59))
        self.assertEqual(hs.parse_array_task_spec("2-5"), ("2-5", None, 4))
        self.assertEqual(hs.parse_array_task_spec("1,3,5-9:2%10"), ("1,3,5-9:2", 10, 5))
        self.assertEqual(hs.parse_array_task_spec("3%0"), ("3", None, 1))

    def test_pipe_identity(self):
        remainder = hs.pipe_job_identity("8248307_[2-5%4]")
        self.assertEqual(remainder, hs.JobIdentity("8248307", 8248307, "2-5", 4, 4))
        self.assertEqual(hs.pipe_job_identity("8248307_[0-5]"), hs.JobIdentity("8248307", 8248307, "0-5", None, 6))
        self.assertEqual(hs.pipe_job_identity("8248307_0"), hs.JobIdentity("8248307_0", 8248307))
        self.assertEqual(hs.pipe_job_identity("123"), hs.JobIdentity("123"))
        self.assertEqual(hs.pipe_job_identity("123+0"), hs.JobIdentity("123+0"))

    def test_json_identity(self):
        meta = {"job_id": 9863, "array_job_id": _num(9863), "array_task_id": _num(0, is_set=False),
                "array_max_tasks": _num(4), "array_task_string": "0-58%4", "job_state": ["PENDING"]}
        self.assertEqual(hs.json_job_identity(meta), hs.JobIdentity("9863", 9863, "0-58", 4, 59))
        task = {"job_id": 9870, "array_job_id": _num(9863), "array_task_id": _num(0)}
        self.assertEqual(hs.json_job_identity(task), hs.JobIdentity("9863_0", 9863))
        plain = {"job_id": 101, "array_job_id": _num(0), "array_task_id": _num(0, is_set=False)}
        self.assertEqual(hs.json_job_identity(plain), hs.JobIdentity("101"))
        # Older dumps: raw ints, NO_VAL for "no task".
        legacy = {"job_id": 77, "array_job_id": 77, "array_task_id": 4294967294,
                  "array_task_string": "1-3", "job_state": "PENDING"}
        self.assertEqual(hs.json_job_identity(legacy), hs.JobIdentity("77", 77, "1-3", None, 3))
        # The throttle comes from the string or, failing that, array_max_tasks.
        bare = dict(meta, array_task_string="0-9")
        self.assertEqual(hs.json_job_identity(bare), hs.JobIdentity("9863", 9863, "0-9", 4, 10))
        # A pending meta-record without a task string is still a remainder
        # (cancelling it by id would hit the whole array); its size is unknown.
        unknown = dict(meta, array_task_string="")
        self.assertEqual(hs.json_job_identity(unknown), hs.JobIdentity("9863", 9863, "", 4, None))
        self.assertIsNone(hs.json_job_identity({"job_id": _num(0, is_set=False)}))


class JobsJSONTests(unittest.TestCase):
    def jobs(self):
        jobs = hs.parse_jobs_json(CANNED_JOBS_JSON, now=FIXTURE_NOW, user=USER)
        self.assertIsNotNone(jobs)
        return {job.job_id: job for job in jobs}

    def test_ids_and_user_filter(self):
        self.assertEqual(sorted(self.jobs()), ["35796", "35796_1", "35796_2", "40188", "9918"])

    def test_without_user_filter_everything_is_kept(self):
        jobs = hs.parse_jobs_json(CANNED_JOBS_JSON, now=FIXTURE_NOW)
        self.assertIn("41000", {job.job_id for job in jobs})

    def test_epochs_render_in_cluster_time(self):
        # Zone-less times are read as the clusters' (Europe/London) wall
        # clock by every consumer, whatever zone the Mac is set to.
        epoch = 1_760_258_090  # 2025-10-12T08:34:50Z, BST (+01:00)
        previous = {key: os.environ.get(key) for key in ("TZ", "HPC_CLUSTER_TZ")}
        os.environ["TZ"] = "America/New_York"
        os.environ.pop("HPC_CLUSTER_TZ", None)
        _tzset()
        try:
            if hs._cluster_zone() is None:
                self.skipTest("no time-zone database here (Windows without tzdata)")
            self.assertEqual(hs._epoch_to_local_iso(epoch), "2025-10-12T09:34:50")
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
            _tzset()

    def test_running_job(self):
        job = self.jobs()["40188"]
        self.assertEqual((job.state, job.elapsed, job.time_limit, job.reason_or_node_list),
                         ("RUNNING", "3:25:10", "2-00:00:00", "calder-h200-01"))
        self.assertEqual((job.num_cpus, job.num_tasks, job.command),
                         (12, 1, f"/users/{USER}/runs/train.sh --lr=0.1"))
        self.assertIsNone(job.array_job_id)
        self.assertIsNone(job.array_pending_tasks)

    def test_array_tasks_and_remainder(self):
        jobs = self.jobs()
        self.assertEqual(jobs["35796_1"].array_job_id, 35796)
        self.assertIsNone(jobs["35796_1"].array_pending_tasks)
        remainder = jobs["35796"]
        self.assertEqual((remainder.state, remainder.reason_or_node_list), ("PENDING", "(JobArrayTaskLimit)"))
        self.assertEqual((remainder.array_job_id, remainder.array_pending_tasks, remainder.array_throttle,
                          remainder.pending_task_count), (35796, "3-58", 4, 56))
        self.assertEqual(remainder.req_tres, "cpu=12,mem=180G,node=1,billing=12,gres/gpu=1")

    def test_held_job(self):
        held = self.jobs()["9918"]
        self.assertEqual((held.reason_or_node_list, held.time_limit), ("(JobHeldUser)", "12:00:00"))

    def test_unlimited_and_sentinels(self):
        payload = {"jobs": [
            {"job_id": 1, "job_state": "PENDING", "time_limit": _num(0, is_set=False, infinite=True)},
            {"job_id": 2, "job_state": "PENDING", "time_limit": 4294967295},
            {"job_id": 3, "job_state": "PENDING", "time_limit": 4294967294},
        ]}
        jobs = hs.parse_jobs_json(json.dumps(payload))
        self.assertEqual([job.time_limit for job in jobs], ["UNLIMITED", "UNLIMITED", ""])

    def test_unusable_payloads(self):
        for text, reason in (
            ("", "printed nothing"),
            ("not json", "output is not valid JSON"),
            ("{}", "output has no jobs list"),
            ('{"jobs": [1]}', "has a job record that is not an object"),
            ('{"jobs": [], "errors": [{"description": "Unable to query jobs", "error_number": 1}]}',
             "reported an error: Unable to query jobs"),
        ):
            with self.subTest(text=text):
                self.assertEqual(hs.parse_jobs_json_checked(text), (None, reason))

    def test_pretty_and_compacted_are_equal(self):
        pretty = hs.parse_jobs_json(CANNED_JOBS_JSON_PRETTY, now=FIXTURE_NOW, user=USER)
        compact = hs.parse_jobs_json(CANNED_JOBS_JSON, now=FIXTURE_NOW, user=USER)
        self.assertEqual(pretty, compact)


class JobsPipeTests(unittest.TestCase):
    def test_array_detail_join(self):
        jobs = hs.parse_jobs(
            "12340_5|gpu|train|user|RUNNING|1:00|2:00:00|1|gpu001",
            "JobId=12345 ArrayJobId=12340 ArrayTaskId=5 JobName=train SubmitTime=2026-07-19T09:00:00 "
            "WorkDir=/home/u NumCPUs=8 NodeList=gpu001",
        )
        self.assertEqual(len(jobs), 1)
        self.assertEqual((jobs[0].work_dir, jobs[0].num_cpus, jobs[0].array_job_id), ("/home/u", 8, 12340))

    def test_pipe_in_job_name(self):
        fields = hs.split_job_fields("123|gpu|my|weird|name|user|RUNNING|1:00|2:00:00|1|(Priority)")
        self.assertEqual(fields[2], "my|weird|name")

    def test_remainder_is_normalised(self):
        jobs = {job.job_id: job for job in hs.parse_jobs(CANNED_JOBS_PIPE, CANNED_JOB_DETAILS)}
        remainder = jobs["35796"]
        self.assertEqual((remainder.array_job_id, remainder.array_pending_tasks, remainder.array_throttle,
                          remainder.pending_task_count), (35796, "3-58", 4, 56))
        # The meta-record's scontrol details are joined by the bare array id.
        self.assertEqual(remainder.req_tres, "cpu=12,mem=180G,node=1,billing=12,gres/gpu=1")
        self.assertEqual(jobs["35796_2"].num_cpus, 12)

    def test_pipe_and_json_agree(self):
        """Both paths produce identical ids and array fields, so a refresh
        that falls back never makes jobs 'leave the queue'."""
        pipe = {job.job_id: job for job in hs.parse_jobs(CANNED_JOBS_PIPE, CANNED_JOB_DETAILS)}
        json_jobs = {job.job_id: job for job in hs.parse_jobs_json(CANNED_JOBS_JSON, now=FIXTURE_NOW, user=USER)}
        self.assertEqual(sorted(pipe), sorted(json_jobs))
        for job_id in pipe:
            with self.subTest(job_id=job_id):
                left, right = pipe[job_id], json_jobs[job_id]
                for name in ("state", "time_limit", "reason_or_node_list", "array_job_id",
                             "array_pending_tasks", "array_throttle", "pending_task_count", "req_tres"):
                    self.assertEqual(getattr(left, name), getattr(right, name), name)

    def test_rejected_lines(self):
        rejects = []
        hs.parse_jobs("too|few|fields", "", rejects)
        self.assertEqual(rejects, ["too|few|fields"])


class ResolveJobsTests(unittest.TestCase):
    def resolve(self, output):
        sections, statuses = hs.split_sections(output)
        return hs.resolve_jobs(sections, statuses, USER, FIXTURE_NOW)

    def test_json_preferred(self):
        jobs, source, note = self.resolve(round_trip_output())
        self.assertEqual((source, note, len(jobs)), ("json", "", 5))

    def test_pipe_when_json_failed(self):
        jobs, source, note = self.resolve(round_trip_output(jobs_json_status=1, pipe_jobs=CANNED_JOBS_PIPE))
        self.assertEqual((source, note), ("pipe", "squeue --json failed with exit 1"))
        self.assertEqual(len(jobs), 5)

    def test_unusable_json_without_fallback_is_an_error(self):
        jobs, source, note = self.resolve(round_trip_output(jobs_json='{"jobs": [1]}'))
        self.assertIsNone(source)
        self.assertEqual(note, "No usable jobs listing (squeue --json has a job record that is not an object; "
                               "no pipe-format listing arrived)")

    def test_pipe_failure(self):
        output = round_trip_output(jobs_json_status=1, pipe_jobs="").replace(
            "=====HPC-STATUS:jobs:0=====", "=====HPC-STATUS:jobs:1=====")
        _, source, note = self.resolve(output)
        self.assertIsNone(source)
        self.assertEqual(note, "Section 'jobs' failed with exit 1 (squeue --json failed with exit 1)")

    def test_needs_fallback_round_trip(self):
        self.assertFalse(hs.jobs_need_fallback_round_trip(round_trip_output(), USER))
        self.assertTrue(hs.jobs_need_fallback_round_trip(round_trip_output(jobs_json='{"jobs": [1]}'), USER))
        # The remote side already ran the fallback, or JSON failed outright.
        self.assertFalse(hs.jobs_need_fallback_round_trip(
            round_trip_output(jobs_json_status=1, pipe_jobs=CANNED_JOBS_PIPE), USER))


# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------


class QuotaParsingTests(unittest.TestCase):
    NFS_LINES = [
        "Disk quotas for user abcd1234 (uid 1234):",
        "     Filesystem   space   quota   limit   grace   files   quota   limit   grace",
        "10.10.0.15:/export/apps    1M      0K      0K             10       0       0",
        "10.10.0.15:/export/users  45455M  66560M  66560M            294k  1500k  1500k",
    ]
    LFS_BRACKET = [
        "Disk quotas for usr abcd1234 (uid 1234):",
        "     Filesystem  kbytes   quota   limit   grace   files   quota   limit   grace",
        "   /mnt/scratch [3605893120]  0 4294967296  - 3182119 0 5000000 -",
        'Some errors happened when getting quota info. Some devices may be not working or '
        'deactivated. The data in "[]" is inaccurate.',
    ]

    def test_nfs_wrapped_over_quota(self):
        quota = hs.parse_nfs_quota([
            "Disk quotas for user u (uid 12345):",
            "     Filesystem   space   quota   limit   grace   files   quota   limit   grace",
            "storage:/export/users",
            "                  12.5G*    10G     15G   6days    100k    200k    300k",
        ], filesystem="any:/export/users")
        self.assertEqual((quota.get("used_gb"), quota.get("file_count_int"), quota.get("over_quota")),
                         (12.5, 100_000, True))

    def test_nfs_single_line(self):
        quota = hs.parse_nfs_quota([
            "nfs:/export/users   5G     10G     15G             50k    200k    300k",
        ], filesystem="nfs:/export/users")
        self.assertEqual((quota.get("used_gb"), quota.get("file_count_int"), quota.get("over_quota")),
                         (5, 50_000, False))

    def test_nfs_matched_by_df_source(self):
        quota = hs.parse_nfs_quota(self.NFS_LINES, filesystem="10.10.0.15:/export/users")
        self.assertAlmostEqual(quota.get("used_gb"), 45455 / 1024)
        self.assertEqual((quota.get("limit_gb"), quota.get("quota_gb")), (65.0, 65.0))
        self.assertEqual((quota.get("file_count_int"), quota.get("file_limit_int")), (294_000, 1_500_000))
        self.assertIs(quota.get("over_quota"), False)
        self.assertEqual(hs.parse_nfs_quota(self.NFS_LINES, filesystem="nfs-home.leeds:/export/users")
                         .get("limit_gb"), 65.0)
        self.assertEqual(hs.parse_nfs_quota(self.NFS_LINES, filesystem="10.10.0.15:/export/other"), {})

    def test_nfs_file_grace_does_not_shift_columns(self):
        quota = hs.parse_nfs_quota(["nfs:/export/users  5G  10G  15G  300k*  200k  300k  6days"],
                                   filesystem="nfs:/export/users")
        self.assertEqual((quota.get("file_count_int"), quota.get("file_limit_int"), quota.get("over_quota")),
                         (300_000, 300_000, True))

    def test_lfs_human_over_quota(self):
        quota = hs.parse_lfs_quota([
            "   /mnt/scratch  500G*     1T    1.5T       -  100000  200000  300000       -",
        ], mount="/mnt/scratch")
        self.assertEqual((quota.get("used_gb"), quota.get("file_count_int"), quota.get("over_quota")),
                         (500, 100_000, True))

    def test_lfs_project_raw(self):
        quota = hs.parse_lfs_quota([
            "Disk quotas for prj 123456 (pid 123456):",
            "     Filesystem  kbytes   quota   limit   grace   files   quota   limit   grace",
            "/scratch-calder  182648832  1073741824  1181116006  -  235436  0  1000000  -",
        ], mount="/scratch-calder")
        self.assertAlmostEqual(quota.get("used_gb"), 182648832 / 1024 / 1024)
        self.assertEqual(quota.get("quota_gb"), 1024.0)
        self.assertAlmostEqual(quota.get("limit_gb"), 1181116006 / 1024 / 1024)
        self.assertEqual((quota.get("file_count_int"), quota.get("file_quota_int"), quota.get("file_limit_int")),
                         (235_436, None, 1_000_000))
        self.assertNotIn("inaccurate", quota)

    def test_lfs_wrapped_and_human(self):
        wrapped = hs.parse_lfs_quota([
            "/scratch-calder-longer-name",
            "                182648832  1073741824  1181116006       -  235436       0 1000000       -",
        ], mount="/scratch-calder-longer-name")
        self.assertEqual((wrapped.get("quota_gb"), wrapped.get("file_count_int")), (1024.0, 235_436))
        human = hs.parse_lfs_quota(["/scratch-calder  174.2G      1T    1.1T       -  235436       0 1000000       -"],
                                   mount="/scratch-calder")
        self.assertAlmostEqual(human.get("used_gb"), 174.2)
        self.assertAlmostEqual(human.get("limit_gb"), 1126.4)

    def test_lfs_aire_user_quota(self):
        quota = hs.parse_lfs_quota(["/mnt/scratch 3605893120 0 4294967296 - 3182119 0 5000000 -"],
                                   mount="/mnt/scratch")
        self.assertEqual((quota.get("limit_gb"), quota.get("quota_gb")), (4096.0, None))
        self.assertEqual((quota.get("file_count_int"), quota.get("file_limit_int")), (3_182_119, 5_000_000))

    def test_lfs_brackets(self):
        quota = hs.parse_lfs_quota(self.LFS_BRACKET, mount="/mnt/scratch")
        self.assertAlmostEqual(quota.get("used_gb"), 3605893120 / 1024 / 1024)
        self.assertEqual((quota.get("limit_gb"), quota.get("inaccurate"), quota.get("over_quota")),
                         (4096.0, True, False))
        over = hs.parse_lfs_quota(
            ["/scratch-calder [1100000000]* 1073741824 1181116006 6d23h59m59s [235436] 0 1000000 -"],
            mount="/scratch-calder")
        self.assertEqual((over.get("over_quota"), over.get("inaccurate"), over.get("file_count_int")),
                         (True, True, 235_436))
        wrapped = hs.parse_lfs_quota(
            ["/scratch-calder-longer-name", "   [182648832]  1073741824  1181116006  -  235436  0  1000000  -"],
            mount="/scratch-calder-longer-name")
        self.assertEqual((wrapped.get("quota_gb"), wrapped.get("inaccurate")), (1024.0, True))

    def test_lfs_grace_that_looks_like_a_size(self):
        for row in ("/scratch-calder  1100000000*  1073741824  1181116006  5m  235436  0  1000000  -",
                    "/scratch-calder  1.1T*  1T  1.1T  5m  235436  0  1000000  -"):
            with self.subTest(row=row):
                quota = hs.parse_lfs_quota([row], mount="/scratch-calder")
                self.assertEqual((quota.get("file_count_int"), quota.get("file_quota_int"),
                                  quota.get("file_limit_int"), quota.get("over_quota")),
                                 (235_436, None, 1_000_000, True))
        seven = hs.parse_lfs_quota(["/scratch-calder 1100000000* 1073741824 1181116006 5m 1000000* 0 1000000"],
                                   mount="/scratch-calder")
        self.assertEqual((seven.get("file_count_int"), seven.get("file_limit_int"), seven.get("file_quota_int")),
                         (1_000_000, 1_000_000, None))
        blank = hs.parse_lfs_quota(["/mnt/scratch 4294967296* 0 4294967296 3182119 0 5000000 -"],
                                   mount="/mnt/scratch")
        self.assertEqual((blank.get("file_count_int"), blank.get("file_limit_int")), (3_182_119, 5_000_000))


class StorageSummaryTests(unittest.TestCase):
    def test_canned_calder(self):
        rows, warnings = hs.parse_storage(CANNED_STORAGE, calder_volumes())
        self.assertEqual(warnings, [])
        self.assertEqual([row.label for row in rows], ["Home", "Scratch"])
        home, scratch = rows
        self.assertEqual((home.quota_type, home.source, home.limit_gb, home.mount, home.path, home.project_id),
                         ("nfs", "quota", 65.0, "/users", f"/users/{USER}", None))
        self.assertEqual((scratch.quota_type, scratch.project_id, scratch.source, scratch.mount, scratch.filesystem,
                          scratch.quota_gb, scratch.file_limit),
                         ("lustre-project", 123456, "lfs quota", "/scratch-calder", "10.20.0.1@o2ib:/scratch",
                          1024.0, 1_000_000))
        self.assertGreater(scratch.available_gb, 900)
        self.assertTrue(15.0 < scratch.used_percent < 16.0)
        self.assertEqual(list(asdict(scratch)), [
            "label", "path", "filesystem", "source", "used_gb", "quota_gb", "limit_gb", "available_gb",
            "used_percent", "file_count", "file_quota", "file_limit", "over_quota", "quota_type", "project_id",
            "mount", "unavailable_reason", "optional"])
        self.assertIsNone(scratch.unavailable_reason)

    def test_aire_df_fallback_and_user_quota(self):
        volumes, _ = hs.parse_storage_spec(AIRE_SPEC)
        rows, warnings = hs.parse_storage("\n".join([
            "__HPC-VOLUME:0__", "__HPC-PATH__", "/users/abcd1234", "__HPC-DF__",
            "Filesystem 1024-blocks Used Available Capacity Mounted on",
            "10.10.0.15:/export/users 104857600 52428800 52428800 50% /users",
            "__HPC-MOUNT__", "/users", "__HPC-QUOTA__", "__HPC-VOLUME-END:0__",
            "__HPC-VOLUME:1__", "__HPC-PATH__", "/mnt/scratch/abcd1234", "__HPC-DF__",
            "Filesystem 1024-blocks Used Available Capacity Mounted on",
            "10.1.0.1@o2ib:/scratch 3972844748800 2000000000000 1972844748800 51% /mnt/scratch",
            "__HPC-MOUNT__", "/mnt/scratch", "__HPC-PROJECT__", "0", "__HPC-QUOTA__",
            "/mnt/scratch 3605893120 0 4294967296 - 3182119 0 5000000 -",
            "__HPC-VOLUME-END:1__",
            "__HPC-VOLUME:2__", "__HPC-TRIED__", "/flash-aire/users/abcd1234", "__HPC-VOLUME-END:2__",
        ]), volumes)
        self.assertEqual([row.label for row in rows], ["Home", "Scratch"])
        self.assertEqual((rows[0].source, rows[0].used_gb, rows[0].limit_gb), ("df", 50.0, 100.0))
        self.assertEqual((rows[1].quota_type, rows[1].limit_gb, rows[1].file_limit), ("lustre-user", 4096.0, 5_000_000))
        self.assertEqual(len(warnings), 1)
        self.assertIn("Home", warnings[0])

    def test_bracketed_lfs_warning(self):
        rows, warnings = hs.parse_storage("\n".join([
            "__HPC-VOLUME:1__", "__HPC-PATH__", "/mnt/scratch/abcd1234", "__HPC-DF__",
            "Filesystem 1024-blocks Used Available Capacity Mounted on",
            "10.1.0.1@o2ib:/scratch 3972844748800 2000000000000 1972844748800 51% /mnt/scratch",
            "__HPC-MOUNT__", "/mnt/scratch", "__HPC-PROJECT__", "0", "__HPC-QUOTA__",
        ] + QuotaParsingTests.LFS_BRACKET + ["__HPC-VOLUME-END:1__"]), [
            hs.StorageVolume("Home", ("$HOME",), "none", optional=True),
            hs.StorageVolume("Scratch", ("/mnt/scratch/$USER",), "lustre"),
        ])
        # Home (optional) has no block at all: not collected, not omitted.
        self.assertEqual([(row.label, row.source, row.unavailable_reason, row.optional) for row in rows],
                         [("Home", "unavailable", "not-collected", True), ("Scratch", "lfs quota", None, False)])
        self.assertEqual(len(warnings), 1)
        self.assertIn("inaccurate", warnings[0])

    def test_optional_volume_cut_is_not_collected(self):
        volumes = calder_volumes()
        flash = volumes[2]
        cases = {
            "no block": None,
            "cut after the volume marker": {},
            "PATH marker without its value": {"PATH": []},
            "STALLED marker without its value": {"STALLED": []},
        }
        for name, block in cases.items():
            with self.subTest(name):
                row, warnings = hs.summarize_volume(flash, block)
                self.assertEqual((row.source, row.unavailable_reason, row.optional, row.path),
                                 ("unavailable", "not-collected", True, ""))
                self.assertEqual(warnings, [])
        # Proof of absence (AIRE has no Flash): omitted, no phantom row.
        row, warnings = hs.summarize_volume(flash, {"TRIED": ["/flash-calder/users/u"]})
        self.assertIsNone(row)
        row, _ = hs.summarize_volume(flash, {"TRIED": []})
        self.assertIsNone(row)

    def test_required_volume_cut_is_not_called_missing(self):
        scratch = calder_volumes()[1]
        row, warnings = hs.summarize_volume(scratch, {})
        self.assertEqual((row.unavailable_reason, warnings), ("not-collected", []))
        row, warnings = hs.summarize_volume(scratch, {"TRIED": ["/scratch-calder/users/u", "/scratch-calder/u"]})
        self.assertEqual((row.unavailable_reason, row.path), ("missing", "/scratch-calder/users/u"))
        self.assertIn("no directory found", warnings[0])

    def test_stalled_probe(self):
        flash = calder_volumes()[2]
        row, warnings = hs.summarize_volume(flash, {"STALLED": ["/flash-calder/users/u"]})
        self.assertEqual((row.source, row.unavailable_reason, row.path), ("unavailable", "no-figures",
                                                                          "/flash-calder/users/u"))
        self.assertIn("did not answer in time", warnings[0])

    def test_busy_marker(self):
        rows, warnings = hs.parse_storage("__HPC-STORAGE-BUSY__", calder_volumes())
        self.assertIsNone(rows)
        self.assertIn("still stuck", warnings[0])


class StorageSpecTests(unittest.TestCase):
    def test_default(self):
        volumes, error = hs.parse_storage_spec(None)
        self.assertIsNone(error)
        self.assertEqual([volume.label for volume in volumes], ["Home"])

    def test_invalid_specs_are_errors_not_exceptions(self):
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
            ("oversize", '[{"label": "Home", "paths": ["' + "x" * hs.MAX_STORAGE_SPEC_CHARS + '"]}]'),
        ):
            with self.subTest(name):
                volumes, error = hs.parse_storage_spec(text)
                self.assertEqual(volumes, [])
                self.assertTrue(error.startswith(hs.STORAGE_SPEC_ERROR_PREFIX), error)

    def test_cluster_specs(self):
        for text in (AIRE_SPEC, CALDER_SPEC):
            volumes, error = hs.parse_storage_spec(text)
            self.assertIsNone(error)
            self.assertEqual([volume.label for volume in volumes], ["Home", "Scratch", "Flash"])
            self.assertTrue(volumes[2].optional)
            self.assertEqual(volumes[1].quota, "lustre")

    def test_spec_error_snapshot(self):
        config = hs.SSHConfig(host="aire", username=None, hostname=None, use_jump_host=False,
                              jump_hostname=None, control_path=None, jump_control_path=None, timeout=5)
        _, error = hs.parse_storage_spec("not json")
        snapshot = hs.empty_snapshot(config, hs.ClusterInfo("aire", "AIRE"), "now", error)
        self.assertEqual(snapshot.errors, [error])
        self.assertIsNone(snapshot.storage)
        self.assertEqual(asdict(snapshot)["cluster"], {"id": "aire", "name": "AIRE"})


class PathTemplateTests(unittest.TestCase):
    def test_rendering(self):
        self.assertEqual(hs.render_path_template("/scratch-calder/users/$USER"), "'/scratch-calder/users/'\"$USER\"")
        self.assertEqual(hs.render_path_template("$HOME"), '"$HOME"')
        self.assertEqual(hs.render_path_template("${HOME}/x"), "\"$HOME\"'/x'")
        self.assertEqual(hs.render_path_template("/d/$USERNAME/$SCRATCH"), "'/d/$USERNAME/$SCRATCH'")
        self.assertEqual(hs.render_path_template("/o'brien/$USER"), "'/o'\"'\"'brien/'\"$USER\"")

    @unittest.skipUnless(os.path.exists("/bin/sh"), "needs /bin/sh")
    def test_shell_expansion(self):
        env = {"PATH": "/usr/bin:/bin", "USER": "alice", "HOME": "/home/alice",
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
            with self.subTest(template=template):
                completed = subprocess.run(["/bin/sh", "-c", f"printf '%s' {hs.render_path_template(template)}"],
                                           check=False, capture_output=True, text=True, env=env,
                                           stdin=subprocess.DEVNULL, timeout=10)
                self.assertEqual(completed.stdout, expected)


# ---------------------------------------------------------------------------
# Section protocol, timing and assembly
# ---------------------------------------------------------------------------


class SectionProtocolTests(unittest.TestCase):
    def test_split_sections_ignores_time_markers(self):
        sections, statuses = hs.split_sections(
            "=====HPC-TIME:start:100.0=====\n"
            "\n=====HPC-SECTION:remote=====\nhost|user|/home/u|2026-07-19T10:00:00\n"
            "\n=====HPC-STATUS:remote:0=====\n=====HPC-TIME:remote:100.5=====\n"
            "\n=====HPC-SECTION:jobs=====\n\n=====HPC-STATUS:jobs:1=====\n"
        )
        self.assertEqual(sections["remote"], "host|user|/home/u|2026-07-19T10:00:00")
        self.assertEqual(statuses, {"remote": 0, "jobs": 1})

    def test_section_timings(self):
        timings = hs.section_timings(round_trip_output())
        self.assertEqual(timings, {"prelude": 12, "remote": 30, "partitions": 85, "nodes": 140, "jobs_json": 357,
                                   "node_details": 120, "storage": 450})

    def test_coarse_and_repeated_timings(self):
        # A `date` without %N prints '1760000000.N': whole seconds. A second
        # round trip (start again) accumulates per section.
        output = "\n".join([
            "=====HPC-TIME:start:1760000000.N=====", "=====HPC-TIME:prelude:1760000001.N=====",
            "=====HPC-TIME:start:1760000100.000=====", "=====HPC-TIME:prelude:1760000100.250=====",
            "=====HPC-TIME:jobs:garbage=====", "=====HPC-TIME:job_details:1760000101.000=====",
        ])
        self.assertEqual(hs.section_timings(output), {"prelude": 1250})
        self.assertEqual(hs.parse_remote_clock("1760000000.5"), 1760000000.5)
        self.assertIsNone(hs.parse_remote_clock("N"))

    def test_complete_lines(self):
        self.assertEqual(hs.complete_lines("a\nb\n"), "a\nb\n")
        self.assertEqual(hs.complete_lines("a\nAllocTRES=cpu=64,gr"), "a\n")
        self.assertEqual(hs.complete_lines("partial"), "")
        self.assertEqual(hs.complete_lines(""), "")

    def test_describe_cut(self):
        sections, statuses = hs.split_sections(round_trip_output().split("=====HPC-STATUS:node_details")[0])
        self.assertEqual(hs.describe_cut(sections, statuses), "cut during node_details")
        sections, statuses = hs.split_sections(round_trip_output().split("=====HPC-SECTION:node_details")[0])
        self.assertEqual(hs.describe_cut(sections, statuses), "cut after jobs_json")
        self.assertEqual(hs.describe_cut({}, {}), "cut before any section finished")


class AssembleTests(unittest.TestCase):
    def test_clean_snapshot(self):
        snapshot = assemble(round_trip_output())
        self.assertEqual((snapshot.errors, snapshot.warnings), ([], []))
        self.assertEqual(snapshot.cluster, CALDER)
        self.assertEqual((snapshot.remote.host, snapshot.remote.user), ("calder.leeds.ac.uk", USER))
        self.assertEqual([row.label for row in snapshot.storage], ["Home", "Scratch"])
        self.assertEqual(len(snapshot.jobs), 5)
        self.assertEqual(len(snapshot.nodes), 5)
        self.assertFalse(snapshot.storage_skipped)
        self.assertEqual(snapshot.timings["jobs_json"], 357)

    def test_payload_schema_version_first(self):
        payload = hs.snapshot_payload(assemble(round_trip_output()))
        keys = list(payload)
        self.assertEqual(keys[0], "schema_version")
        self.assertEqual(payload["schema_version"], hs.SCHEMA_VERSION)
        self.assertEqual(keys[1:], ["collected_at", "cluster", "remote", "jobs", "partitions", "nodes", "storage",
                                    "errors", "warnings", "storage_skipped", "started_at", "duration_ms", "timings",
                                    "job_usage"])
        job_keys = list(payload["jobs"][0])
        self.assertEqual(job_keys[-4:], ["array_job_id", "array_pending_tasks", "array_throttle",
                                         "pending_task_count"])

    def test_fallback_jobs_warn(self):
        snapshot = assemble(round_trip_output(jobs_json_status=1, pipe_jobs=CANNED_JOBS_PIPE))
        self.assertEqual(snapshot.errors, [])
        self.assertEqual(snapshot.warnings,
                         ["Jobs read with the pipe-format fallback (squeue --json failed with exit 1)"])
        self.assertEqual(sorted(job.job_id for job in snapshot.jobs), ["35796", "35796_1", "35796_2", "40188", "9918"])

    def test_missing_job_details_only_matters_on_the_fallback(self):
        output = round_trip_output(jobs_json_status=1, pipe_jobs=CANNED_JOBS_PIPE)
        output = output.replace("=====HPC-STATUS:job_details:0=====\n", "")
        snapshot = assemble(output)
        self.assertIn("Section 'job_details' missing from remote output", snapshot.warnings)
        self.assertNotIn("job_details", " ".join(assemble(round_trip_output()).warnings))

    def test_no_jobs_is_a_core_error(self):
        snapshot = assemble(round_trip_output(jobs_json='{"jobs": [1]}'))
        self.assertEqual(len(snapshot.errors), 1)
        self.assertIn("No usable jobs listing", snapshot.errors[0])

    def test_no_sections_is_an_error(self):
        snapshot = assemble("")
        self.assertEqual(snapshot.errors, ["Remote output contained no sections (the remote shell ran nothing)"])

    def test_node_details_failure_marks_gpu_allocation_unknown(self):
        snapshot = assemble(round_trip_output(node_details="", node_details_status=1))
        self.assertEqual(snapshot.errors, [])
        self.assertIn("Section 'node_details' failed with exit 1", snapshot.warnings)
        self.assertIn("GPU allocation unknown for 4 GPU nodes (node_details unavailable)", snapshot.warnings)
        self.assertTrue(all(node.gpu_allocated is None for node in snapshot.nodes))

    def test_unreadable_node_line_is_reported(self):
        snapshot = assemble(round_trip_output(nodes=CANNED_NODES + "\nbroken-line"))
        self.assertEqual(len(snapshot.nodes), 5)
        self.assertEqual(snapshot.warnings, ["Skipped 1 unreadable node line: 'broken-line'"])

    def test_skip_storage(self):
        snapshot = assemble(round_trip_output(include_storage=False), skip_storage=True)
        self.assertEqual((snapshot.errors, snapshot.warnings), ([], []))
        self.assertIsNone(snapshot.storage)
        self.assertTrue(snapshot.storage_skipped)

    def test_busy_storage(self):
        snapshot = assemble(round_trip_output(storage="__HPC-STORAGE-BUSY__"))
        self.assertIsNone(snapshot.storage)
        self.assertTrue(snapshot.storage_skipped)
        self.assertEqual(len(snapshot.warnings), 1)

    def test_timeout_with_complete_core(self):
        cut = round_trip_output().split("=====HPC-SECTION:storage=====")[0] + (
            "=====HPC-SECTION:storage=====\n__HPC-VOLUME:0__\n__HPC-PATH__\n/users/abcd1234\n__HPC-DF__\n")
        snapshot = assemble(cut, error="Timed out after 30s: snapshot collection", timed_out=True)
        self.assertEqual(snapshot.errors, [])
        self.assertIn("Timed out after 30s: snapshot collection (core sections were complete; cut during storage)",
                      snapshot.warnings)
        self.assertIn("Section 'storage' missing from remote output", snapshot.warnings)
        # Home was cut right after its PATH line: unavailable with the real
        # path, never a df row of nulls. Scratch and the optional Flash never
        # arrived: not collected (Flash is not silently dropped).
        self.assertEqual([(row.label, row.source, row.unavailable_reason, row.path) for row in snapshot.storage], [
            ("Home", "unavailable", "no-figures", "/users/abcd1234"),
            ("Scratch", "unavailable", "not-collected", ""),
            ("Flash", "unavailable", "not-collected", ""),
        ])
        self.assertTrue(snapshot.storage[2].optional)
        self.assertFalse(any("showing filesystem totals" in warning for warning in snapshot.warnings))

    def test_timeout_names_node_details(self):
        cut = round_trip_output().split("=====HPC-STATUS:node_details")[0]
        snapshot = assemble(cut, error="Timed out after 30s: snapshot collection", timed_out=True)
        self.assertEqual(snapshot.errors, [])
        self.assertIn("Timed out after 30s: snapshot collection (core sections were complete; "
                      "cut during node_details)", snapshot.warnings)
        # Every record arrived whole before the cut, so allocation is known
        # (the L40 node is unknown only because it has no GPU TRES).
        self.assertFalse(any("GPU allocation unknown" in warning for warning in snapshot.warnings))
        self.assertEqual({node.node: node.gpu_allocated for node in snapshot.nodes if node.gpu_total},
                         {"calder-h200-01": 5, "calder-h200-02": 0, "calder-h200-05": 0, "calder-l40-01": None})
        self.assertIsNone(snapshot.storage)
        # Cut before the last two records: those GPU nodes are unknown.
        partial = round_trip_output().split("NodeName=calder-h200-05")[0]
        snapshot = assemble(partial, error="Timed out after 30s: snapshot collection", timed_out=True)
        self.assertIn("GPU allocation unknown for 2 GPU nodes (node_details unavailable)", snapshot.warnings)

    def test_timeout_with_incomplete_core(self):
        early = round_trip_output().split("=====HPC-SECTION:nodes=====")[0]
        snapshot = assemble(early, error="Timed out after 30s: snapshot collection", timed_out=True)
        self.assertIn("Timed out after 30s: snapshot collection", snapshot.errors)
        self.assertIn("Section 'nodes' missing from remote output", snapshot.errors)
        self.assertIsNone(snapshot.storage)

    def test_failed_round_trip(self):
        snapshot = assemble("", error="Command failed with exit 255: snapshot collection")
        self.assertEqual(snapshot.errors, ["Command failed with exit 255: snapshot collection"])
        self.assertEqual((snapshot.storage, snapshot.warnings), (None, []))


# ---------------------------------------------------------------------------
# The generated remote script, run by local shells against stub commands
# ---------------------------------------------------------------------------


def _write_stub(directory, name, body):
    path = os.path.join(directory, name)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("#!/bin/sh\n" + body)
    os.chmod(path, 0o755)
    return path


def available_shells():
    return [shell for shell in ("/bin/sh", "/bin/dash", "/bin/bash", "/bin/zsh") if os.path.exists(shell)]


class RemoteScriptTextTests(unittest.TestCase):
    def test_script_shape(self):
        volumes = calder_volumes()
        script = hs.build_remote_script(volumes)
        self.assertIn("hpc_volume 1 'lustre' '/scratch-calder/users/'\"$USER\" '/scratch-calder/'\"$USER\"", script)
        self.assertIn("=====HPC-SECTION:", script)
        self.assertNotIn("AIRE-SECTION", script)
        self.assertIn("%f|%l'", script)
        self.assertIn("%f|%E'", script)
        self.assertIn("hpc_storage_timeout=10\n", script)
        self.assertIn("hpc_storage_stuck_after=15\n", script)
        self.assertIn("hpc_storage_timeout=2\n", hs.build_remote_script(volumes, 5))
        self.assertIn("hpc_run df -Pk", script)
        self.assertIn("hpc_run lfs quota -p", script)
        self.assertIn('hpc_run test -d "$hpc_candidate"', script)
        self.assertNotIn('[ -d "$hpc_candidate" ]', script)
        self.assertIn("SLURM_BITSTR_LEN=0", script)
        self.assertEqual([hs.storage_command_timeout(b) for b in (1, 8, 20, 30, 300)], [2, 2, 6, 10, 10])

    def test_section_order(self):
        script = hs.build_remote_script(calder_volumes())
        order = [script.index(f"section {name}\n") for name in
                 ("remote", "partitions", "nodes", "jobs_json", "jobs", "node_details", "job_details", "storage")]
        self.assertEqual(order, sorted(order))

    def test_json_path_has_no_per_job_loop(self):
        """The scontrol-per-job loop and the pipe squeue only exist inside
        the fallback branch."""
        script = hs.build_remote_script(calder_volumes())
        fallback_start = script.index('if [ "$hpc_jobs_fallback" -eq 1 ]; then\n    section jobs')
        self.assertGreater(script.index("scontrol show job"), fallback_start)
        self.assertEqual(script.count("squeue -u"), 2)
        self.assertGreater(script.index("squeue -u \"$USER\" -h -o"), fallback_start)

    def test_comments_are_stripped(self):
        script = hs.build_remote_script(calder_volumes())
        lines = script.splitlines()
        self.assertEqual(lines[0], "# hpc-round-trip: snapshot")
        self.assertFalse(any(line.lstrip().startswith("#") for line in lines[1:]))
        self.assertFalse(any(not line.strip() for line in lines))
        self.assertTrue(hs.build_jobs_fallback_script().startswith("# hpc-round-trip: jobs-fallback\n"))

    def test_skip_storage_omits_the_section(self):
        script = hs.build_remote_script(calder_volumes(), include_storage=False)
        self.assertNotIn("section storage", script)
        self.assertNotIn("hpc_volume", script)

    def test_syntax_in_every_shell(self):
        for shell in available_shells():
            for script in (hs.build_remote_script(calder_volumes()), hs.build_jobs_fallback_script()):
                with self.subTest(shell=shell):
                    completed = subprocess.run([shell, "-n", "-c", script], check=False, capture_output=True,
                                               text=True, stdin=subprocess.DEVNULL, timeout=10)
                    self.assertEqual(completed.returncode, 0, completed.stderr)


@unittest.skipUnless(os.path.exists("/bin/sh") and shutil.which("awk"), "needs /bin/sh and awk")
class RemoteScriptHarnessTests(unittest.TestCase):
    """Execute the generated script under local shells against a fake tree
    and stub Slurm/df/quota/lfs/timeout/ps commands. Proves the generated
    shell (quoting, candidate resolution, the JSON-or-fallback branch, the
    project-id branch, mount extraction, hpc_run wrapping, the stuck-storage
    guard, section and time markers) end to end without any SSH."""

    def setUp(self):
        # A temp root containing a space and a single quote exercises quoting.
        self.root = tempfile.mkdtemp(prefix="hpc self'test ")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.bin = os.path.join(self.root, "bin")
        self.home = os.path.join(self.root, "home", "alice")
        self.scratch = os.path.join(self.root, "scratch-calder", "users", "alice")
        for directory in (self.bin, self.home, self.scratch):
            os.makedirs(directory)
        self.data = os.path.join(self.root, "data")
        os.makedirs(self.data)
        for name, text in (("jobs.json", CANNED_JOBS_JSON_PRETTY.replace(USER, "alice")),
                           ("jobs.pipe", CANNED_JOBS_PIPE.replace(USER, "alice")),
                           ("job_details", CANNED_JOB_DETAILS.replace(USER, "alice")),
                           ("partitions", CANNED_PARTITIONS), ("nodes", CANNED_NODES),
                           ("node_details", CANNED_NODE_DETAILS)):
            with open(os.path.join(self.data, name), "w", encoding="utf-8") as handle:
                handle.write(text + "\n")
        self.calls = os.path.join(self.root, "calls.log")
        self.timeout_log = os.path.join(self.root, "timeout.log")
        data = hs.shell_single_quote(self.data)
        calls = hs.shell_single_quote(self.calls)
        # df reports the NFS home or the Lustre scratch depending on the
        # path; lfs only answers for the project id it hands out.
        _write_stub(self.bin, "df", (
            'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\\n"\n'
            'case "$2" in\n'
            '*scratch-calder*) printf "10.20.0.1@o2ib:/scratch 5944000000000 1200000000000 4744000000000 21%% /scratch-calder\\n" ;;\n'
            '*) printf "10.10.0.15:/export/users 104857600000 70000000000 34857600000 67%% /users\\n" ;;\n'
            'esac\n'
        ))
        _write_stub(self.bin, "quota", (
            'printf "Disk quotas for user alice (uid 1001):\\n"\n'
            'printf "     Filesystem   space   quota   limit   grace   files   quota   limit   grace\\n"\n'
            'printf "10.10.0.15:/export/users  45455M  66560M  66560M            294k  1500k  1500k\\n"\n'
        ))
        _write_stub(self.bin, "lfs", (
            'if [ "$1" = project ]; then printf "123456 P %s\\n" "$3"; exit 0; fi\n'
            'if [ "$1" = quota ] && [ "$2" = -p ] && [ "$3" = 123456 ] && [ "$4" = /scratch-calder ]; then\n'
            '  printf "Disk quotas for prj 123456 (pid 123456):\\n"\n'
            '  printf "     Filesystem  kbytes   quota   limit   grace   files   quota   limit   grace\\n"\n'
            '  printf " /scratch-calder  182648832  1073741824  1181116006  -  235436  0  1000000  -\\n"\n'
            '  exit 0\n'
            'fi\n'
            'exit 1\n'
        ))
        # squeue: --json prints the pretty payload (or fails with
        # $HPC_SELFTEST_JSON_RC); otherwise the pipe listing. Every call is
        # logged, so RPC counts can be asserted.
        _write_stub(self.bin, "squeue", (
            f'printf "squeue %s\\n" "$*" >> {calls}\n'
            'case " $* " in\n'
            '*" --json "*)\n'
            '    if [ -n "${HPC_SELFTEST_JSON_RC:-}" ]; then exit "$HPC_SELFTEST_JSON_RC"; fi\n'
            f'    cat {data}/jobs.json ;;\n'
            f'*) cat {data}/jobs.pipe ;;\n'
            'esac\n'
        ))
        _write_stub(self.bin, "sinfo", (
            f'printf "sinfo %s\\n" "$*" >> {calls}\n'
            f'case " $* " in *" -N "*) cat {data}/nodes ;; *) cat {data}/partitions ;; esac\n'
        ))
        _write_stub(self.bin, "scontrol", (
            f'printf "scontrol %s\\n" "$*" >> {calls}\n'
            f'if [ "$2" = node ]; then cat {data}/node_details; exit 0; fi\n'
            'awk -v id="$4" \'{ n = split(id, p, "_"); if ($1 == "JobId=" id) { print; next }\n'
            '  if (n == 1 && index($0, " ArrayJobId=" id " ")) { print; next }\n'
            '  if (n == 2 && index($0, " ArrayJobId=" p[1] " ArrayTaskId=" p[2] " ")) print }\' '
            f'{data}/job_details\n'
        ))
        # `timeout` logs how hpc_run called it, then runs the command — or,
        # for a df or test of a path containing $HPC_SELFTEST_STALL, pretends
        # the limit expired (exit 124, no output) like a hung filesystem.
        _write_stub(self.bin, "timeout", (
            f'printf "%s %s %s %s\\n" "$1" "$2" "$3" "$4" >> {hs.shell_single_quote(self.timeout_log)}\n'
            'shift 3\n'
            'if [ -n "${HPC_SELFTEST_STALL:-}" ] && [ "$1" = "${HPC_SELFTEST_STALL_COMMAND:-df}" ]; then\n'
            '    case "$3" in *"$HPC_SELFTEST_STALL"*) exit 124 ;; esac\n'
            'fi\n'
            'exec "$@"\n'
        ))
        # ps: prints $HPC_SELFTEST_PS when set (a canned process table).
        _write_stub(self.bin, "ps", 'if [ -n "${HPC_SELFTEST_PS:-}" ]; then cat "$HPC_SELFTEST_PS"; fi\n')
        # The remote account is the job owner (the JSON is filtered on it).
        _write_stub(self.bin, "whoami", 'printf "%s\\n" "$USER"\n')
        spec = json.dumps([
            {"label": "Home", "paths": ["$HOME"], "quota": "nfs"},
            {"label": "Scratch", "paths": [self.root + "/scratch-calder/users/$USER",
                                           self.root + "/scratch-calder/$USER"], "quota": "lustre"},
            {"label": "Flash", "paths": [self.root + "/flash-calder/users/$USER"], "quota": "lustre",
             "optional": True},
            {"label": "Projects", "paths": [self.root + "/projects/${USER}"], "quota": "none"},
        ])
        self.volumes, error = hs.parse_storage_spec(spec)
        self.assertIsNone(error)
        self.env = {"PATH": self.bin + os.pathsep + "/usr/bin:/bin", "USER": "alice", "HOME": self.home,
                    "LC_ALL": "C"}

    def run_script(self, shell="/bin/sh", include_storage=True, **extra_env):
        for path in (self.calls, self.timeout_log):
            if os.path.exists(path):
                os.remove(path)
        completed = subprocess.run(
            [shell, "-c", hs.build_remote_script(self.volumes, include_storage=include_storage)],
            check=False, capture_output=True, text=True, env=dict(self.env, **extra_env), cwd=self.home,
            stdin=subprocess.DEVNULL, timeout=60,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return completed.stdout

    def read_log(self, path):
        try:
            with open(path, encoding="utf-8") as handle:
                return handle.read().splitlines()
        except OSError:
            return []

    def snapshot(self, output, **kwargs):
        config = calder_config(username="alice")
        return hs.assemble_snapshot(config, CALDER, self.volumes, "now", output, None, False, now=FIXTURE_NOW,
                                    **kwargs)

    def test_json_path_in_every_shell(self):
        for shell in available_shells():
            with self.subTest(shell=shell):
                output = self.run_script(shell)
                sections, statuses = hs.split_sections(output)
                self.assertEqual(list(statuses), ["remote", "partitions", "nodes", "jobs_json", "node_details",
                                                  "storage"])
                self.assertTrue(all(code == 0 for code in statuses.values()), statuses)
                # The JSON arrived without its indentation.
                self.assertFalse(any(line != line.lstrip() for line in sections["jobs_json"].splitlines()))
                calls = self.read_log(self.calls)
                self.assertEqual([call for call in calls if call.startswith("squeue")],
                                 ["squeue -u alice --json"])
                self.assertEqual([call for call in calls if call.startswith("scontrol")], ["scontrol show node -o"])
                snapshot = self.snapshot(output)
                self.assertEqual(snapshot.errors, [])
                self.assertEqual(sorted(job.job_id for job in snapshot.jobs),
                                 ["35796", "35796_1", "35796_2", "40188", "9918"])
                self.assertEqual(sorted(snapshot.timings),
                                 sorted(["prelude", "remote", "partitions", "nodes", "jobs_json", "node_details",
                                         "storage"]))
                self.assertEqual({node.node: node.reason for node in snapshot.nodes}["calder-h200-05"], NHC_REASON)

    def test_fallback_path(self):
        output = self.run_script(HPC_SELFTEST_JSON_RC="1")
        sections, statuses = hs.split_sections(output)
        self.assertEqual(list(statuses), ["remote", "partitions", "nodes", "jobs_json", "jobs", "node_details",
                                          "job_details", "storage"])
        self.assertEqual(statuses["jobs_json"], 1)
        calls = self.read_log(self.calls)
        self.assertEqual([call for call in calls if call.startswith("squeue")],
                         ["squeue -u alice --json", "squeue -u alice -h -o %i|%P|%j|%u|%T|%M|%l|%D|%R"])
        # One scontrol per listed id, the remainder by its bare array id.
        self.assertEqual(sorted(call for call in calls if call.startswith("scontrol show job")),
                         sorted(f"scontrol show job -o {job_id}" for job_id in
                                ("35796", "35796_1", "35796_2", "40188", "9918")))
        snapshot = self.snapshot(output)
        self.assertEqual(snapshot.errors, [])
        self.assertEqual(snapshot.warnings,
                         ["Jobs read with the pipe-format fallback (squeue --json failed with exit 1)",
                          "Storage 'Projects': no directory found (tried " + self.root + "/projects/alice)"])
        remainder = {job.job_id: job for job in snapshot.jobs}["35796"]
        self.assertEqual((remainder.array_pending_tasks, remainder.pending_task_count, remainder.num_cpus),
                         ("3-58", 56, 12))

    def test_storage_rows(self):
        output = self.run_script()
        rows, warnings = hs.parse_storage(hs.split_sections(output)[0]["storage"], self.volumes)
        by_label = {row.label: row for row in rows}
        self.assertEqual(sorted(by_label), ["Home", "Projects", "Scratch"])
        home, scratch, projects = by_label["Home"], by_label["Scratch"], by_label["Projects"]
        self.assertEqual((home.quota_type, home.path, home.limit_gb, home.filesystem, home.mount),
                         ("nfs", self.home, 65.0, "10.10.0.15:/export/users", "/users"))
        self.assertEqual((scratch.quota_type, scratch.project_id, scratch.path, scratch.mount, scratch.file_limit),
                         ("lustre-project", 123456, self.scratch, "/scratch-calder", 1_000_000))
        self.assertEqual((projects.source, projects.path, projects.unavailable_reason),
                         ("unavailable", self.root + "/projects/alice", "missing"))
        self.assertEqual(len(warnings), 1)
        self.assertIn("Projects", warnings[0])
        wrapped = [line.split() for line in self.read_log(self.timeout_log)]
        # The probe runs once with 5 s; every storage command, the existence
        # probes included, gets the default budget's 10 s limit and a 2 s
        # SIGKILL grace.
        self.assertIn(["-k", "2", "5", "true"], wrapped)
        self.assertEqual({words[3] for words in wrapped if words[:3] == ["-k", "2", "10"]},
                         {"test", "df", "quota", "lfs"})

    def test_stalled_df(self):
        output = self.run_script(HPC_SELFTEST_STALL="scratch-calder")
        rows, warnings = hs.parse_storage(hs.split_sections(output)[0]["storage"], self.volumes)
        scratch = {row.label: row for row in rows}["Scratch"]
        self.assertEqual((scratch.source, scratch.path, scratch.unavailable_reason),
                         ("unavailable", self.scratch, "no-figures"))
        self.assertTrue(any("Scratch" in warning and "no usage figures" in warning for warning in warnings))

    def test_stalled_existence_probe(self):
        output = self.run_script(HPC_SELFTEST_STALL="scratch-calder/users", HPC_SELFTEST_STALL_COMMAND="test")
        rows, warnings = hs.parse_storage(hs.split_sections(output)[0]["storage"], self.volumes)
        scratch = {row.label: row for row in rows}["Scratch"]
        # Stopped at the stalled candidate: not 'missing', and the second
        # candidate was not tried in its place.
        self.assertEqual((scratch.source, scratch.unavailable_reason, scratch.path),
                         ("unavailable", "no-figures", self.scratch))
        self.assertTrue(any("did not answer in time" in warning for warning in warnings))
        self.assertNotIn(self.root + "/scratch-calder/alice",
                         [line.split(" ", 3)[-1] for line in self.read_log(self.timeout_log)])

    def test_stuck_earlier_collection_skips_storage(self):
        table = os.path.join(self.root, "ps.txt")
        with open(table, "w", encoding="utf-8") as handle:
            handle.write("    3 -bash\n   40 df -Pk /scratch-calder/users/alice\n")
        output = self.run_script(HPC_SELFTEST_PS=table)
        snapshot = self.snapshot(output)
        self.assertIsNone(snapshot.storage)
        self.assertTrue(snapshot.storage_skipped)
        self.assertFalse(any(line.startswith("-k 2 10") for line in self.read_log(self.timeout_log)))

    def test_young_storage_commands_are_not_stuck(self):
        table = os.path.join(self.root, "ps.txt")
        with open(table, "w", encoding="utf-8") as handle:
            # A concurrent healthy collection (1 s old) and an old unrelated process.
            handle.write("    1 df -Pk /users/alice\n 9000 lfsquota-lookalike\n 9000 vim notes.txt\n")
        snapshot = self.snapshot(self.run_script(HPC_SELFTEST_PS=table))
        self.assertIsNotNone(snapshot.storage)
        self.assertFalse(snapshot.storage_skipped)

    def test_skip_storage(self):
        output = self.run_script(include_storage=False)
        snapshot = self.snapshot(output, skip_storage=True)
        self.assertNotIn("storage", hs.split_sections(output)[1])
        self.assertEqual((snapshot.errors, snapshot.warnings, snapshot.storage), ([], [], None))
        self.assertFalse(any(line.startswith("df") for line in self.read_log(self.timeout_log)))


# ---------------------------------------------------------------------------
# collect_snapshot end to end, with a stub instead of the ssh client
# ---------------------------------------------------------------------------


@unittest.skipUnless(os.path.exists("/bin/sh"), "needs /bin/sh")
class CollectorStubSSHTests(unittest.TestCase):
    """SSHConfig.ssh_executable is a local stub's absolute path, so the real
    ssh client, the network and the user's control sockets are never
    involved. The stub answers `-O check` itself and otherwise prints a
    canned output chosen by which round trip the command is, optionally
    stalling afterwards."""

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="hpc-selftest-ssh-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.round_trip_marker = os.path.join(self.root, "round-trip-ran")

    def make_stub(self, name, payload, fallback_payload=b"", probe_rc=0, stall=False):
        main = os.path.join(self.root, name + ".out")
        fallback = os.path.join(self.root, name + ".fallback.out")
        for path, data in ((main, payload), (fallback, fallback_payload)):
            with open(path, "wb") as handle:
                handle.write(data)
        return _write_stub(self.root, name, (
            'for hpc_arg in "$@"; do\n'
            '    if [ "$hpc_arg" = "-O" ]; then\n'
            f'        [ {probe_rc} -eq 0 ] || echo "Control socket connect: No such file or directory" >&2\n'
            f'        exit {probe_rc}\n'
            '    fi\n'
            'done\n'
            f': > {hs.shell_single_quote(self.round_trip_marker)}\n'
            'for hpc_last in "$@"; do :; done\n'
            'case $hpc_last in\n'
            f'"# hpc-round-trip: jobs-fallback"*) cat {hs.shell_single_quote(fallback)} ;;\n'
            f'*) cat {hs.shell_single_quote(main)} ;;\n'
            'esac\n'
            + ("exec sleep 30\n" if stall else "exit 0\n")
        ))

    def config(self, stub, timeout):
        return hs.SSHConfig(host="selftest", username=USER, hostname="selftest.invalid", use_jump_host=False,
                            jump_hostname=None, control_path=os.path.join(self.root, "ctl.sock"),
                            jump_control_path=None, timeout=timeout, ssh_executable=stub)

    def test_non_utf8_bytes(self):
        output = round_trip_output(jobs_json_status=1, pipe_jobs=(
            f"777|calder-cpu-turin|caf@E9@-run|{USER}|RUNNING|0:10|2-00:00:00|1|calder-c001"))
        stub = self.make_stub("ssh-latin1", output.encode("utf-8").replace(b"@E9@", b"\xe9"))
        snapshot = hs.collect_snapshot(self.config(stub, 10), CALDER, calder_volumes())
        self.assertEqual(snapshot.errors, [])
        self.assertEqual([job.name for job in snapshot.jobs], ["caf�-run"])
        self.assertEqual([row.label for row in snapshot.storage], ["Home", "Scratch"])
        encoded = json.dumps(hs.snapshot_payload(snapshot), ensure_ascii=False).encode("utf-8")
        self.assertIn(b"caf\xef\xbf\xbd-run", encoded)
        self.assertEqual(set(snapshot.timings) >= {"probe", "round_trip", "jobs_json", "storage"}, True)
        self.assertIsNotNone(snapshot.started_at)
        self.assertGreaterEqual(snapshot.duration_ms, 0)

    def test_storage_stall_stays_within_budget(self):
        partial = round_trip_output().split("=====HPC-SECTION:storage=====")[0] + (
            "=====HPC-SECTION:storage=====\n__HPC-VOLUME:0__\n__HPC-PATH__\n/users/u\n")
        stub = self.make_stub("ssh-stall", partial.encode("utf-8"), stall=True)
        budget = 2
        started = time.monotonic()
        snapshot = hs.collect_snapshot(self.config(stub, budget), CALDER, calder_volumes())
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, budget + 3)
        self.assertEqual(snapshot.errors, [])
        self.assertEqual(len(snapshot.partitions), 3)
        self.assertTrue(any("Timed out" in warning and "cut during storage" in warning
                            for warning in snapshot.warnings), snapshot.warnings)
        self.assertEqual([(row.label, row.source) for row in snapshot.storage],
                         [("Home", "unavailable"), ("Scratch", "unavailable"), ("Flash", "unavailable")])
        self.assertTrue(all(row.unavailable_reason in ("no-figures", "not-collected") and "$" not in row.path
                            for row in snapshot.storage))
        self.assertFalse(any("showing filesystem totals" in warning for warning in snapshot.warnings))

    def test_cut_line_is_not_parsed(self):
        """A record cut mid-line by the budget must not read as 'nothing
        allocated': the fragment is dropped and allocation is unknown."""
        head = round_trip_output().split("=====HPC-SECTION:node_details=====")[0]
        cut = head + "=====HPC-SECTION:node_details=====\n" + (
            "NodeName=calder-h200-01 CfgTRES=cpu=128,mem=1546664M,gres/gpu=8 AllocTRES=cpu=64,gr")
        stub = self.make_stub("ssh-cut", cut.encode("utf-8"), stall=True)
        snapshot = hs.collect_snapshot(self.config(stub, 2), CALDER, calder_volumes())
        self.assertEqual(snapshot.errors, [])
        node = {node.node: node for node in snapshot.nodes}["calder-h200-01"]
        self.assertIsNone(node.gpu_allocated)
        self.assertIn("GPU allocation unknown for 4 GPU nodes (node_details unavailable)", snapshot.warnings)
        self.assertTrue(any("cut during node_details" in warning for warning in snapshot.warnings))

    def test_unusable_json_triggers_one_fallback_round_trip(self):
        main = round_trip_output(jobs_json='{"jobs": [1, 2]}')
        fallback = "\n".join([
            "=====HPC-TIME:start:1760270500.000=====",
            "=====HPC-TIME:prelude:1760270500.010=====",
            "=====HPC-SECTION:jobs=====", CANNED_JOBS_PIPE, "=====HPC-STATUS:jobs:0=====",
            "=====HPC-TIME:jobs:1760270500.060=====",
            "=====HPC-SECTION:job_details=====", CANNED_JOB_DETAILS, "=====HPC-STATUS:job_details:0=====",
            "=====HPC-TIME:job_details:1760270500.270=====",
        ]) + "\n"
        stub = self.make_stub("ssh-fallback", main.encode("utf-8"), fallback.encode("utf-8"))
        snapshot = hs.collect_snapshot(self.config(stub, 10), CALDER, calder_volumes())
        self.assertEqual(snapshot.errors, [])
        self.assertEqual(sorted(job.job_id for job in snapshot.jobs), ["35796", "35796_1", "35796_2", "40188", "9918"])
        self.assertIn("Jobs read with the pipe-format fallback (squeue --json has a job record that is not an object)",
                      snapshot.warnings)
        self.assertIn("jobs_fallback_round_trip", snapshot.timings)
        self.assertEqual((snapshot.timings["jobs"], snapshot.timings["job_details"]), (50, 210))
        self.assertEqual(snapshot.timings["prelude"], 22)

    def test_failed_fallback_is_a_core_error(self):
        stub = self.make_stub("ssh-fallback-empty", round_trip_output(jobs_json='{"jobs": [1]}').encode("utf-8"))
        snapshot = hs.collect_snapshot(self.config(stub, 10), CALDER, calder_volumes())
        self.assertEqual(len(snapshot.errors), 1)
        self.assertIn("no pipe-format listing arrived", snapshot.errors[0])
        self.assertIn("jobs_fallback_round_trip", snapshot.timings)

    def test_fallback_that_runs_out_of_budget_reports_why(self):
        stub = self.make_stub("ssh-fallback-stall", round_trip_output(jobs_json='{"jobs": [1]}').encode("utf-8"))
        # The stub stalls after printing; for the main round trip that means
        # the budget runs out first, so make only the fallback stall.
        with open(stub, encoding="utf-8") as handle:
            body = handle.read()
        body = body.replace(
            '"# hpc-round-trip: jobs-fallback"*) cat',
            '"# hpc-round-trip: jobs-fallback"*) exec sleep 30; cat',
        )
        with open(stub, "w", encoding="utf-8") as handle:
            handle.write(body)
        started = time.monotonic()
        snapshot = hs.collect_snapshot(self.config(stub, 3), CALDER, calder_volumes())
        self.assertLess(time.monotonic() - started, 3 + 3)
        self.assertIn("Timed out after", snapshot.errors[0])
        self.assertIn("(pipe-format jobs fallback)", snapshot.errors[0])
        self.assertTrue(any("no pipe-format listing arrived" in error for error in snapshot.errors), snapshot.errors)

    def test_skip_storage(self):
        stub = self.make_stub("ssh-skip", round_trip_output(include_storage=False).encode("utf-8"))
        snapshot = hs.collect_snapshot(self.config(stub, 10), CALDER, calder_volumes(), skip_storage=True)
        self.assertEqual((snapshot.errors, snapshot.warnings), ([], []))
        self.assertIsNone(snapshot.storage)
        self.assertTrue(snapshot.storage_skipped)

    def test_dead_master_short_circuits(self):
        stub = self.make_stub("ssh-dead", b"", probe_rc=255)
        snapshot = hs.collect_snapshot(self.config(stub, 10), CALDER, calder_volumes())
        self.assertEqual(len(snapshot.errors), 1)
        self.assertIn("control master is not running", snapshot.errors[0])
        self.assertFalse(os.path.exists(self.round_trip_marker))
        self.assertIn("probe", snapshot.timings)

    def test_lenient_decoding(self):
        decoded = hs.run_captured(["/bin/sh", "-c", "printf 'caf\\351\\n'"], 10).stdout
        self.assertEqual(decoded, "caf�\n")


# ---------------------------------------------------------------------------
# CLI and SSH command construction
# ---------------------------------------------------------------------------


class CLITests(unittest.TestCase):
    def test_arguments(self):
        legacy = hs.parse_args(["--username", "u", "--aire-hostname", "aire.leeds.ac.uk"])
        self.assertEqual(legacy.hostname, "aire.leeds.ac.uk")
        args = hs.parse_args(["--cluster-id", "calder", "--hostname", "calder.leeds.ac.uk"])
        self.assertEqual((args.hostname, args.cluster_id, args.timeout, args.skip_storage),
                         ("calder.leeds.ac.uk", "calder", hs.DEFAULT_TIMEOUT, False))
        self.assertTrue(hs.parse_args(["--skip-storage"]).skip_storage)

    def test_timeout_validation(self):
        for bad in ("0", "-5", "ten"):
            with self.subTest(bad=bad):
                with self.assertRaises(argparse.ArgumentTypeError):
                    hs.positive_int(bad)

    def test_cluster_names(self):
        self.assertEqual([hs.default_cluster_name(name) for name in ("calder", "aire", "x1")], ["Calder", "AIRE", "X1"])

    def test_refuses_option_like_host(self):
        hostile = hs.SSHConfig(host="aire", username="u", hostname="-oProxyCommand=evil", use_jump_host=False,
                               jump_hostname=None, control_path=None, jump_control_path=None, timeout=5)
        self.assertIsNone(hs.build_ssh_command(hostile, "true")[0])

    def test_jump_command(self):
        command, error = hs.build_ssh_command(
            hs.SSHConfig(host="calder", username="u", hostname="calder.leeds.ac.uk", use_jump_host=True,
                         jump_hostname="rash.leeds.ac.uk", control_path="/tmp/t.sock",
                         jump_control_path="/tmp/j.sock", timeout=5),
            "true",
        )
        self.assertIsNone(error)
        self.assertEqual(command[-2], "calder.leeds.ac.uk")
        self.assertTrue(any("ControlPath=/tmp/j.sock" in part for part in command))
        self.assertNotIn("ControlMaster=auto", " ".join(command))


# ---------------------------------------------------------------------------
# The contract with the app
# ---------------------------------------------------------------------------


class ContractFixtureTests(unittest.TestCase):
    def load(self, path):
        if not os.path.exists(path):
            self.fail(f"{os.path.relpath(path, PROJECT_ROOT)} is missing: run "
                      "python3 scripts/tests/test_snapshot.py --write-fixture")
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)

    def test_fixture_is_current(self):
        """The checked-in fixture is exactly what the collector prints for the
        canned refresh. When this fails, the collector's output changed:
        regenerate (--write-fixture), then make sure the Swift contract test
        (CollectorContractTests) still passes before committing."""
        expected = build_snapshot_fixture()
        actual = self.load(SNAPSHOT_FIXTURE)
        if actual != expected:
            differing = sorted(key for key in set(expected) | set(actual) if expected.get(key) != actual.get(key))
            self.fail("Tests/Fixtures/collector_snapshot.json is out of date (differs in "
                      f"{', '.join(differing)}): run python3 scripts/tests/test_snapshot.py --write-fixture")

    def test_contract_constants_are_current(self):
        self.assertEqual(self.load(CONTRACT_FIXTURE), build_contract_constants(),
                         "Tests/Fixtures/collector_contract.json is out of date: run "
                         "python3 scripts/tests/test_snapshot.py --write-fixture")

    def test_fixture_covers_the_contract(self):
        payload = build_snapshot_fixture()
        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual((payload["errors"], payload["warnings"]), ([], []))
        jobs = {job["job_id"]: job for job in payload["jobs"]}
        self.assertEqual(jobs["35796"]["array_pending_tasks"], "3-58")
        self.assertEqual(jobs["35796"]["pending_task_count"], 56)
        self.assertEqual(jobs["35796_1"]["array_job_id"], 35796)
        nodes = {node["node"]: node for node in payload["nodes"]}
        self.assertEqual(nodes["calder-h200-02"]["gpu_allocated"], 0)
        self.assertIsNone(nodes["calder-l40-01"]["gpu_allocated"])
        self.assertEqual(nodes["calder-h200-05"]["reason"], NHC_REASON)
        self.assertEqual([row["label"] for row in payload["storage"]], ["Home", "Scratch"])
        # Dates are rendered in UTC for the fixture, whatever the host's TZ.
        self.assertEqual(jobs["40188"]["start_time"], "2026-10-12T08:34:50")


class JobUsageParsingTests(unittest.TestCase):
    def test_hostlists_and_indices(self):
        self.assertEqual(hs.expand_hostlist("calder-h200-[01-03,07]"),
                         ["calder-h200-01", "calder-h200-02", "calder-h200-03", "calder-h200-07"])
        self.assertEqual(hs.expand_hostlist("gpu001,cpu[9-10]"), ["gpu001", "cpu9", "cpu10"])
        self.assertEqual(hs.parse_index_list("0-3,8,x,10-11"), [0, 1, 2, 3, 8, 10, 11])

    def test_allocation_line(self):
        allocation = hs.parse_job_allocation(
            "Nodes=calder-h200-[01-02] CPU_IDs=0-31,64-95 Mem=256000 GRES=gpu:nvidia_h200:4(IDX:0-3)")
        self.assertEqual(allocation, {"nodes": ["calder-h200-01", "calder-h200-02"], "cpus": 64,
                                      "memory_mb": 256000, "gpu_indices": [0, 1, 2, 3]})
        self.assertEqual(hs.parse_job_allocation("Nodes=cpu1 CPU_IDs=4 Mem=1000 GRES=")["gpu_indices"], [])

    def test_gpu_rows(self):
        row = hs.parse_gpu_usage_line("2, NVIDIA H200, 97, 41, 70123, 143771, 655.30, 700.00, 61")
        self.assertEqual((row.index, row.name, row.utilization_percent, row.memory_used_mb, row.power_watts),
                         (2, "NVIDIA H200", 97.0, 70123.0, 655.3))
        self.assertIsNone(hs.parse_gpu_usage_line("0, NVIDIA L40S, [N/A], 0, 1, 2, [Not Supported], 3, 4")
                          .utilization_percent)
        self.assertIsNone(hs.parse_gpu_usage_line("No devices were found"))

    def test_section(self):
        text = "\n".join([
            "job|500|500|gpu01",
            "detail|500|Nodes=gpu01 CPU_IDs=0-7 Mem=64000 GRES=gpu:h200:2(IDX:0-1)",
            "on|gpu01|500",
            "job|501|77_3|gpu01",
            "detail|501|Nodes=gpu01 CPU_IDs=8-15 Mem=64000 GRES=gpu:h200:2(IDX:2-3)",
            "on|gpu01|501",
            "job|502|502|gone01",
            "on|gone01|502",
            "job|503|503|slow01",
            "on|slow01|503",
            "node|gpu01|t|0|1000.0",
            "node|gpu01|cg|0|500|1000000|0|0|0|max",
            "node|gpu01|cg|0|501|5000000|0|0|0|max",
            "node|gpu01|self|0::/system.slice/slurmstepd.scope/job_500/step_extern/user/task_special",
            "node|gpu01|gpu|0, NVIDIA H200, 97, 40, 70000, 143771, 650, 700, 60",
            "node|gpu01|gpu|1, NVIDIA H200, 12, 3, 9000, 143771, 120, 700, 41",
            "node|gpu01|t|1|1001.0",
            "node|gpu01|cg|1|500|7000000|2147483648|4294967296|5368709120|68719476736",
            "node|gpu01|cg|1|501|5100000|1048576|1048576|1048576|max",
            "node|gpu01|rc|0",
            "node|gone01|Access denied: user alice (uid=1) has no active jobs on this node.",
            "node|gone01|rc|255",
            "node|slow01|rc|124",
        ])
        usage = {(row.job_id, row.node): row for row in hs.parse_job_usage(text)}
        first = usage[("500", "gpu01")]
        self.assertEqual(first.cpus_allocated, 8)
        self.assertEqual(first.cpus_busy, 6.0)
        self.assertEqual((first.memory_used_mb, first.memory_charged_mb, first.memory_peak_mb, first.memory_limit_mb),
                         (2048.0, 4096.0, 5120.0, 65536.0))
        self.assertEqual([gpu.index for gpu in first.gpus], [0, 1])
        self.assertIsNone(first.note)
        second = usage[("501", "gpu01")]
        self.assertEqual(second.display_id, "77_3")
        self.assertEqual(second.cpus_busy, 0.1)
        self.assertEqual(second.memory_limit_mb, 64000.0)
        self.assertEqual(second.gpus, [])
        self.assertIn("come from your job 500", second.note)
        self.assertIn("ended before", usage[("502", "gone01")].note)
        self.assertIn("in time", usage[("503", "slow01")].note)

    def test_not_requested_means_not_sampled(self):
        snapshot = assemble(round_trip_output())
        self.assertIsNone(snapshot.job_usage)
        self.assertFalse(any("job_usage" in warning for warning in snapshot.warnings))


@unittest.skipUnless(os.path.exists("/bin/sh") and shutil.which("awk"), "needs /bin/sh and awk")
class JobUsageScriptTests(unittest.TestCase):
    """The job_usage section run for real, in every available shell, with
    stub squeue/scontrol/ssh/nvidia-smi/date/sleep and fake cgroup files.
    The ssh stub runs the probe locally as if on the named node."""

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="hpc-usage-test.")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.bin = os.path.join(self.root, "bin")
        os.makedirs(self.bin)
        root = hs.shell_single_quote(self.root)
        _write_stub(self.bin, "squeue", 'printf "500|500|gpu01\\n501|77_3|cpu[01-02]\\n502|502|gone01\\n"\n')
        _write_stub(self.bin, "scontrol", (
            'if [ "$1" = show ] && [ "$2" = hostnames ]; then\n'
            '  case "$3" in "cpu[01-02]") printf "cpu01\\ncpu02\\n" ;; *) printf "%s\\n" "$3" ;; esac; exit 0\n'
            'fi\n'
            'case "$4" in\n'
            '500) printf "JobId=500 JobName=train\\n   Nodes=gpu01 CPU_IDs=0-3 Mem=8000 GRES=gpu:h200:2(IDX:0-1)\\n" ;;\n'
            '501) printf "JobId=501\\n   Nodes=cpu[01-02] CPU_IDs=0-1 Mem=2000 GRES=\\n" ;;\n'
            '502) printf "JobId=502\\n   Nodes=gone01 CPU_IDs=0 Mem=100 GRES=\\n" ;;\n'
            'esac\n'
        ))
        _write_stub(self.bin, "timeout", 'shift\nexec "$@"\n')
        _write_stub(self.bin, "ssh", (
            'while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -T|-x) shift ;; *) break ;; esac; done\n'
            'host=$1; shift\n'
            'if [ "$host" = gone01 ]; then echo "Access denied: user alice (uid=1) has no active jobs on this node." >&2; exit 1; fi\n'
            'HPC_TEST_NODE=$host; HPC_CGROUP_ROOT=' + root + '/cg/$host; HPC_SELF_CGROUP=' + root + '/cg/$host/self\n'
            'export HPC_TEST_NODE HPC_CGROUP_ROOT HPC_SELF_CGROUP\n'
            'exec "$@"\n'
        ))
        # Each node's clock: date prints it, sleep advances it by one second
        # and charges the jobs' cgroups 2 s (gpu01) or 0.5 s (cpu nodes) of CPU.
        _write_stub(self.bin, "date", 'cat "$HPC_CGROUP_ROOT/clock" 2>/dev/null || echo 1000.0\n')
        _write_stub(self.bin, "sleep", (
            '[ -n "${HPC_CGROUP_ROOT:-}" ] || exit 0\n'
            'echo 1001.0 > "$HPC_CGROUP_ROOT/clock"\n'
            'for f in "$HPC_CGROUP_ROOT"/system.slice/slurmstepd.scope/job_*/cpu.stat; do\n'
            '  read -r key value < "$f"; printf "usage_usec %s\\n" $((value + $(cat "$HPC_CGROUP_ROOT/charge"))) > "$f"\n'
            'done\n'
        ))
        _write_stub(self.bin, "nvidia-smi", (
            'case "$HPC_TEST_NODE" in\n'
            'gpu01) printf "0, NVIDIA H200, 95, 40, 70000, 143771, 650.5, 700.0, 60\\n1, NVIDIA H200, 15, 2, 4000, 143771, 120.0, 700.0, 40\\n" ;;\n'
            '*) echo "NVIDIA-SMI has failed because it couldn\'t communicate with the NVIDIA driver."; exit 9 ;;\n'
            'esac\n'
        ))
        self.env = {"PATH": self.bin + os.pathsep + "/usr/bin:/bin", "USER": "alice", "HOME": self.root,
                    "LC_ALL": "C"}
        for node, jobs, charge in (("gpu01", ["500"], 2000000), ("cpu01", ["501"], 500000), ("cpu02", ["501"], 500000)):
            base = os.path.join(self.root, "cg", node)
            for job in jobs:
                directory = os.path.join(base, "system.slice", "slurmstepd.scope", "job_" + job)
                os.makedirs(directory)
                for name, content in (("cpu.stat", "usage_usec 1000000\n"),
                                      ("memory.stat", "anon 1073741824\nfile 5\n"),
                                      ("memory.current", "2147483648\n"), ("memory.peak", "3221225472\n"),
                                      ("memory.max", "max\n")):
                    with open(os.path.join(directory, name), "w") as handle:
                        handle.write(content)
            with open(os.path.join(base, "charge"), "w") as handle:
                handle.write(str(charge))
            with open(os.path.join(base, "clock"), "w") as handle:
                handle.write("1000.0\n")
            with open(os.path.join(base, "self"), "w") as handle:
                handle.write("0::/system.slice/slurmstepd.scope/job_%s/step_extern/user/task_special\n" % jobs[0])

    def reset_clocks(self):
        for node in ("gpu01", "cpu01", "cpu02"):
            base = os.path.join(self.root, "cg", node)
            with open(os.path.join(base, "clock"), "w") as handle:
                handle.write("1000.0\n")
            for job in os.listdir(os.path.join(base, "system.slice", "slurmstepd.scope")):
                with open(os.path.join(base, "system.slice", "slurmstepd.scope", job, "cpu.stat"), "w") as handle:
                    handle.write("usage_usec 1000000\n")

    def test_section_in_every_shell(self):
        script = hs.build_remote_script([], include_storage=False, include_job_usage=True)
        for shell in available_shells():
            with self.subTest(shell=shell):
                self.reset_clocks()
                completed = subprocess.run([shell, "-c", script], check=False, capture_output=True, text=True,
                                           env=self.env, cwd=self.root, stdin=subprocess.DEVNULL, timeout=60)
                sections, statuses = hs.split_sections(completed.stdout)
                self.assertEqual(statuses.get("job_usage"), 0, completed.stdout + completed.stderr)
                usage = {(row.job_id, row.node): row for row in hs.parse_job_usage(sections["job_usage"])}
                self.assertEqual(sorted(usage), [("500", "gpu01"), ("501", "cpu01"), ("501", "cpu02"),
                                                 ("502", "gone01")])
                gpu = usage[("500", "gpu01")]
                self.assertEqual((gpu.cpus_allocated, gpu.cpus_busy), (4, 2.0))
                self.assertEqual((gpu.memory_used_mb, gpu.memory_charged_mb, gpu.memory_peak_mb, gpu.memory_limit_mb),
                                 (1024.0, 2048.0, 3072.0, 8000.0))
                self.assertEqual([(g.index, g.utilization_percent) for g in gpu.gpus], [(0, 95.0), (1, 15.0)])
                self.assertIsNone(gpu.note)
                cpu = usage[("501", "cpu02")]
                self.assertEqual((cpu.display_id, cpu.cpus_busy, cpu.gpus, cpu.note), ("77_3", 0.5, [], None))
                self.assertIn("ended before", usage[("502", "gone01")].note)

    def test_snapshot_carries_usage_only_when_asked(self):
        script = hs.build_remote_script([], include_storage=False, include_job_usage=True)
        completed = subprocess.run(["/bin/sh", "-c", script], check=False, capture_output=True, text=True,
                                   env=self.env, cwd=self.root, stdin=subprocess.DEVNULL, timeout=60)
        config = calder_config(username="alice")
        asked = hs.assemble_snapshot(config, CALDER, [], "now", completed.stdout, None, False,
                                     skip_storage=True, job_usage=True)
        self.assertEqual(len(asked.job_usage), 4)
        payload = json.loads(json.dumps(hs.snapshot_payload(asked)))
        self.assertEqual(payload["job_usage"][0]["gpus"][0]["name"], "NVIDIA H200")
        not_asked = hs.assemble_snapshot(config, CALDER, [], "now", completed.stdout, None, False,
                                         skip_storage=True, job_usage=False)
        self.assertIsNone(not_asked.job_usage)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--write-fixture" in argv:
        write_fixtures()
        return 0
    program = unittest.main(module=__name__, argv=[sys.argv[0]] + argv, exit=False, verbosity=1)
    return 0 if program.result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
