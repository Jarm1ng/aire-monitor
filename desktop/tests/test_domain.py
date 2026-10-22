"""The macOS app's domain rules, ported to the desktop app, tested with the
same tables as the Swift suite (Tests/AIREMonitorAppTests: CoreSlurmStateTests,
CoreGPUTests, CoreJobTests, the storage tone and storage cadence tests), so
both front ends show the same figures for one snapshot.

Standard library and pytest only: this file runs on any machine.
"""

import json
from datetime import datetime, timezone
from pathlib import Path

import pytest

from leeds_hpc_desktop import core, rules
from leeds_hpc_desktop.core import validate_snapshot
from leeds_hpc_desktop.rules import (
    GPUFleet,
    JobQueueCounts,
    JobState,
    NodeState,
    StorageTracker,
    cluster_figures,
    cpus_full,
    display_job_id,
    gpu_model_display_name,
    history_gpu_text,
    history_point,
    is_array_remainder,
    is_held,
    job_change_messages,
    job_sort_key,
    known_gpu_allocated,
    merge_storage,
    node_gpu_count,
    parse_slurm_time,
    slurm_gpu_model,
    slurm_gpu_model_display_name,
    slurm_gpu_total,
    storage_carries_earlier_rows,
    storage_file_count_dominates,
    storage_file_used_percent,
    storage_pressure_percent,
    storage_tone,
    task_multiplicity,
    trend_gpu_value,
    usage_tone,
)

# ---------------------------------------------------------------------------
# Fixtures: CoreFixtures.swift's AIRE and Calder rows (anonymised; modelled on
# real rows from 13 October 2026), built the same way.
# ---------------------------------------------------------------------------


def aire_gpu_node(name, cpu_allocated, gpu_allocated, state="mix"):
    down = not NodeState.parse(state).available
    return {
        "node": name,
        "partitions": ["gpu"],
        "state": state,
        "cpu_allocated": 0 if down else cpu_allocated,
        "cpu_idle": 0 if down else 24 - cpu_allocated,
        "cpu_other": 24 if down else 0,
        "cpu_total": 24,
        "gres": "gpu:l40s:3",
        "gpu_total": 3,
        "gpu_allocated": gpu_allocated,
        "gpu_idle": None if gpu_allocated is None else 3 - gpu_allocated,
    }


def aire_cpu_node(name, partitions, state, cpu_allocated):
    return {
        "node": name,
        "partitions": partitions,
        "state": state,
        "cpu_allocated": cpu_allocated,
        "cpu_idle": 168 - cpu_allocated,
        "cpu_other": 0,
        "cpu_total": 168,
        "gres": "",
        "gpu_total": 0,
        "gpu_allocated": 0,
        "gpu_idle": 0,
    }


# 14 GPU nodes (42 L40S): 31 allocated, 4 idle and startable (gpu001 1,
# gpu002 2, gpu010 1), 1 stranded (gpu018), 6 unavailable on 2 down$ nodes.
AIRE_NODES = [
    aire_gpu_node("gpu001", 23, 2),
    aire_gpu_node("gpu002", 10, 1),
    aire_gpu_node("gpu003", 24, 3, "alloc"),
    aire_gpu_node("gpu004", 22, 3),
    aire_gpu_node("gpu005", 12, 3),
    aire_gpu_node("gpu006", 22, 3),
    aire_gpu_node("gpu007", 17, 3),
    aire_gpu_node("gpu008", 17, 3),
    aire_gpu_node("gpu009", 22, 3),
    aire_gpu_node("gpu010", 21, 2),
    aire_gpu_node("gpu018", 24, 2, "alloc"),
    aire_gpu_node("gpu020", 24, 3, "alloc"),
    aire_gpu_node("gpu021", 0, None, "down$"),
    aire_gpu_node("gpu028", 0, None, "down$"),
    aire_cpu_node("node001", ["nodes"], "mix", 133),
    aire_cpu_node("node002", ["nodes"], "alloc", 168),
    aire_cpu_node("node003", ["nodes"], "mix", 96),
    aire_cpu_node("node042", ["nodes", "teachingnodes"], "mix", 149),
    aire_cpu_node("node049", ["nodes", "teachingnodes"], "alloc", 168),
    aire_cpu_node("himem01", ["himem"], "mix", 60),
    aire_cpu_node("himem02", ["himem"], "mix", 24),
]


def calder_h200_node(name, state, cpu_allocated, gpu_allocated):
    usable = NodeState.parse(state).available
    return {
        "node": name,
        "partitions": ["calder-gpu-hopper"],
        "state": state,
        "cpu_allocated": cpu_allocated if usable else 0,
        "cpu_idle": 128 - cpu_allocated if usable else 0,
        "cpu_other": 0 if usable else 128,
        "cpu_total": 128,
        "gres": "gpu:nvidia_h200:8",
        "gpu_total": 8,
        "gpu_allocated": gpu_allocated,
        "gpu_idle": None if gpu_allocated is None else 8 - gpu_allocated,
    }


def calder_cpu_node(name, state, cpu_allocated, partition="calder-cpu-turin", cpu_total=128):
    usable = NodeState.parse(state).available
    return {
        "node": name,
        "partitions": [partition],
        "state": state,
        "cpu_allocated": cpu_allocated if usable else 0,
        "cpu_idle": cpu_total - cpu_allocated if usable else 0,
        "cpu_other": 0 if usable else cpu_total,
        "cpu_total": cpu_total,
        "gres": "",
        "gpu_total": 0,
        "gpu_allocated": 0,
        "gpu_idle": 0,
    }


# H200 pool: 7 nodes, 56 GPUs — 32 allocated, 16 idle and startable, 8
# unavailable on the drained h200-05. L40 pool: one drained, not-responding
# node hosted for AIRE, 3 GPUs unavailable.
CALDER_NODES = [
    calder_h200_node("calder-h200-01", "mix-", 64, 8),
    calder_h200_node("calder-h200-02", "mix-", 64, 8),
    calder_h200_node("calder-h200-03", "mix-", 88, 7),
    calder_h200_node("calder-h200-04", "mix-", 36, 3),
    calder_h200_node("calder-h200-05", "drain", 0, None),
    calder_h200_node("calder-h200-06", "mix", 53, 5),
    calder_h200_node("calder-h200-07", "mix", 16, 1),
    {
        "node": "gpu028",
        "partitions": ["aire-gpu-lovelace"],
        "state": "drain*",
        "cpu_allocated": 0,
        "cpu_idle": 0,
        "cpu_other": 24,
        "cpu_total": 24,
        "gres": "gpu:nvidia_l40:3",
        "gpu_total": 3,
        "gpu_allocated": None,
        "gpu_idle": None,
    },
    calder_cpu_node("calder-cpu001", "mix", 120),
    calder_cpu_node("calder-cpu008", "alloc", 128),
    calder_cpu_node("calder-cpu020", "idle", 0),
    calder_cpu_node("calder-cpu021", "idle", 0),
    calder_cpu_node("calder-cpu091", "down*", 0),
    calder_cpu_node("calder-cpu098", "down$", 0),
    calder_cpu_node("node056", "drain$", 0, "aire-cpu-genoa", 168),
    calder_cpu_node("node057", "drain*", 0, "aire-cpu-genoa", 168),
    calder_cpu_node("node058", "drain", 0, "aire-cpu-genoa", 168),
]

CALDER_PARTITIONS = [
    ("aire-cpu-genoa", 1, "drain$"),
    ("aire-cpu-genoa", 2, "drain*"),
    ("aire-cpu-genoa", 5, "drain"),
    ("calder-cpu-turin", 1, "down$"),
    ("calder-cpu-turin", 1, "down*"),
    ("calder-cpu-turin", 36, "mix"),
    ("calder-cpu-turin", 2, "alloc"),
    ("calder-cpu-turin", 58, "idle"),
]


def job(job_id, state="PENDING", reason="", node_list=None, **extra):
    running = JobState.parse(state).occupies_nodes
    return {
        "job_id": job_id,
        "state": state,
        "reason_or_node_list": (node_list or "") if running else reason,
        **extra,
    }


def array_task(job_id, node_list):
    return job(job_id, "RUNNING", node_list=node_list, array_job_id=int(job_id.split("_")[0]))


# A GPU array (two running tasks plus a pending remainder of 57 tasks), jobs
# waiting on priority and on dependencies.
AIRE_JOBS = [
    job("8247672", reason="(Dependency)"),
    array_task("8248307_0", "gpu003"),
    job("8248326", reason="(Priority)"),
    job("8248328", reason="(Dependency)"),
    job("8248684", reason="(Dependency)"),
    array_task("8248307_1", "gpu020"),
    job(
        "8248307",
        reason="(Priority)",
        array_job_id=8248307,
        array_pending_tasks="2-58",
        array_throttle=4,
        pending_task_count=57,
    ),
]

CALDER_JOBS = [
    job("9863", reason="(JobHeldUser)"),
    job("9926", "RUNNING", node_list="calder-cpu001"),
    array_task("35796_1", "calder-h200-06"),
    array_task("38961_2", "calder-h200-03"),
    job("48081", "RUNNING", node_list="calder-cpu008"),
    job("64375", reason="(Resources)", array_job_id=64375, array_pending_tasks="4-20", pending_task_count=17),
]


# ---------------------------------------------------------------------------
# Node states (CoreSlurmStateTests · node states)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "raw,base,available",
    [
        ("idle", "idle", True),
        ("mix", "mixed", True),
        ("alloc", "allocated", True),
        ("comp", "completing", True),
        ("plnd", "planned", True),
        ("drng", "draining", False),
        ("drain", "drained", False),
        ("down", "down", False),
        ("fail", "failed", False),
        ("failg", "failing", False),
        ("maint", "maintenance", False),
        ("resv", "reserved", False),
        ("futr", "future", False),
        ("blocked", "blocked", False),
        ("inval", "invalid", False),
        ("boot", "booting", False),
        ("pow_dn", "powered_down", False),
        ("unk", "unknown", False),
        ("", "unknown", False),
        ("npc", "unknown", False),
    ],
)
def test_compact_base_states(raw, base, available):
    info = NodeState.parse(raw)
    assert info.base == base
    assert info.available == available
    assert info.raw == raw


@pytest.mark.parametrize(
    "raw,base,available,not_responding,maintenance,planned",
    [
        ("mix-", "mixed", True, False, False, True),
        ("down$", "down", False, False, True, False),
        ("down*", "down", False, True, False, False),
        ("drain", "drained", False, False, False, False),
        ("drain*", "drained", False, True, False, False),
        ("drain$", "drained", False, False, True, False),
        ("idle$", "idle", False, False, True, False),
        ("idle*", "idle", False, True, False, False),
        ("mix*", "mixed", False, True, False, False),
        ("alloc$", "allocated", False, False, True, False),
        ("drain$*", "drained", False, True, True, False),
    ],
)
def test_flagged_states_seen_on_aire_and_calder(raw, base, available, not_responding, maintenance, planned):
    info = NodeState.parse(raw)
    assert info.base == base
    assert info.available == available
    assert info.not_responding == not_responding
    assert info.maintenance_reservation == maintenance
    assert info.planned_by_backfill == planned


def test_maintenance_reservation_is_never_free_capacity():
    info = NodeState.parse("idle$")
    assert info.base == "idle"
    assert not info.available
    assert info.flag_descriptions == ["in a maintenance reservation"]


@pytest.mark.parametrize(
    "raw,available,power_saving,powering_down,reboot",
    [
        ("idle~", True, True, False, False),
        ("idle#", True, True, False, False),
        ("idle%", False, False, True, False),
        ("idle!", False, False, True, False),
        ("mix@", False, False, False, True),
        ("idle^", False, False, False, True),
    ],
)
def test_power_and_reboot_flags(raw, available, power_saving, powering_down, reboot):
    # "~"/"#": powered off or powering up for energy saving, which the
    # scheduler resumes on demand, so the node still counts.
    info = NodeState.parse(raw)
    assert info.base in ("idle", "mixed")
    assert info.available == available
    assert info.power_saving == power_saving
    assert info.powering_down == powering_down
    assert info.reboot_pending == reboot


@pytest.mark.parametrize("raw", ["MIX-", " mix- ", "Mix-\n"])
def test_case_and_whitespace_do_not_matter(raw):
    info = NodeState.parse(raw)
    assert info.base == "mixed"
    assert info.planned_by_backfill
    assert info.available


@pytest.mark.parametrize(
    "raw,base,available",
    [
        ("MIXED", "mixed", True),
        ("ALLOCATED", "allocated", True),
        ("IDLE+PLANNED", "planned", True),
        ("MIXED+PLANNED", "mixed", True),
        ("IDLE+DRAIN", "drained", False),
        ("DOWN+DRAIN", "drained", False),
        ("MIXED+DRAIN", "draining", False),
        ("ALLOCATED+DRAIN", "draining", False),
        ("IDLE+DRAIN+NOT_RESPONDING", "drained", False),
        ("DOWN+NOT_RESPONDING", "down", False),
        ("IDLE+MAINT", "idle", False),
        ("IDLE+REBOOT_REQUESTED", "idle", False),
        ("IDLE+CLOUD", "idle", True),
    ],
)
def test_long_forms(raw, base, available):
    info = NodeState.parse(raw)
    assert info.base == base
    assert info.available == available


@pytest.mark.parametrize(
    "long,compact",
    [
        ("IDLE+DRAIN", "drain"),
        ("MIXED+DRAIN", "drng"),
        ("DOWN+NOT_RESPONDING", "down*"),
        ("IDLE+MAINT", "idle$"),
        ("MIXED+PLANNED", "mix-"),
        ("IDLE+REBOOT_REQUESTED", "idle@"),
        # POWERED_DOWN is "~" (the scheduler resumes it), not "%"/"!".
        ("IDLE+POWERED_DOWN", "idle~"),
        # FAIL is "fail"/"failg": the admins expect the node to fail.
        ("IDLE+FAIL", "fail"),
        ("MIXED+FAIL", "failg"),
        # A node in an advanced reservation is "resv".
        ("IDLE+RESERVED", "resv"),
    ],
)
def test_long_form_agrees_with_its_compact_code(long, compact):
    long_info, compact_info = NodeState.parse(long), NodeState.parse(compact)
    assert long_info.base == compact_info.base
    assert long_info.available == compact_info.available
    assert long_info.flag_descriptions == compact_info.flag_descriptions


@pytest.mark.parametrize(
    "raw,label",
    [
        ("mix-", "Mixed"),
        ("drain*", "Drained"),
        ("drng", "Draining"),
        ("down$", "Down"),
        ("plnd", "Idle (planned)"),
        ("alloc", "Allocated"),
        ("pow_dn", "Powered down"),
        ("", "Unknown"),
        # An unfamiliar state is shown as Slurm spelled it rather than guessed.
        ("npc", "NPC"),
        # sinfo's own spelling of UNKNOWN reads as a word.
        ("unk", "Unknown"),
        ("UNKNOWN*", "Unknown"),
    ],
)
def test_node_labels_are_plain_words(raw, label):
    assert NodeState.parse(raw).label == label


@pytest.mark.parametrize(
    "raw,descriptions",
    [
        ("mix", []),
        ("down*", ["not responding"]),
        ("mix-", ["planned by backfill for a queued job"]),
        ("drain$*", ["not responding", "in a maintenance reservation"]),
        ("idle~", ["powered down to save energy"]),
        ("idle%", ["powering down"]),
        ("mix@", ["reboot pending"]),
    ],
)
def test_flag_descriptions_in_a_fixed_order(raw, descriptions):
    assert NodeState.parse(raw).flag_descriptions == descriptions


def test_node_description_names_the_flags():
    assert NodeState.parse("down$").description == "Down (in a maintenance reservation)"
    assert NodeState.parse("mix").description == "Mixed"


def test_every_fixture_nodes_availability_follows_its_state():
    unavailable = [n["node"] for n in AIRE_NODES + CALDER_NODES if not NodeState.parse(n["state"]).available]
    assert unavailable == [
        "gpu021",
        "gpu028",
        "calder-h200-05",
        "gpu028",
        "calder-cpu091",
        "calder-cpu098",
        "node056",
        "node057",
        "node058",
    ]


def test_an_up_partition_whose_every_row_is_drained_offers_no_capacity():
    # Calder's aire-cpu-genoa: sinfo says "up", but its rows are drain$,
    # drain* and drain.
    genoa = [row for row in CALDER_PARTITIONS if row[0] == "aire-cpu-genoa"]
    assert not any(NodeState.parse(state).available for _, _, state in genoa)
    assert sum(count for _, count, _ in genoa) == 8
    turin = [row for row in CALDER_PARTITIONS if row[0] == "calder-cpu-turin"]
    assert sum(count for _, count, state in turin if NodeState.parse(state).available) == 96


# ---------------------------------------------------------------------------
# Job states (CoreSlurmStateTests · job states)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "raw,kind",
    [
        ("RUNNING", "running"),
        ("R", "running"),
        ("PENDING", "pending"),
        ("PD", "pending"),
        ("SUSPENDED", "suspended"),
        ("S", "suspended"),
        ("STOPPED", "suspended"),
        ("ST", "suspended"),
        ("COMPLETING", "completing"),
        ("CG", "completing"),
        ("CONFIGURING", "configuring"),
        ("CF", "configuring"),
        ("REQUEUED", "requeued"),
        ("RQ", "requeued"),
        ("REQUEUE_HOLD", "requeued"),
        ("RH", "requeued"),
        ("REQUEUE_FED", "requeued"),
        ("RF", "requeued"),
        ("COMPLETED", "finished"),
        ("CD", "finished"),
        ("FAILED", "finished"),
        ("TIMEOUT", "finished"),
        ("OUT_OF_MEMORY", "finished"),
        ("NODE_FAIL", "finished"),
        ("PREEMPTED", "finished"),
        ("BOOT_FAIL", "finished"),
        ("DEADLINE", "finished"),
        ("REVOKED", "finished"),
        ("SPECIAL_EXIT", "finished"),
        # Case, whitespace and trailing flags are ignored.
        ("running", "running"),
        (" PENDING\n", "pending"),
        ("CANCELLED by 12345", "finished"),
        ("RUNNING+SIGNALING", "running"),
        # Unfamiliar states are kept, not guessed.
        ("RESIZING", "other"),
        ("", "other"),
    ],
)
def test_job_states(raw, kind):
    assert JobState.parse(raw).kind == kind


def test_suspended_is_neither_pending_nor_running():
    # The substring parser read "SUSPENDED" as pending because of "pend".
    state = JobState.parse("SUSPENDED")
    assert not state.is_pending and not state.is_running and not state.occupies_nodes
    assert not state.is_finished
    assert state.label == "Suspended"


def test_which_job_states_hold_nodes_wait_or_are_over():
    assert JobState.parse("RUNNING").is_running and JobState.parse("RUNNING").occupies_nodes
    for raw in ("COMPLETING", "CONFIGURING"):
        state = JobState.parse(raw)
        assert state.occupies_nodes and not state.is_running and not state.is_pending
    assert JobState.parse("REQUEUED").is_pending
    assert not JobState.parse("PENDING").occupies_nodes
    for raw in ("COMPLETED", "FAILED", "TIMEOUT", "CANCELLED"):
        state = JobState.parse(raw)
        assert state.is_finished and not state.occupies_nodes and not state.is_pending
    assert not JobState.parse("STAGE_OUT").occupies_nodes


@pytest.mark.parametrize(
    "raw,label",
    [
        ("PD", "Pending"),
        ("R", "Running"),
        ("CG", "Completing"),
        ("RH", "Requeued"),
        ("TIMEOUT", "Timeout"),
        ("OUT_OF_MEMORY", "Out of memory"),
        ("NODE_FAIL", "Node fail"),
        ("", "Unknown"),
        ("SIGNALING", "Signaling"),
    ],
)
def test_job_labels_read_as_words(raw, label):
    assert JobState.parse(raw).label == label


# ---------------------------------------------------------------------------
# GRES and per-node facts (CoreGPUTests · gres parsing, per-node facts)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "gres,total",
    [
        ("gpu:4", 4),
        ("gpu:l40s:3", 3),
        ("gpu:l40s:3(S:0-1)", 3),
        ("gpu:nvidia_h200:8(S:0-1)", 8),
        ("gpu:nvidia_l40:3", 3),
        ("gpu:a100:4(S:0,2),mps:400", 4),
        ("mps:400,gpu:a100:4(IDX:0-3)", 4),
        ("gpu:nvidia_h200:8(S:0-1),gpu:nvidia_l40:2", 10),
        ("GPU:2", 2),
        ("gpu", 1),
        ("mps:400", 0),
        ("(null)", 0),
        (" (null) ", 0),
        ("", 0),
    ],
)
def test_gpu_totals_from_gres(gres, total):
    assert slurm_gpu_total(gres) == total


@pytest.mark.parametrize(
    "gres,model",
    [
        ("gpu:l40s:3(S:0-1)", "l40s"),
        ("gpu:nvidia_h200:8", "nvidia_h200"),
        ("mps:400,gpu:a100:4(S:0,2)", "a100"),
        ("gpu:4", None),
        ("gpu", None),
        ("(null)", None),
        ("", None),
    ],
)
def test_raw_gpu_models(gres, model):
    assert slurm_gpu_model(gres) == model


@pytest.mark.parametrize(
    "gres,name",
    [
        ("gpu:nvidia_h200:8(S:0-1)", "H200"),
        ("gpu:nvidia_l40:3", "L40"),
        ("gpu:l40s:3", "L40S"),
        ("gpu:a100_80g:4", "A100 80G"),
        ("gpu:4", None),
    ],
)
def test_gpu_display_names(gres, name):
    assert slurm_gpu_model_display_name(gres) == name


@pytest.mark.parametrize(
    "raw,name",
    [
        ("NVIDIA_H200", "H200"),
        ("nvidia-a100", "A100"),
        ("amd_mi250x", "MI250X"),
        ("amd-mi300a", "MI300A"),
        ("h100", "H100"),
    ],
)
def test_vendor_prefixes_are_dropped(raw, name):
    assert gpu_model_display_name(raw) == name


def test_configured_gpus_prefer_the_tres_count():
    assert node_gpu_count({"gres": "gpu:l40s:3", "gpu_total": 4}) == 4
    assert node_gpu_count({"gres": "gpu:l40s:3"}) == 3
    assert node_gpu_count({}) == 0


def test_allocation_is_known_derived_or_unknown():
    assert known_gpu_allocated({"gres": "gpu:3", "gpu_total": 3, "gpu_allocated": 2, "gpu_idle": 1}) == 2
    # Only the idle count reported: allocation is the rest, never negative.
    assert known_gpu_allocated({"gres": "gpu:3", "gpu_total": 3, "gpu_idle": 1}) == 2
    assert known_gpu_allocated({"gres": "gpu:3", "gpu_total": 3, "gpu_idle": 5}) == 0
    # No node details at all: unknown, which is never the same as idle.
    assert known_gpu_allocated({"gres": "gpu:3"}) is None
    # A CPU node has nothing to allocate.
    assert known_gpu_allocated({}) == 0


def test_a_nodes_cpus_are_full_when_nothing_is_idle():
    assert cpus_full({"cpu_allocated": 24, "cpu_idle": 0, "cpu_other": 0, "cpu_total": 24})
    assert not cpus_full({"cpu_allocated": 23, "cpu_idle": 1, "cpu_other": 0, "cpu_total": 24})
    # Without an idle count it is derived from total - allocated - other.
    assert cpus_full({"cpu_allocated": 20, "cpu_other": 4, "cpu_total": 24})
    assert not cpus_full({"cpu_allocated": 20, "cpu_total": 24})
    # Nothing known: never claim the node is full.
    assert not cpus_full({})


def test_gpu018_has_full_cpus_and_one_idle_gpu():
    node = next(n for n in AIRE_NODES if n["node"] == "gpu018")
    assert cpus_full(node)
    assert known_gpu_allocated(node) == 2
    assert NodeState.parse(node["state"]).available


# ---------------------------------------------------------------------------
# GPU pools (CoreGPUTests · GPU pools, pool tone and captions)
# ---------------------------------------------------------------------------


def test_unknown_allocation_is_never_a_definite_figure():
    unknown = {"node": "g1", "partitions": ["gpu"], "state": "mix", "gres": "gpu:h200:8"}
    known = {
        "node": "g2",
        "partitions": ["gpu"],
        "state": "mix",
        "cpu_idle": 4,
        "gres": "gpu:h200:8",
        "gpu_allocated": 3,
    }
    all_unknown = GPUFleet.from_nodes([unknown]).pools[0]
    assert all_unknown.idle_figure == "?"
    assert all_unknown.in_use_caption == "8 unknown"
    assert GPUFleet.from_nodes([unknown, known]).pools[0].in_use_caption == "3 in use · 8 unknown"
    assert GPUFleet.from_nodes([known]).pools[0].in_use_caption == "3 in use"


def test_aire_has_one_l40s_pool_with_idle_stranded_and_unavailable_kept_apart():
    fleet = GPUFleet.from_nodes(AIRE_NODES)
    assert len(fleet.pools) == 1
    pool = fleet.primary
    assert pool is not None
    assert (pool.model, pool.label, pool.partitions) == ("L40S", "L40S", ("gpu",))
    assert (pool.node_count, pool.total, pool.allocated) == (14, 42, 31)
    # gpu001, gpu002 and gpu010 have free CPUs next to their idle GPUs.
    assert pool.idle == 4
    # gpu018's idle GPU sits on a node whose CPUs are all taken.
    assert pool.stranded == 1
    # gpu021 and gpu028 are down$ with no allocation reported.
    assert (pool.unavailable, pool.unavailable_nodes, pool.unknown) == (6, 2, 0)
    assert not fleet.has_unknown_allocation
    assert fleet.model_label == "L40S"
    assert [p.label for p in fleet.pools_with_idle] == ["L40S"]


def test_calder_h200_and_l40_are_separate_pools_largest_first():
    fleet = GPUFleet.from_nodes(CALDER_NODES)
    assert [pool.label for pool in fleet.pools] == ["H200", "L40"]
    assert fleet.model_label == "H200 + L40"
    h200, l40 = fleet.pools
    assert h200.partitions == ("calder-gpu-hopper",)
    assert (h200.node_count, h200.total, h200.allocated) == (7, 56, 32)
    # mix- nodes (planned by backfill) still accept work.
    assert (h200.idle, h200.stranded) == (16, 0)
    # calder-h200-05 is drained with no allocation reported.
    assert (h200.unavailable, h200.unavailable_nodes) == (8, 1)
    assert l40.partitions == ("aire-gpu-lovelace",)
    assert (l40.node_count, l40.total, l40.idle, l40.allocated) == (1, 3, 0, 0)
    assert (l40.unavailable, l40.unavailable_nodes) == (3, 1)
    # Fleet totals exist for trend lines only; the per-model split is what
    # the user sees.
    assert (fleet.total, fleet.idle, fleet.unavailable) == (59, 16, 11)
    assert (fleet.unavailable_nodes, fleet.node_count) == (2, 8)
    assert [p.label for p in fleet.pools_with_idle] == ["H200"]


def test_every_gpu_is_counted_exactly_once_in_each_pool():
    nodes = (
        AIRE_NODES
        + CALDER_NODES
        + [
            {"node": "u1", "partitions": ["gpu"], "state": "mix", "gres": "gpu:a100:4"},
            {
                "node": "d1",
                "partitions": ["gpu"],
                "state": "drng",
                "gres": "gpu:a100:4",
                "gpu_total": 4,
                "gpu_allocated": 2,
            },
        ]
    )
    fleet = GPUFleet.from_nodes(nodes)
    for pool in fleet.pools:
        assert pool.allocated + pool.idle + pool.stranded + pool.unavailable + pool.unknown == pool.total
    assert fleet.total == sum(node_gpu_count(n) for n in nodes)


def test_unknown_allocation_on_a_usable_node_is_unknown_never_idle():
    fleet = GPUFleet.from_nodes([{"node": "g1", "partitions": ["gpu"], "state": "mix", "gres": "gpu:a100:4"}])
    pool = fleet.pools[0]
    assert (pool.unknown, pool.idle, pool.allocated) == (4, 0, 0)
    assert fleet.has_unknown_allocation


def test_unknown_allocation_on_a_node_that_accepts_no_work_is_unavailable():
    pool = GPUFleet.from_nodes([{"node": "g1", "state": "drain", "gres": "gpu:a100:4"}]).pools[0]
    assert (pool.unavailable, pool.unknown, pool.unavailable_nodes) == (4, 0, 1)


@pytest.mark.parametrize("state", ["drng", "mix$", "idle$", "mix*", "mix@"])
def test_idle_gpus_on_draining_and_reserved_nodes_are_unavailable(state):
    node = {
        "node": "g1",
        "partitions": ["gpu"],
        "state": state,
        "cpu_allocated": 8,
        "cpu_idle": 16,
        "cpu_other": 0,
        "cpu_total": 24,
        "gres": "gpu:l40s:3",
        "gpu_total": 3,
        "gpu_allocated": 1,
        "gpu_idle": 2,
    }
    pool = GPUFleet.from_nodes([node]).pools[0]
    assert (pool.allocated, pool.idle, pool.stranded, pool.unavailable, pool.unavailable_nodes) == (
        1,
        0,
        0,
        2,
        1,
    )


def test_over_reported_allocation_is_clamped():
    pool = GPUFleet.from_nodes(
        [{"state": "alloc", "gres": "gpu:4", "gpu_total": 4, "gpu_allocated": 6}]
    ).pools[0]
    assert (pool.allocated, pool.idle) == (4, 0)


def test_stranded_gpus_are_not_idle():
    # The review's case: an H200 node with every core taken and 2 GPUs idle,
    # next to an L40 node with 3 free.
    fleet = GPUFleet.from_nodes(
        [
            {"state": "mix", "cpu_idle": 0, "gres": "gpu:nvidia_h200:8", "gpu_total": 8, "gpu_allocated": 6},
            {"state": "idle", "cpu_idle": 24, "gres": "gpu:nvidia_l40:3", "gpu_total": 3, "gpu_allocated": 0},
        ]
    )
    h200, l40 = fleet.pools
    assert (h200.idle, h200.stranded) == (0, 2)
    assert l40.idle == 3


def test_untyped_gpus_form_their_own_pool():
    fleet = GPUFleet.from_nodes(
        [
            {"state": "idle", "cpu_idle": 8, "gres": "gpu:2", "gpu_total": 2, "gpu_allocated": 0},
            {"state": "idle", "cpu_idle": 8, "gres": "gpu:l40s:3", "gpu_total": 3, "gpu_allocated": 0},
        ]
    )
    assert [pool.label for pool in fleet.pools] == ["L40S", "GPU"]
    assert fleet.pools[-1].model is None


def test_ties_keep_first_seen_order_and_a_third_model_is_more():
    def node(gres, count):
        return {"state": "idle", "cpu_idle": 8, "gres": gres, "gpu_total": count, "gpu_allocated": 0}

    fleet = GPUFleet.from_nodes([node("gpu:a100:4", 4), node("gpu:v100:4", 4), node("gpu:nvidia_h200:8", 8)])
    assert [pool.label for pool in fleet.pools] == ["H200", "A100", "V100"]
    assert fleet.model_label == "H200 + A100 + more"


def test_partitions_are_collected_per_pool_in_first_seen_order():
    def node(partitions):
        return {
            "partitions": partitions,
            "state": "mix",
            "gres": "gpu:l40s:3",
            "gpu_total": 3,
            "gpu_allocated": 3,
        }

    pool = GPUFleet.from_nodes([node(["gpu", "gpu-long"]), node(["gpu"]), node(["gpu-debug", "gpu"])]).pools[
        0
    ]
    assert pool.partitions == ("gpu", "gpu-long", "gpu-debug")
    assert pool.node_count == 3


def test_cpu_only_clusters_have_no_pools():
    fleet = GPUFleet.from_nodes([n for n in AIRE_NODES if node_gpu_count(n) == 0])
    assert fleet.pools == ()
    assert fleet.primary is None and fleet.model_label is None and fleet.primary_idle_text is None
    assert fleet.total == 0


def tone_node(name, state="mix", cpu_idle=16, gres="gpu:nvidia_h200:8", allocated=None):
    return {
        "node": name,
        "partitions": ["gpu"],
        "state": state,
        "cpu_allocated": 128 - cpu_idle,
        "cpu_idle": cpu_idle,
        "cpu_total": 128,
        "gres": gres,
        "gpu_total": 8,
        "gpu_allocated": allocated,
        "gpu_idle": None if allocated is None else 8 - allocated,
    }


def first_pool(*nodes):
    return GPUFleet.from_nodes(nodes).pools[0]


def test_pool_idle_tone():
    assert first_pool(tone_node("a", allocated=6)).idle_tone == "normal"
    # 7 allocated and 1 idle stranded: a busy pool, not a fault.
    full = first_pool(tone_node("a", state="alloc", cpu_idle=0, allocated=7))
    assert (full.idle, full.stranded, full.idle_tone) == (0, 1, "warning")
    unknown = first_pool(tone_node("a"))
    assert unknown.idle_is_unknown and unknown.idle_tone == "unavailable"
    # Some GPUs known idle beside unknown ones: a job can start, so good.
    assert first_pool(tone_node("a", allocated=6), tone_node("b")).idle_tone == "normal"
    drained = first_pool(
        tone_node("a", state="drain", allocated=0), tone_node("b", state="drng", allocated=3)
    )
    assert drained.is_wholly_unavailable and drained.idle_tone == "unavailable"


def test_calder_live_pools_captions():
    l40 = {
        "node": "gpu028",
        "partitions": ["aire-gpu-lovelace"],
        "state": "drain*",
        "cpu_allocated": 0,
        "cpu_idle": 64,
        "cpu_total": 64,
        "gres": "gpu:nvidia_l40:3",
        "gpu_total": 3,
        "gpu_allocated": 0,
        "gpu_idle": 3,
    }
    fleet = GPUFleet.from_nodes(
        [
            tone_node("calder-h200-01", state="alloc", cpu_idle=0, allocated=8),
            tone_node("calder-h200-04", state="alloc", cpu_idle=0, allocated=1),
            tone_node("calder-h200-05", state="drain", allocated=0),
            l40,
        ]
    )
    h200, l40_pool = fleet.pools
    assert h200.idle_tone == "warning"
    assert h200.capacity_caption == "9 in use · 7 stranded · 8 unavailable"
    assert l40_pool.idle_tone == "unavailable"
    assert l40_pool.capacity_caption == "all 3 unavailable"


def test_captions_name_every_gpu_that_is_not_idle():
    stranded = first_pool(tone_node("a", state="alloc", cpu_idle=0, allocated=7))
    assert stranded.breakdown_summary == "7 in use · 1 stranded"
    assert stranded.capacity_caption == stranded.breakdown_summary
    assert first_pool(tone_node("a", allocated=0)).breakdown_summary == "0 in use"
    unknown = first_pool(tone_node("a"), tone_node("b", state="drain"))
    assert unknown.breakdown_summary == "8 unavailable · 8 unknown"
    assert "in use" not in unknown.capacity_caption
    assert first_pool(tone_node("a", allocated=3), tone_node("b")).breakdown_summary == "3 in use · 8 unknown"
    draining = first_pool(tone_node("a", state="drng", allocated=3))
    assert draining.is_wholly_unavailable
    assert draining.capacity_caption == "3 in use · 5 unavailable"


def test_primary_idle_text_says_more_model_never_a_bare_plus_one():
    l40 = {
        "node": "gpu028",
        "state": "drain*",
        "cpu_idle": 64,
        "cpu_total": 64,
        "gres": "gpu:nvidia_l40:3",
        "gpu_total": 3,
        "gpu_allocated": 0,
        "gpu_idle": 3,
    }
    h200 = tone_node("calder-h200-01", allocated=8)
    a100 = tone_node("x", gres="gpu:a100:8", allocated=8)
    assert GPUFleet.from_nodes([h200]).primary_idle_text == "0 of 8 H200 idle"
    assert GPUFleet.from_nodes([h200, l40]).primary_idle_text == "0 of 8 H200 idle · +1 more model"
    assert (
        GPUFleet.from_nodes(
            [h200, tone_node("y", gres="gpu:a100:8", allocated=8), a100, l40]
        ).primary_idle_text
        == "0 of 16 A100 idle · +2 more models"
    )
    unknown = GPUFleet.from_nodes([tone_node("calder-h200-01"), l40])
    assert unknown.primary_idle_text == "? of 8 H200 idle · +1 more model"


# ---------------------------------------------------------------------------
# Jobs (CoreJobTests · job arrays, display order; OverviewModelTests · queue
# counts)
# ---------------------------------------------------------------------------


def test_the_pending_remainder_stands_for_every_queued_task():
    remainder = next(j for j in AIRE_JOBS if j["job_id"] == "8248307")
    assert is_array_remainder(remainder)
    assert task_multiplicity(remainder) == 57
    assert display_job_id(remainder) == "8248307_[2-58]"


def test_a_running_array_task_is_one_job_with_its_own_id():
    task = next(j for j in AIRE_JOBS if j["job_id"] == "8248307_0")
    assert not is_array_remainder(task)
    assert task_multiplicity(task) == 1
    assert display_job_id(task) == "8248307_0"


def test_plain_jobs_and_incomplete_remainders_never_count_as_zero_jobs():
    plain = {"job_id": "8248326"}
    assert (is_array_remainder(plain), task_multiplicity(plain), display_job_id(plain)) == (
        False,
        1,
        "8248326",
    )
    assert task_multiplicity({"job_id": "77", "array_job_id": 77, "array_pending_tasks": "1-3"}) == 1
    zero = {"job_id": "77", "array_job_id": 77, "array_pending_tasks": "1-3", "pending_task_count": 0}
    assert task_multiplicity(zero) == 1
    no_tasks = {"job_id": "77", "array_job_id": 77, "array_pending_tasks": "", "pending_task_count": 3}
    assert display_job_id(no_tasks) == "77"


def test_queue_totals_count_array_tasks_not_rows():
    pending = [j for j in AIRE_JOBS if JobState.parse(j["state"]).is_pending]
    assert len(pending) == 5
    assert sum(task_multiplicity(j) for j in pending) == 61


def test_fixture_display_order():
    ordered = [j["job_id"] for j in sorted(AIRE_JOBS, key=job_sort_key)]
    assert ordered == ["8248307_0", "8248307_1", "8248307", "8248326", "8247672", "8248328", "8248684"]


def test_every_rank_with_natural_id_order_inside_a_rank():
    jobs = [
        {"job_id": "10", "state": "SUSPENDED"},
        {"job_id": "9", "state": "PENDING", "reason_or_node_list": "(JobHeldAdmin)"},
        {"job_id": "8", "state": "PENDING", "reason_or_node_list": "(DependencyNeverSatisfied)"},
        {"job_id": "7", "state": "PENDING", "reason_or_node_list": "(Resources)"},
        {"job_id": "123_10", "state": "RUNNING", "reason_or_node_list": "gpu010"},
        {"job_id": "123_2", "state": "RUNNING", "reason_or_node_list": "gpu002"},
        {"job_id": "5", "state": "COMPLETING"},
        {"job_id": "6", "state": "CONFIGURING"},
        {"job_id": "11", "state": "REQUEUED", "reason_or_node_list": "(BeginTime)"},
        {"job_id": "4", "state": "PENDING", "reason_or_node_list": "(JobHeldUser)"},
        {"job_id": "3", "state": "COMPLETED"},
    ]
    ordered = [j["job_id"] for j in sorted(jobs, key=job_sort_key)]
    assert ordered == ["5", "6", "123_2", "123_10", "7", "11", "8", "4", "9", "3", "10"]
    assert [j["job_id"] for j in sorted(reversed(jobs), key=job_sort_key)] == ordered


def test_queue_counts_tell_running_pending_held_and_other_apart():
    counts = JobQueueCounts.from_jobs(
        [
            {"job_id": "1", "state": "RUNNING"},
            {"job_id": "2", "state": "COMPLETING"},
            {"job_id": "3", "state": "PENDING", "reason_or_node_list": "Priority"},
            {"job_id": "4", "state": "PENDING", "reason_or_node_list": "JobHeldUser"},
            {"job_id": "5", "state": "SUSPENDED"},
            {"job_id": "6", "state": "REQUEUE_HOLD", "reason_or_node_list": "JobHoldMaxRequeue"},
        ]
    )
    assert (counts.running, counts.pending, counts.held, counts.other) == (2, 1, 2, 1)
    assert (counts.waiting, counts.total) == (3, 6)


def test_queue_counts_weight_array_remainders():
    remainder = {
        "job_id": "8248307",
        "state": "PENDING",
        "reason_or_node_list": "Priority",
        "array_job_id": 8248307,
        "array_pending_tasks": "2-58",
        "pending_task_count": 57,
    }
    task = {"job_id": "8248307_1", "state": "RUNNING", "array_job_id": 8248307}
    counts = JobQueueCounts.from_jobs([remainder, task])
    assert (counts.pending, counts.running, counts.total) == (57, 1, 58)


def test_the_reviews_queue():
    # A 58-task remainder, a held job, COMPLETING, CONFIGURING and REQUEUED:
    # the old count said 0 running / 2 pending.
    counts = JobQueueCounts.from_jobs(
        [
            {
                "job_id": "200",
                "state": "PENDING",
                "reason_or_node_list": "(Priority)",
                "array_job_id": 200,
                "array_pending_tasks": "0-57",
                "pending_task_count": 58,
            },
            {"job_id": "201", "state": "PENDING", "reason_or_node_list": "(JobHeldUser)"},
            {"job_id": "202", "state": "COMPLETING"},
            {"job_id": "203", "state": "CONFIGURING"},
            {"job_id": "204", "state": "REQUEUED", "reason_or_node_list": "(BeginTime)"},
        ]
    )
    assert counts.summary() == "2 running · 59 pending · 1 held"


def test_fixture_queue_counts():
    assert JobQueueCounts.from_jobs(CALDER_JOBS).summary() == "4 running · 17 pending · 1 held"
    assert is_held(CALDER_JOBS[0])
    # A running job's %R column is its node list, never a reason.
    assert not is_held({"job_id": "1", "state": "RUNNING", "reason_or_node_list": "holdnode01"})


def test_queue_summary_leaves_out_empty_parts_but_always_names_running():
    assert JobQueueCounts(running=1, pending=13).summary() == "1 running · 13 pending"
    assert JobQueueCounts(held=2).summary() == "0 running · 2 held"
    assert JobQueueCounts().summary() == "0 running · 0 pending"
    assert JobQueueCounts(3, 1, 1, 2).summary() == "3 running · 1 pending · 1 held · 2 other"
    assert (
        JobQueueCounts(running=1, pending=6, other=1).summary("suspended")
        == "1 running · 6 pending · 1 suspended"
    )
    assert JobQueueCounts(other=1).summary("suspended") == "0 running · 1 suspended"


# Notifications (the macOS app's JobStateDiff.compute)


def remainder(tasks, count, array="123"):
    return {
        "job_id": array,
        "state": "PENDING",
        "reason_or_node_list": "(Resources)",
        "array_job_id": int(array),
        "array_pending_tasks": tasks,
        "pending_task_count": count,
    }


def test_a_started_job_is_reported():
    before = [{"job_id": "8100", "state": "PENDING"}]
    after = [{"job_id": "8100", "state": "RUNNING"}]
    assert job_change_messages(before, after) == ["8100: PENDING → RUNNING"]


def test_a_remainder_shedding_a_task_reports_the_start_not_an_ending():
    before = [remainder("5-9", 5)]
    after = [remainder("6-9", 4), {"job_id": "123_5", "state": "RUNNING", "array_job_id": 123}]
    assert job_change_messages(before, after) == ["123_5: PENDING → RUNNING"]


def test_a_remainder_whose_last_task_started_did_not_leave_the_queue():
    before = [remainder("9", 1), {"job_id": "123_8", "state": "RUNNING", "array_job_id": 123}]
    after = [
        {"job_id": "123_8", "state": "RUNNING", "array_job_id": 123},
        {"job_id": "123_9", "state": "RUNNING", "array_job_id": 123},
    ]
    assert job_change_messages(before, after) == ["123_9: PENDING → RUNNING"]


def test_an_array_gone_from_the_queue_is_named_by_its_tasks():
    before = [remainder("5-9", 5)]
    assert job_change_messages(before, []) == ["123_[5-9]: left the active queue (final status unknown)"]


def test_endings_and_resumes():
    before = [
        {"job_id": "10", "state": "RUNNING"},
        {"job_id": "9", "state": "RUNNING"},
        {"job_id": "11", "state": "SUSPENDED"},
        {"job_id": "12", "state": "COMPLETED"},
    ]
    after = [{"job_id": "10", "state": "COMPLETED"}, {"job_id": "11", "state": "RUNNING"}]
    # A finished state is reported as such, a vanished job as unknown, a
    # resumed SUSPENDED job not at all; endings in natural id order.
    assert job_change_messages(before, after) == [
        "9: left the active queue (final status unknown)",
        "10: RUNNING → COMPLETED",
    ]


def test_a_job_seen_running_for_the_first_time_is_not_a_start():
    # It never was in a queue this app saw (the macOS app agrees).
    assert job_change_messages([], [{"job_id": "1", "state": "RUNNING"}]) == []


# ---------------------------------------------------------------------------
# CPUs and history (OverviewClusterStats, TrendPoint)
# ---------------------------------------------------------------------------


def test_cpus_free_counts_available_cpu_only_nodes():
    figures = cluster_figures({"nodes": CALDER_NODES, "jobs": CALDER_JOBS})
    # calder-cpu001 8 + cpu008 0 + cpu020 128 + cpu021 128; the down and
    # drained CPU nodes and every GPU node's cores are left out.
    assert (figures.cpu_idle, figures.cpu_total, figures.cpu_nodes) == (264, 512, 4)
    assert figures.unavailable_nodes == 7
    assert figures.node_count == 17


def test_a_missing_cpu_idle_is_estimated_not_blanking_the_figure():
    nodes = [
        {"state": "mix", "cpu_total": 100, "cpu_allocated": 30, "cpu_other": 10},
        {"state": "idle", "cpu_total": 50, "cpu_idle": 50},
        # A GPU node's cores feed its GPUs.
        {"state": "idle", "cpu_total": 64, "cpu_idle": 64, "gres": "gpu:l40s:3", "gpu_total": 3},
    ]
    figures = cluster_figures({"nodes": nodes})
    assert (figures.cpu_idle, figures.cpu_total) == (110, 150)


def test_history_point_sums_models_only_for_the_trend_line():
    point = history_point(
        {"collected_at": "2026-10-13T11:49:45+00:00", "nodes": CALDER_NODES, "jobs": CALDER_JOBS}
    )
    assert point["gpu_idle"] == 16 and point["gpu_unknown"] == 0 and point["gpu_total"] == 59
    assert (point["running"], point["pending"], point["held"]) == (4, 17, 1)
    assert point["cpu_idle"] == 264
    assert core.clean_history([point]) == [point]


@pytest.mark.parametrize(
    "point,value,text",
    [
        ({"gpu_idle": 5, "gpu_unknown": 0}, 5, "5"),
        ({"gpu_idle": 5, "gpu_unknown": 4}, None, "at least 5"),
        ({"gpu_idle": 0, "gpu_unknown": 4}, None, "unknown"),
        ({"gpu_idle": None}, None, "—"),
        # History written before gpu_unknown existed.
        ({"gpu_idle": 3}, 3, "3"),
    ],
)
def test_trend_points_never_state_a_figure_they_do_not_have(point, value, text):
    assert trend_gpu_value(point) == value
    assert history_gpu_text(point) == text


# ---------------------------------------------------------------------------
# Storage tone (CoreCatalogTests · status tone, DashboardLogicTests · storage)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "percent,tone",
    [
        (None, "unavailable"),
        (0, "normal"),
        (62.4, "normal"),
        (74.9, "normal"),
        (74.99, "normal"),
        (75, "warning"),
        (87.98, "warning"),
        (89.9, "warning"),
        (89.999, "warning"),
        (90, "critical"),
        (90.5, "critical"),
        (130, "critical"),
    ],
)
def test_usage_thresholds(percent, tone):
    assert usage_tone(percent) == tone
    assert storage_tone({"label": "Scratch", "source": "lfs quota", "used_percent": percent}) == tone


def test_fixture_storage_tones():
    # AIRE home 68.5 %, AIRE scratch 88 %, Calder scratch 90.5 %, flash 62.4 %.
    assert [usage_tone(p) for p in (68.5, 87.98, 68.5, 90.5, 62.4)] == [
        "normal",
        "warning",
        "normal",
        "critical",
        "normal",
    ]


def test_over_quota_is_critical_and_unreadable_is_unavailable():
    assert storage_tone({"label": "Home", "used_percent": 20, "over_quota": True}) == "critical"
    assert storage_tone({"label": "Scratch", "source": "unavailable"}) == "unavailable"
    assert rules.storage_status({"label": "Home", "used_percent": 20, "over_quota": True}) == "Over quota"


def test_file_count_pressure_counts_when_it_is_the_closer_limit():
    row = {"label": "Home", "used_percent": 40, "file_count": 950_000, "file_quota": 1_000_000}
    assert storage_file_count_dominates(row)
    assert storage_file_used_percent(row) == 95
    assert storage_pressure_percent(row) == 95
    assert storage_tone(row) == "critical"
    # The hard file limit wins over the soft quota.
    assert storage_file_used_percent({"file_count": 50, "file_quota": 100, "file_limit": 200}) == 25


def test_the_reviews_inode_bound_volume_is_flagged():
    # 960,000 of 1,000,000 files and 120 GiB of 1.1 TiB: 10.9 % space.
    row = {
        "label": "Scratch",
        "source": "lfs quota",
        "used_gb": 120,
        "quota_gb": 1100,
        "used_percent": 10.9,
        "file_count": 960_000,
        "file_limit": 1_000_000,
    }
    assert storage_tone(row) == "critical"
    assert rules.storage_row_text(row) == "Scratch: 120.0 / 1,100.0 GiB · 96% of file limit · CRITICAL"


def test_storage_row_text_for_unavailable_and_df_rows():
    assert (
        rules.storage_row_text(
            {"label": "Flash", "source": "unavailable", "unavailable_reason": "no-figures"}
        )
        == "Flash: unavailable (no figures in time)"
    )
    df = {
        "label": "Home",
        "source": "df",
        "used_gb": 10,
        "quota_gb": None,
        "limit_gb": 100,
        "used_percent": 10,
    }
    assert rules.storage_row_text(df) == "Home: 10.0 / 100.0 GiB (df: whole filesystem) · 10% used"


# ---------------------------------------------------------------------------
# Storage merge and cadence (SessionTests · storage cadence, cut short)
# ---------------------------------------------------------------------------

HOME = {"label": "Home", "source": "nfs", "used_percent": 40}
SCRATCH = {"label": "Scratch", "source": "lustre", "available_gb": 900, "used_percent": 55}
SCRATCH_STALLED = {"label": "Scratch", "source": "unavailable", "unavailable_reason": "no-figures"}
SCRATCH_NOT_REACHED = {"label": "Scratch", "source": "unavailable", "unavailable_reason": "not-collected"}
SCRATCH_MISSING = {"label": "Scratch", "source": "unavailable", "unavailable_reason": "missing"}
FLASH_CUT = {
    "label": "Flash",
    "source": "unavailable",
    "unavailable_reason": "not-collected",
    "optional": True,
}


def test_an_optional_volume_cut_short_shows_only_where_it_had_figures():
    # AIRE-like: Flash never had figures, so its cut row stays hidden.
    assert merge_storage(None, [HOME, FLASH_CUT], {"Home"}) == [HOME]
    # Calder-like: Flash had figures, so the cut row is shown.
    assert merge_storage(None, [HOME, FLASH_CUT], {"Home", "Flash"}) == [HOME, FLASH_CUT]
    # None keeps the previous rows; [] means collected, no volumes.
    assert merge_storage([HOME], None, set()) == [HOME]
    assert merge_storage([HOME], [], {"Home"}) == []


def test_only_rows_cut_short_keep_earlier_figures():
    labels = {"Home", "Scratch"}
    assert merge_storage([HOME, SCRATCH], [HOME, SCRATCH_NOT_REACHED], labels, True) == [HOME, SCRATCH]
    assert merge_storage([HOME, SCRATCH], [HOME, SCRATCH_STALLED], labels, True) == [HOME, SCRATCH]
    assert merge_storage([HOME, SCRATCH], [HOME, SCRATCH_NOT_REACHED], labels, False) == [
        HOME,
        SCRATCH_NOT_REACHED,
    ]
    # A volume that is gone is shown as gone.
    assert merge_storage([HOME, SCRATCH], [HOME, SCRATCH_MISSING], labels, True) == [HOME, SCRATCH_MISSING]
    # Nothing to carry when the previous row had no figures either.
    assert merge_storage([HOME, SCRATCH_STALLED], [HOME, SCRATCH_NOT_REACHED], labels, True) == [
        HOME,
        SCRATCH_NOT_REACHED,
    ]
    assert storage_carries_earlier_rows([HOME, SCRATCH_NOT_REACHED], [HOME, SCRATCH])
    assert not storage_carries_earlier_rows([HOME, SCRATCH_NOT_REACHED], [HOME, SCRATCH_NOT_REACHED])
    assert not storage_carries_earlier_rows([HOME, SCRATCH], [HOME, SCRATCH])
    assert not storage_carries_earlier_rows(None, [HOME, SCRATCH])


def snap(stamp, storage):
    return {"collected_at": f"2026-10-13T12:{stamp}+00:00", "storage": storage}


def test_storage_is_collected_first_then_every_five_minutes():
    tracker = StorageTracker()
    assert tracker.wants_storage(manual=False, now=0)
    shown = tracker.receive(None, snap("00:00", [HOME]), True, 0)
    assert not tracker.wants_storage(False, 10)
    # A skipped section keeps the previous rows and their collection time.
    shown = tracker.receive(shown, snap("00:10", None), False, 10)
    assert shown["storage"] == [HOME]
    assert shown["storage_collected_at"] == "2026-10-13T12:00:00+00:00"
    assert rules.storage_rows_time(shown) == "2026-10-13T12:00:00+00:00"
    assert not tracker.wants_storage(False, 299)
    assert tracker.wants_storage(False, 300)
    # A manual refresh always collects.
    assert tracker.wants_storage(True, 11)
    # Fresh rows carry no separate time: it is the snapshot's.
    shown = tracker.receive(shown, snap("05:00", [HOME]), True, 300)
    assert "storage_collected_at" not in shown
    assert rules.storage_rows_time(shown) == "2026-10-13T12:05:00+00:00"


def test_storage_that_does_not_come_back_is_asked_for_a_minute_later():
    tracker = StorageTracker()
    shown = tracker.receive(None, snap("00:00", None), True, 0)
    assert shown["storage"] is None
    assert not tracker.wants_storage(False, 10)
    assert tracker.wants_storage(False, 60)
    # Not even the five-minute rule overrides the back-off after a miss.
    tracker.receive(shown, snap("05:00", [HOME]), True, 300)
    tracker.receive(None, snap("10:00", None), True, 600)
    assert not tracker.wants_storage(False, 630)
    assert tracker.wants_storage(True, 630)


def test_a_cut_section_is_a_miss_whose_rows_keep_their_figures_for_a_while():
    tracker = StorageTracker()
    shown = tracker.receive(None, snap("00:00", [HOME, SCRATCH]), True, 0)
    assert not tracker.wants_storage(False, 299)
    # One stalled df does not wipe good figures, and the carried row keeps
    # the older collection time: it is not passed off as fresh.
    shown = tracker.receive(shown, snap("05:00", [HOME, SCRATCH_STALLED]), True, 300)
    assert shown["storage"] == [HOME, SCRATCH]
    assert rules.storage_rows_time(shown) == "2026-10-13T12:00:00+00:00"
    # Not every refresh: a stuck df is probably still stuck.
    assert not tracker.wants_storage(False, 310)
    # A minute after the miss, not five: the cut section was no collection.
    assert tracker.wants_storage(False, 360)
    # Past the carry limit a volume that keeps failing shows as unreadable.
    shown = tracker.receive(shown, snap("15:00", [HOME, SCRATCH_NOT_REACHED]), True, 900)
    assert shown["storage"] == [HOME, SCRATCH_NOT_REACHED]
    assert rules.storage_rows_time(shown) == "2026-10-13T12:15:00+00:00"


def test_aire_flash_never_appears_but_calder_flash_is_kept():
    flash = {"label": "Flash", "source": "lfs quota", "used_percent": 10, "optional": True}
    aire = StorageTracker()
    assert aire.receive(None, snap("00:00", [HOME, FLASH_CUT]), True, 0)["storage"] == [HOME]
    calder = StorageTracker()
    shown = calder.receive(None, snap("00:00", [HOME, flash]), True, 0)
    shown = calder.receive(shown, snap("01:00", [HOME, FLASH_CUT]), True, 60)
    assert shown["storage"] == [HOME, flash]


def test_cached_rows_teach_which_volumes_had_figures():
    tracker = StorageTracker()
    tracker.note_cached({"storage": [HOME, {"label": "Flash", "source": "lfs quota"}]})
    assert tracker.labels_with_figures == {"Home", "Flash"}
    assert tracker.wants_storage(False, 0)


# ---------------------------------------------------------------------------
# Times (CoreTimeTests: zone-less Slurm times are Europe/London)
# ---------------------------------------------------------------------------


@pytest.fixture
def london(monkeypatch):
    monkeypatch.delenv("HPC_CLUSTER_TZ", raising=False)


@pytest.mark.parametrize(
    "raw,utc",
    [
        # British Summer Time: 12:00 in Leeds is 11:00 UTC.
        ("2026-07-01T12:00:00", datetime(2026, 7, 1, 11, 0, tzinfo=timezone.utc)),
        ("2026-12-01 12:00:00", datetime(2026, 12, 1, 12, 0, tzinfo=timezone.utc)),
        ("2026-10-13T11:49:45.636173+00:00", datetime(2026, 10, 13, 11, 49, 45, 636173, tzinfo=timezone.utc)),
        ("2026-10-13T12:49:55+01:00", datetime(2026, 10, 13, 11, 49, 55, tzinfo=timezone.utc)),
        ("2026-10-13T11:49:45Z", datetime(2026, 10, 13, 11, 49, 45, tzinfo=timezone.utc)),
    ],
)
def test_zone_less_slurm_times_are_cluster_times(london, raw, utc):
    assert parse_slurm_time(raw) == utc


@pytest.mark.parametrize("raw", ["", "Unknown", "N/A", "2026-10-13", None, 5])
def test_unparsable_times(london, raw):
    assert parse_slurm_time(raw) is None


def test_local_text_is_this_computers_zone(london):
    expected = datetime(2026, 7, 1, 11, 0, tzinfo=timezone.utc).astimezone().strftime("%d %b %Y %H:%M:%S %Z")
    assert rules.local_time_text("2026-07-01T12:00:00") == expected
    assert rules.local_time_text("Unknown") == "Unknown"


def test_the_collectors_zone_override_is_honoured(monkeypatch):
    # The collector renders squeue --json epochs in this zone (tests pin
    # UTC through HPC_CLUSTER_TZ), so the app reads them back the same way.
    monkeypatch.setenv("HPC_CLUSTER_TZ", "UTC")
    assert parse_slurm_time("2026-07-01T12:00:00") == datetime(2026, 7, 1, 12, 0, tzinfo=timezone.utc)


def test_job_details_show_local_times(london):
    text = rules.job_details_text(
        {"job_id": "1", "submit_time": "2026-07-01T12:00:00", "start_time": None, "_tone": "x"}
    )
    assert text.startswith("Times are in this computer's time zone.\n")
    details = json.loads(text.split("\n", 1)[1])
    assert details["submit_time"] == rules.local_time_text("2026-07-01T12:00:00")
    assert details["start_time"] is None
    assert "_tone" not in details


# ---------------------------------------------------------------------------
# The collector's real output (Tests/Fixtures/collector_snapshot.json): the
# figures the Swift contract test asserts, through the desktop rules.
# ---------------------------------------------------------------------------

FIXTURE = Path(__file__).resolve().parents[2] / "Tests" / "Fixtures" / "collector_snapshot.json"


def test_collector_fixture_figures_match_the_macos_app():
    snapshot = validate_snapshot(json.loads(FIXTURE.read_text(encoding="utf-8")), "calder", "abcd1234")
    # The two gres parsers agree, including '(S:0,2)' socket lists.
    for node in snapshot["nodes"]:
        if node["gpu_total"] is not None:
            assert slurm_gpu_total(node["gres"]) == node["gpu_total"], node["node"]
    figures = cluster_figures(snapshot)
    pools = {pool.label: pool for pool in figures.fleet.pools}
    h200 = pools["H200"]
    assert (h200.total, h200.allocated, h200.idle, h200.unavailable, h200.unknown) == (24, 5, 11, 8, 0)
    # calder-l40-01 reports no GPU TRES: unknown, never idle, and it no
    # longer blanks the H200 figure (or gets added into it).
    l40s = pools["L40S"]
    assert (l40s.total, l40s.idle, l40s.unknown) == (4, 0, 4)
    assert figures.fleet.primary_idle_text == "11 of 24 H200 idle · +1 more model"
    assert figures.counts.summary() == "3 running · 56 pending · 1 held"
    assert [display_job_id(j) for j in sorted(snapshot["jobs"], key=job_sort_key)] == [
        "35796_1",
        "35796_2",
        "40188",
        "35796_[3-58]",
        "9918",
    ]
    assert (figures.cpu_idle, figures.cpu_total) == (28, 128)
