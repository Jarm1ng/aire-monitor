import copy
import json
import re
from pathlib import Path

import hpc_snapshot as collector
import pytest

from leeds_hpc_desktop import demo
from leeds_hpc_desktop.core import (
    LocalStore,
    PROFILES,
    clean_history,
    validate_snapshot,
    validate_username,
)
from leeds_hpc_desktop.rules import cluster_figures

REPO = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize(
    "username,canonical",
    [
        ("abcd1234", "abcd1234"),
        ("ab_cd", "ab_cd"),
        ("abc-12", "abc-12"),
        ("Abc.1", "abc.1"),
        ("AB12CDE", "ab12cde"),
    ],
)
def test_username(username, canonical):
    # One spelling for sign-in, saved password and cache: Leeds usernames
    # are lower case and the clusters' account lookup ignores case.
    assert validate_username(f" {username} ") == canonical


def test_snapshot_account_check_ignores_case(tmp_path):
    # whoami reports the canonical lower-case name, whatever was typed.
    snapshot = copy.deepcopy(demo.snapshots()["aire"])
    snapshot["remote"]["user"] = "DEMO"
    assert validate_snapshot(snapshot, "aire", "demo") is snapshot
    store = LocalStore(tmp_path)
    store.save("Demo", "aire", snapshot, [])
    assert [p.name for p in tmp_path.iterdir()] == ["demo-aire.json"]
    assert store.load("DEMO", "aire")[0] == snapshot
    snapshot["remote"]["user"] = "other"
    with pytest.raises(ValueError, match="different account"):
        validate_snapshot(snapshot, "aire", "demo")


@pytest.mark.parametrize("username", ["", "-option", "a@leeds.ac.uk", "../user", "a/b", "a\\b", "a;pwd"])
def test_bad_username(username):
    with pytest.raises(ValueError):
        validate_username(username)


def test_profiles_match_collector_specs():
    assert len(PROFILES) == 2
    assert all(len(p.volumes) == 3 for p in PROFILES)
    assert PROFILES[0].color != PROFILES[1].color
    assert PROFILES[0].volumes[0] == PROFILES[1].volumes[0]


def test_profiles_are_the_collectors_clusters():
    # CollectorContractTests (Swift) checks the collector's cluster table and
    # <ID>_SPEC storage specs against the macOS catalogue. This pins the
    # other half: the desktop app shows exactly the collector's clusters,
    # with those names, hosts and specs, so all three apps agree.
    assert {p.id for p in PROFILES} == set(collector.KNOWN_CLUSTER_NAMES)
    for p in PROFILES:
        assert p.name == collector.KNOWN_CLUSTER_NAMES[p.id]
        assert p.host == collector.KNOWN_CLUSTER_HOSTNAMES[p.id]
        # A "-" in an id (allowed: MACOS_APP.md, "Adding a cluster") is "_"
        # in the constant's name, as in CollectorContractTests.
        assert p.storage_spec == getattr(collector, f"{p.id.upper().replace('-', '_')}_SPEC")


def test_the_collector_names_this_app_uses_are_documented_as_stable():
    # MONITORING_PROTOTYPE.md ("Keep stable") and the collector's docstring
    # tell whoever changes the collector for the macOS app which names this
    # app needs. A name used here but missing from either list could be
    # renamed in good faith, and this package would then fail to import.
    used = set()
    for source in (REPO / "desktop" / "leeds_hpc_desktop").glob("*.py"):
        used |= set(re.findall(r"\bcollector\.([A-Za-z_]\w*)", source.read_text(encoding="utf-8")))
    assert {"run_collection", "DEFAULT_TIMEOUT", "_cluster_zone"} <= used
    guide = (REPO / "MONITORING_PROTOTYPE.md").read_text(encoding="utf-8")
    keep_stable = next(line for line in guide.splitlines() if line.startswith("**Keep stable:**"))
    docstring = collector.__doc__ or ""
    for name in sorted(used):
        assert re.search(rf"\b{name}\b", keep_stable), f"{name} is missing from MONITORING_PROTOTYPE.md"
        assert re.search(rf"\b{name}\b", docstring), f"{name} is missing from the hpc_snapshot.py docstring"


# The node availability rule is HPCCore's allow-list (NodeStateInfo): only
# idle, mixed, allocated, completing and planned nodes without a blocking
# flag accept work. The old substring deny-list let these through as free
# capacity: a maintenance reservation ("$"), draining ("drng" has no
# "drain"), "unk" (no "unknown"), reservations, power-down and reboot flags.
@pytest.mark.parametrize(
    "state",
    [
        "idle$",
        "mix$",
        "alloc$",
        "drng",
        "drain",
        "resv",
        "maint",
        "futr",
        "boot",
        "pow_dn",
        "unk",
        "mix@",
        "idle^",
        "idle%",
        "idle!",
        "mix*",
        "down",
        "fail",
        "IDLE+DRAIN",
        "MIXED+MAINT",
        "npc",
    ],
)
def test_unavailable_nodes_never_advertised(state):
    snapshot = {
        "nodes": [{"state": state, "gres": "gpu:l40s:8", "gpu_idle": 8, "gpu_total": 8, "cpu_idle": 128}]
    }
    figures = cluster_figures(snapshot)
    assert figures.fleet.idle == 0
    assert figures.fleet.unavailable == 8
    assert figures.unavailable_nodes == 1


# "~"/"#": powered down (or powering up) to save energy, which the scheduler
# resumes on demand, so the node still counts; "-"/planned is backfill.
@pytest.mark.parametrize("state", ["idle", "mix-", "plnd", "idle~", "idle#", "MIXED+PLANNED", "comp"])
def test_available_nodes_count(state):
    snapshot = {
        "nodes": [{"state": state, "gres": "gpu:l40s:8", "gpu_idle": 8, "gpu_total": 8, "cpu_idle": 128}]
    }
    figures = cluster_figures(snapshot)
    assert figures.fleet.idle == 8
    assert figures.unavailable_nodes == 0


def test_unknown_gpu_allocation_not_zero():
    snapshot = {"nodes": [{"state": "mix", "gpu_idle": None, "gpu_total": 8, "cpu_idle": 32}]}
    pool = cluster_figures(snapshot).fleet.primary
    assert pool is not None
    assert pool.idle == 0
    assert pool.unknown == 8
    assert pool.idle_figure == "?"


def test_free_capacity_and_jobs():
    # The demo's AIRE pool: 5 startable, 1 stranded on a CPU-full node, 2
    # idle on a draining node.
    figures = cluster_figures(demo.snapshots()["aire"])
    assert (figures.fleet.idle, figures.fleet.stranded, figures.fleet.unavailable) == (5, 1, 2)
    assert figures.counts.running == figures.counts.pending == 1
    assert (figures.cpu_idle, figures.cpu_total) == (216, 336)


def test_cache_scoped_by_account_and_cluster(tmp_path):
    store = LocalStore(tmp_path)
    snapshot = demo.snapshots()["aire"]
    store.save("demo", "aire", snapshot, demo.history(0))
    assert store.load("demo", "aire")[0] == snapshot
    assert store.load("other", "aire") == (None, [])
    assert store.load("demo", "calder") == (None, [])
    saved = json.loads((tmp_path / "demo-aire.json").read_text())
    saved["snapshot"]["remote"]["user"] = "other"
    (tmp_path / "demo-aire.json").write_text(json.dumps(saved))
    assert store.load("demo", "aire") == (None, [])


@pytest.mark.parametrize("content", ["not json", "null", "[]", "{}"])
def test_corrupt_cache_is_ignored(tmp_path, content):
    (tmp_path / "demo-aire.json").write_text(content)
    assert LocalStore(tmp_path).load("demo", "aire") == (None, [])


def test_cache_does_not_allow_paths(tmp_path):
    store = LocalStore(tmp_path)
    with pytest.raises(ValueError):
        store.cache_name("../elsewhere", "aire")
    with pytest.raises(ValueError):
        store.cache_name("demo", "../elsewhere")


def test_history_bounded_and_sanitized(tmp_path):
    store = LocalStore(tmp_path)
    row = demo.history(0)[0]
    store.save("demo", "aire", demo.snapshots()["aire"], [row] * 9000)
    assert len(store.load("demo", "aire")[1]) == 8640
    assert clean_history(
        [
            None,
            {},
            {"time": "bad"},
            {"time": row["time"], "gpu_idle": "oops"},
            {"time": row["time"], "gpu_idle": float("nan")},
            row,
        ]
    ) == [row]


@pytest.mark.parametrize("key", ["jobs", "nodes", "partitions", "storage", "errors", "warnings"])
def test_invalid_snapshot_fields(key):
    data = copy.deepcopy(demo.snapshots()["aire"])
    data[key] = "bad"
    with pytest.raises(ValueError):
        validate_snapshot(data, "aire", "demo")


def test_storage_not_collected_is_accepted_and_kept():
    # The collector reports storage as null when it was not collected (a
    # refresh between storage refreshes, an earlier df/quota/lfs still
    # stuck). The snapshot stays valid and None stays None, meaning "keep
    # the previous rows"; turning it into [] wiped them and the cache.
    data = copy.deepcopy(demo.snapshots()["aire"])
    data["storage"] = None
    assert validate_snapshot(data, "aire", "demo")["storage"] is None


def test_cache_keeps_uncollected_storage(tmp_path):
    store = LocalStore(tmp_path)
    data = copy.deepcopy(demo.snapshots()["aire"])
    data["storage"] = None
    store.save("demo", "aire", data, [])
    assert store.load("demo", "aire")[0]["storage"] is None


@pytest.mark.parametrize("value", ["2026-10-13T12:00:00+00:00", None])
def test_storage_collection_time_accepted(value):
    data = copy.deepcopy(demo.snapshots()["aire"])
    data["storage_collected_at"] = value
    assert validate_snapshot(data, "aire", "demo")["storage_collected_at"] == value


@pytest.mark.parametrize("value", [123, "yesterday"])
def test_bad_storage_collection_time_rejected(value):
    data = copy.deepcopy(demo.snapshots()["aire"])
    data["storage_collected_at"] = value
    with pytest.raises(ValueError):
        validate_snapshot(data, "aire", "demo")


@pytest.mark.parametrize(
    "section,key,value",
    [
        ("nodes", "cpu_other", "4"),
        ("storage", "file_limit", -1),
        ("storage", "available_gb", float("nan")),
        ("jobs", "pending_task_count", "57"),
        ("jobs", "array_job_id", [1]),
        ("jobs", "array_pending_tasks", 5),
    ],
)
def test_fields_the_rules_read_are_validated(section, key, value):
    data = copy.deepcopy(demo.snapshots()["aire"])
    data[section][0][key] = value
    with pytest.raises(ValueError):
        validate_snapshot(data, "aire", "demo")


@pytest.mark.parametrize("value", ["8", {}, True, -1, float("nan"), float("inf")])
def test_invalid_cached_capacity_rejected(value, tmp_path):
    data = demo.snapshots()["aire"]
    data["nodes"][0]["gpu_idle"] = value
    (tmp_path / "demo-aire.json").write_text(json.dumps({"snapshot": data}))
    assert LocalStore(tmp_path).load("demo", "aire") == (None, [])


@pytest.mark.parametrize("key,value", [("remote", None), ("cluster", []), ("collected_at", 123)])
def test_malformed_metadata_rejected(key, value):
    data = demo.snapshots()["aire"]
    data[key] = value
    with pytest.raises(ValueError):
        validate_snapshot(data, "aire", "demo")
