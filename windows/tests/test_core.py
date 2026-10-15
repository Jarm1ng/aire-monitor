import copy
import json

import pytest

from aire_windows import demo
from aire_windows.core import (
    LocalStore,
    PROFILES,
    clean_history,
    metrics,
    validate_snapshot,
    validate_username,
)


@pytest.mark.parametrize("username", ["abcd1234", "ab_cd", "abc-12", "Abc.1"])
def test_username(username):
    assert validate_username(f" {username} ") == username


@pytest.mark.parametrize("username", ["", "-option", "a@leeds.ac.uk", "../user", "a/b", "a\\b", "a;pwd"])
def test_bad_username(username):
    with pytest.raises(ValueError):
        validate_username(username)


def test_profiles_match_collector_specs():
    assert len(PROFILES) == 2
    assert all(len(p.volumes) == 3 for p in PROFILES)
    assert PROFILES[0].gpu != PROFILES[1].gpu
    assert PROFILES[0].volumes[0] == PROFILES[1].volumes[0]


@pytest.mark.parametrize("state", ["down", "idle+drain", "mix*", "fail", "maint", "not_resp", "idle~"])
def test_unavailable_nodes_never_advertised(state):
    snapshot = {"nodes": [{"state": state, "gpu_idle": 8, "gpu_total": 8, "cpu_idle": 128}]}
    m = metrics(snapshot)
    assert m["gpu_idle"] is None
    assert m["cpu_idle"] is None
    assert m["unavailable"] == 1


def test_unknown_gpu_allocation_not_zero():
    snapshot = {"nodes": [{"state": "mix", "gpu_idle": None, "gpu_total": 8, "cpu_idle": 32}]}
    assert metrics(snapshot)["gpu_idle"] is None


def test_free_capacity_and_jobs():
    m = metrics(demo.snapshots()["aire"])
    assert m["gpu_idle"] == 8
    assert m["running"] == m["pending"] == 1


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
