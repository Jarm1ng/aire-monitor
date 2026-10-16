import copy
import time
from unittest.mock import MagicMock

import pytest

from aire_linux import demo
from aire_linux.app import MainWindow
from aire_linux.core import LocalStore
from aire_linux.ssh import AuthenticationRejected, Cancelled


def finish(window):
    window.close()
    window.pool.waitForDone(3000)


def test_demo_widgets_and_filters(qt_app, tmp_path):
    window = MainWindow(LocalStore(tmp_path), is_demo=True)
    assert "DEMO" in window.windowTitle()
    assert window.tables["jobs"].rowCount() == 4
    assert window.tables["nodes"].rowCount() == 6
    window.cluster_filter.setCurrentIndex(2)
    assert window.tables["jobs"].rowCount() == 2
    assert window.tables["jobs"].item(0, 0).text() == "Calder"
    for index in range(7):
        window.nav.setCurrentRow(index)
        assert window.stack.currentIndex() == index
    assert not window.connect_button.isEnabled()
    assert list(tmp_path.iterdir()) == []
    finish(window)


def test_offline_cache_failure_keeps_last_snapshot(qt_app, tmp_path):
    store = LocalStore(tmp_path)
    snapshot = demo.snapshots()["aire"]
    store.save("demo", "aire", snapshot, demo.history(0))
    store.write("settings.json", {"username": "demo", "route": "direct"})
    window = MainWindow(store)
    assert window.states["aire"] == "CACHED / OFFLINE"
    assert window.tables["jobs"].rowCount() == 2
    window.receive("aire", None, RuntimeError("Offline for test"))
    assert window.snapshots["aire"] == snapshot
    assert "saved snapshot" in window.banner.text()
    assert "Offline for test" in window.banner.text()
    window.username.setText("other")
    window.load_account()
    assert window.snapshots == {}
    assert window.tables["jobs"].rowCount() == 0
    finish(window)


def test_async_worker_reports_success_and_failure(qt_app, tmp_path):
    window = MainWindow(LocalStore(tmp_path))
    results = []
    window.submit(lambda: 42, lambda value, error: results.append((value, error)))

    def fail():
        raise ValueError("test failure")

    window.submit(fail, lambda value, error: results.append((value, error)))
    deadline = time.monotonic() + 5
    while len(results) < 2 and time.monotonic() < deadline:
        qt_app.processEvents()
        time.sleep(0.01)
    assert (42, None) in results
    assert any(isinstance(error, ValueError) for _, error in results)
    finish(window)


def test_unrelated_cluster_failure_isolated(qt_app, tmp_path):
    window = MainWindow(LocalStore(tmp_path))
    window.account = "demo"
    window.receive("aire", demo.snapshots()["aire"], None)
    aire = copy.deepcopy(window.snapshots["aire"])
    window.receive("calder", None, RuntimeError("Calder offline"))
    assert window.snapshots["aire"] == aire
    assert window.states["aire"] == "CONNECTED"
    assert window.states["calder"] == "STALE / REFRESH FAILED"
    finish(window)


@pytest.mark.parametrize("error", [Cancelled("Cancelled"), AuthenticationRejected("Rejected")])
def test_cancelled_signin_stops_remaining_clusters(qt_app, tmp_path, monkeypatch, error):
    window = MainWindow(LocalStore(tmp_path))
    window.username.setText("demo")
    window.password.setText("test-only")
    window.manager.connect = MagicMock(side_effect=error)
    monkeypatch.setattr(window, "submit", lambda work, done: done(work(), None))
    window.connect_all()
    assert window.manager.connect.call_count == 1
    assert window.states["calder"] == "SIGN-IN CANCELLED"
    assert window.password.text() == ""
    finish(window)


def test_bad_capacity_does_not_replace_good_snapshot(qt_app, tmp_path):
    window = MainWindow(LocalStore(tmp_path))
    window.account = "demo"
    good = demo.snapshots()["aire"]
    window.receive("aire", good, None)
    bad = copy.deepcopy(good)
    bad["nodes"][0]["gpu_idle"] = "invalid"
    window.receive("aire", bad, None)
    assert window.snapshots["aire"] == good
    assert window.states["aire"] == "STALE / INVALID SNAPSHOT"
    assert "Invalid numeric field" in window.errors["aire"]
    finish(window)


def test_corrupt_saved_username_ignored(qt_app, tmp_path):
    store = LocalStore(tmp_path)
    store.write("settings.json", {"username": ["bad"]})
    window = MainWindow(store)
    assert window.username.text() == ""
    finish(window)
