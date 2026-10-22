import copy
import time
from datetime import datetime, timedelta
from unittest.mock import MagicMock

import pytest

from leeds_hpc_desktop import demo, platform_support
from leeds_hpc_desktop.app import FileBrowser, MainWindow
from leeds_hpc_desktop.core import PROFILES, LocalStore
from leeds_hpc_desktop.ssh import AuthenticationRejected, Cancelled, PasswordRejected, Session


def finish(window):
    window.close()
    window.pool.waitForDone(3000)


def test_demo_widgets_and_filters(qt_app, tmp_path):
    window = MainWindow(LocalStore(tmp_path), is_demo=True)
    assert "DEMO" in window.windowTitle()
    assert window.tables["jobs"].rowCount() == 4
    assert window.tables["nodes"].rowCount() == 12
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


def test_without_a_tray_the_window_is_never_hidden(qt_app, tmp_path, monkeypatch):
    # e.g. stock GNOME: hiding into a tray that does not exist would leave no
    # way back to the window, with the SSH sessions still open.
    monkeypatch.setattr(platform_support, "tray_available", lambda: False)
    window = MainWindow(LocalStore(tmp_path))
    window.show()
    assert window.tray is None
    assert window.minimize_button.text() == "Minimize"
    window.minimize()
    assert not window.isHidden()
    # Job changes go to the banner instead of a tray notification.
    window.account = "demo"
    first = demo.snapshots()["aire"]
    window.receive("aire", first, None)
    second = copy.deepcopy(first)
    second["jobs"][1]["state"] = "RUNNING"
    window.receive("aire", second, None)
    assert "AIRE jobs: 8100: PENDING → RUNNING" in window.banner.text()
    finish(window)


def test_with_a_tray_minimize_hides_into_it(qt_app, tmp_path, monkeypatch):
    monkeypatch.setattr(platform_support, "tray_available", lambda: True)
    window = MainWindow(LocalStore(tmp_path))
    window.show()
    assert window.tray is not None
    assert window.minimize_button.text() == "Minimize to tray"
    window.minimize()
    assert window.isHidden()
    finish(window)


def test_cards_name_each_gpu_model_and_count_array_tasks(qt_app, tmp_path):
    # Headings come from the pools the snapshot reports, never a fixed
    # model; an idle L40 is not added to the H200 figure; an array's
    # pending remainder counts as its 8 tasks and shows its task range.
    window = MainWindow(LocalStore(tmp_path), is_demo=True)
    _, name, _, summary, details = window.cards["calder"]
    assert name.text() == "Calder  /  H200 + L40 GPUs"
    assert summary.text() == "1 running · 8 pending   /   3 of 24 H200 idle · +1 more model"
    assert "L40: 0 of 3 idle · all 3 unavailable" in details.text()
    assert "156 of 256 CPUs idle on CPU nodes" in details.text()
    window.cluster_filter.setCurrentIndex(2)
    jobs = window.tables["jobs"]
    assert {jobs.item(row, 1).text() for row in range(jobs.rowCount())} == {"7101", "8101_[2-9]"}
    finish(window)


def test_storage_rows_survive_refreshes_that_skip_storage(qt_app, tmp_path):
    # storage None means "not collected this time": the rows on screen,
    # their collection time and the cached copy all stay.
    store = LocalStore(tmp_path)
    window = MainWindow(store)
    window.account = "demo"
    first = demo.snapshots()["aire"]
    window.receive("aire", first, None)
    later = copy.deepcopy(first)
    later["collected_at"] = (
        datetime.fromisoformat(first["collected_at"]) + timedelta(seconds=10)
    ).isoformat()
    later["storage"] = None
    window.receive("aire", later, None, requested_storage=False)
    assert window.states["aire"] == "CONNECTED"
    assert window.snapshots["aire"]["storage"] == first["storage"]
    assert window.snapshots["aire"]["storage_collected_at"] == first["collected_at"]
    assert window.tables["storage"].rowCount() == 2
    cached, _ = store.load("demo", "aire")
    assert cached is not None and cached["storage"] == first["storage"]
    finish(window)


def test_refreshes_collect_storage_only_when_due(qt_app, tmp_path, monkeypatch):
    # The first refresh collects storage, the next ones skip it (the macOS
    # cadence: every 5 minutes), and Refresh now always collects it.
    window = MainWindow(LocalStore(tmp_path))
    window.account = "demo"
    requests = []

    class FakeSession:
        connected = True

        def collect(self, username, skip_storage=False):
            requests.append(skip_storage)
            snapshot = demo.snapshots()["aire"]
            if skip_storage:
                snapshot["storage"] = None
            return snapshot

        def close(self):
            pass

    window.manager.sessions = {"aire": FakeSession()}
    monkeypatch.setattr(window, "submit", lambda work, done: done(work(), None))
    window.refresh_all()
    window.refresh_all()
    window.refresh_now()
    assert requests == [False, True, False]
    assert window.snapshots["aire"]["storage"] == demo.snapshots()["aire"]["storage"]
    finish(window)


class FakeVault:
    def __init__(self, saved=None):
        self.saved = dict(saved or {})
        self.reads = 0

    def get_password(self, service, username):
        self.reads += 1
        return self.saved.get(username)

    def set_password(self, service, username, password):
        self.saved[username] = password

    def delete_password(self, service, username):
        self.saved.pop(username, None)


class FakeClusterSession:
    connected = True

    def __init__(self, profile):
        self.profile = profile

    def collect(self, username, skip_storage=False):
        return demo.snapshots()[self.profile.id]

    def close(self):
        pass


def synchronous(window, monkeypatch):
    problems = []
    monkeypatch.setattr(window, "problem", problems.append)
    monkeypatch.setattr(window, "submit", lambda work, done: done(work(), None))
    return problems


def test_rejected_saved_password_is_never_sent_again(qt_app, tmp_path, monkeypatch):
    # The macOS rule: after a server refuses the saved password, an empty
    # password field never sends it again (each try counts towards the
    # account lockout), until a typed password is accepted and replaces it.
    vault = FakeVault({"demo": "old-pass"})
    monkeypatch.setattr(platform_support, "credential_backend", lambda: vault)
    store = LocalStore(tmp_path)
    window = MainWindow(store)
    problems = synchronous(window, monkeypatch)
    sent = []

    def refuse(profile, username, password, route):
        sent.append(password)
        raise PasswordRejected(f"{profile.host} rejected the password.")

    window.manager.connect = refuse
    window.username.setText("demo")
    window.connect_all()
    # One attempt: the other cluster is skipped, not sent the same password.
    assert sent == ["old-pass"]
    assert store.saved_password_rejected("demo")
    assert any("will not be sent again" in problem for problem in problems)
    assert "rejected" in window.password.placeholderText()
    reads = vault.reads
    window.connect_all()
    assert sent == ["old-pass"]
    assert vault.reads == reads
    finish(window)

    # A new run remembers it.
    window = MainWindow(store)
    problems = synchronous(window, monkeypatch)
    window.manager.connect = refuse
    window.connect_all()
    assert sent == ["old-pass"]
    assert "rejected" in problems[-1]

    # A typed password a server accepts, with Save ticked, replaces it.
    def accept(profile, username, password, route):
        sent.append(password)
        return FakeClusterSession(profile), True

    window.manager.connect = accept
    window.password.setText("new-pass")
    window.remember.setChecked(True)
    window.connect_all()
    assert vault.saved["demo"] == "new-pass"
    assert not store.saved_password_rejected("demo")
    assert window.password.placeholderText() == "Password (or saved credential)"
    assert window.states["aire"] == "CONNECTED"
    finish(window)


def test_password_is_saved_only_once_a_server_accepted_it(qt_app, tmp_path, monkeypatch):
    # Reusing open sessions sends nothing, so it proves nothing.
    vault = FakeVault()
    monkeypatch.setattr(platform_support, "credential_backend", lambda: vault)
    window = MainWindow(LocalStore(tmp_path))
    synchronous(window, monkeypatch)
    window.manager.connect = lambda profile, username, password, route: (FakeClusterSession(profile), False)
    window.username.setText("demo")
    window.password.setText("never-checked")
    window.remember.setChecked(True)
    window.connect_all()
    assert vault.saved == {}
    assert window.password.text() == ""
    finish(window)


def test_disconnect_works_while_a_refresh_runs(qt_app, tmp_path, monkeypatch):
    # e.g. a VPN expiry: the refresh waits on a link that no longer answers.
    window = MainWindow(LocalStore(tmp_path))
    window.account = "demo"
    pending = []
    monkeypatch.setattr(window, "submit", lambda work, done: pending.append(done))
    window.manager.sessions = {"aire": FakeClusterSession(PROFILES[0])}
    window.refresh_all()
    assert window.busy == {"aire"}
    window.disconnect()
    assert window.busy == set()
    assert window.manager.sessions == {}
    assert window.states["aire"] == "DISCONNECTED"
    assert window.connect_button.isEnabled()
    # The refresh's late result belongs to the closed session: ignored.
    pending[0](demo.snapshots()["aire"], None)
    assert "aire" not in window.snapshots
    assert window.states["aire"] == "DISCONNECTED"
    finish(window)


def test_disconnect_cancels_a_sign_in_and_connect_is_never_silently_ignored(qt_app, tmp_path, monkeypatch):
    window = MainWindow(LocalStore(tmp_path))
    pending = []
    monkeypatch.setattr(window, "submit", lambda work, done: pending.append(done))
    window.username.setText("demo")
    window.password.setText("test-only")
    window.connect_all()
    assert window.connecting
    window.connect_all()
    assert "already running" in window.status.text()
    assert len(pending) == 1
    assert window.disconnect_button.isEnabled()
    window.disconnect()
    assert window.states["aire"] == "SIGN-IN CANCELLED"
    # Connect returns once the abandoned worker reports in; whatever it
    # brings back is not shown as live.
    assert window.connecting
    pending[0]([("aire", demo.snapshots()["aire"], None)], None)
    assert not window.connecting and window.connect_button.isEnabled()
    assert "aire" not in window.snapshots
    finish(window)


def test_failed_sign_in_leaves_the_account_and_route_editable(qt_app, tmp_path, monkeypatch):
    # Off VPN, "Direct" times out; the documented fix (switch to rash) must
    # then work without a Disconnect first.
    window = MainWindow(LocalStore(tmp_path))
    synchronous(window, monkeypatch)
    monkeypatch.setattr(
        Session, "collect", lambda self, username, skip_storage=False: demo.snapshots()[self.profile.id]
    )
    window.manager._open = MagicMock(side_effect=OSError("timed out"))
    window.username.setText("demo")
    window.password.setText("test-only")
    window.connect_all()
    assert window.states["aire"] == "STALE / REFRESH FAILED"
    assert window.username.isEnabled() and window.route.isEnabled()
    window.route.setCurrentIndex(1)
    window.manager._open = MagicMock(side_effect=lambda *args, **kwargs: (MagicMock(), True))
    window.password.setText("test-only")
    window.connect_all()
    assert window.manager.route == "jump"
    assert window.states["aire"] == window.states["calder"] == "CONNECTED"
    assert not window.username.isEnabled() and not window.route.isEnabled()
    finish(window)


def test_connect_when_already_connected_refreshes_without_a_password(qt_app, tmp_path, monkeypatch):
    vault = FakeVault({"demo": "saved"})
    monkeypatch.setattr(platform_support, "credential_backend", lambda: vault)
    window = MainWindow(LocalStore(tmp_path))
    synchronous(window, monkeypatch)
    window.account = "demo"
    window.username.setText("demo")
    window.manager.sessions = {"aire": FakeClusterSession(PROFILES[0])}
    window.enabled["calder"].setChecked(False)
    window.manager.connect = MagicMock()
    window.connect_all()
    window.manager.connect.assert_not_called()
    assert vault.reads == 0
    assert window.states["aire"] == "CONNECTED"
    finish(window)


def test_file_browser_follows_links_and_opens_what_is_listed(qt_app, tmp_path, monkeypatch):
    window = MainWindow(LocalStore(tmp_path))
    monkeypatch.setattr(window, "submit", lambda work, done: done(*call(work)))

    def call(work):
        try:
            return work(), None
        except Exception as exc:
            return None, exc

    class Files(FakeClusterSession):
        def __init__(self, profile):
            super().__init__(profile)
            self.calls = []

        def files(self, path):
            self.calls.append(("files", path))
            if path == "/elsewhere":
                raise OSError("No such file")
            return path, [
                {"name": "scratch", "directory": False, "symlink": True, "bytes": 0, "modified": 0},
                {"name": "train.log", "directory": False, "symlink": False, "bytes": 5, "modified": 0},
            ]

        def is_directory(self, path):
            self.calls.append(("stat", path))
            return path.endswith("scratch")

        def preview(self, path, tail=False):
            self.calls.append(("preview", path))
            return "text"

    session = Files(PROFILES[0])
    window.manager.sessions = {"aire": session}
    browser = FileBrowser(window, PROFILES[0], "/users/demo")

    def row(name):
        listing = browser.listing
        return next(r for r in range(listing.rowCount()) if listing.item(r, 0).text() == name)

    # A typed folder that fails to open leaves the old listing on screen...
    browser.path.setText("/elsewhere")
    browser.browse()
    assert "No such file" in browser.message.text()
    # ...and a double-click opens the file shown, from the folder listed.
    browser.open_entry(row("train.log"), 0)
    assert session.calls[-1] == ("preview", "/users/demo/train.log")
    # A link to a folder opens as a folder.
    browser.open_entry(row("scratch"), 0)
    assert session.calls[-2:] == [("stat", "/users/demo/scratch"), ("files", "/users/demo/scratch")]
    assert browser.current == "/users/demo/scratch"
    browser.close()
    finish(window)
