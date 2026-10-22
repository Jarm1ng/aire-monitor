"""The Windows/Linux differences (platform_support), tested for both
platforms on any machine: the functions take the platform as a parameter."""

import os
import stat
import sys
import types
from pathlib import Path

import pytest

from leeds_hpc_desktop import platform_support
from leeds_hpc_desktop.core import KNOWN_HOSTS_FILE, SETTINGS_FILE, LocalStore
from leeds_hpc_desktop.platform_support import data_dir, make_private_dir, make_private_file


def test_on_disk_names_are_stable():
    # Existing installs have saved passwords, caches and trusted host keys
    # under these names; renaming any of them would silently lose them.
    assert platform_support.CREDENTIAL_SERVICE == "LeedsHPCMonitor"
    assert platform_support.APP_FOLDER == "LeedsHPCMonitor"
    assert (SETTINGS_FILE, KNOWN_HOSTS_FILE) == ("settings.json", "known_hosts")


def test_windows_data_dir_is_local_appdata(tmp_path):
    local = str(tmp_path / "AppData" / "Local")
    expected = Path(local) / "LeedsHPCMonitor"
    assert data_dir({"LOCALAPPDATA": local}, "win32") == expected
    # XDG_DATA_HOME means nothing on Windows; a missing LOCALAPPDATA falls
    # back to the home folder.
    assert data_dir({"LOCALAPPDATA": local, "XDG_DATA_HOME": "/xdg"}, "win32") == expected
    assert data_dir({}, "win32") == Path.home() / "LeedsHPCMonitor"
    assert data_dir({"LOCALAPPDATA": ""}, "win32") == Path.home() / "LeedsHPCMonitor"


def test_linux_data_dir_follows_xdg(tmp_path):
    xdg = str(tmp_path / "xdg")
    assert data_dir({"XDG_DATA_HOME": xdg}, "linux") == Path(xdg) / "LeedsHPCMonitor"
    default = Path.home() / ".local" / "share" / "LeedsHPCMonitor"
    assert data_dir({}, "linux") == default
    # Unset, empty and relative values all mean the default (XDG spec).
    assert data_dir({"XDG_DATA_HOME": ""}, "linux") == default
    assert data_dir({"XDG_DATA_HOME": "relative/dir"}, "linux") == default
    assert data_dir({"LOCALAPPDATA": str(tmp_path)}, "linux") == default


@pytest.mark.parametrize("platform", ["win32", "linux"])
def test_override_wins_on_both_platforms(tmp_path, platform):
    environ = {"LEEDS_HPC_DATA_DIR": str(tmp_path / "custom"), "LOCALAPPDATA": "x", "XDG_DATA_HOME": "/x"}
    assert data_dir(environ, platform) == tmp_path / "custom"
    # An empty override is ignored rather than meaning the current directory.
    empty = {"LEEDS_HPC_DATA_DIR": "", "LOCALAPPDATA": str(tmp_path), "XDG_DATA_HOME": str(tmp_path)}
    assert data_dir(empty, platform) == tmp_path / "LeedsHPCMonitor"


def test_store_uses_the_override(monkeypatch, tmp_path):
    monkeypatch.setenv("LEEDS_HPC_DATA_DIR", str(tmp_path / "isolated"))
    assert LocalStore().root == tmp_path / "isolated"
    assert (tmp_path / "isolated").is_dir()


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX permission bits")
def test_posix_store_is_owner_only(tmp_path):
    root = tmp_path / "data"
    root.mkdir(mode=0o755)
    os.chmod(root, 0o755)
    # An existing folder (from an older build) is tightened too.
    store = LocalStore(root)
    assert stat.S_IMODE(root.stat().st_mode) == 0o700
    store.write(SETTINGS_FILE, {"username": "demo"})
    assert stat.S_IMODE((root / SETTINGS_FILE).stat().st_mode) == 0o600


def test_windows_keeps_inherited_permissions(monkeypatch, tmp_path):
    # Windows relies on the profile's inherited ACL: no chmod at all, and no
    # mkdir mode (on Python 3.13+ that would apply an owner-only ACL).
    def no_chmod(*args, **kwargs):
        raise AssertionError("chmod called on Windows")

    monkeypatch.setattr(os, "chmod", no_chmod)
    make_private_dir(tmp_path / "data", "win32")
    assert (tmp_path / "data").is_dir()
    (tmp_path / "data" / "file").write_text("x")
    make_private_file(tmp_path / "data" / "file", "win32")


def test_texts_name_each_platform_and_its_store():
    windows, linux = platform_support.texts("win32"), platform_support.texts("linux")
    assert (windows.name, windows.remember_label) == ("Windows", "Save in Credential Manager")
    assert (linux.name, linux.remember_label) == ("Linux", "Save in System Keyring")
    assert "Credential Manager" in windows.forgot_message + windows.save_failed_message
    assert "keyring" in linux.forgot_message and "keyring" in linux.save_failed_message
    assert "Segoe UI" in windows.font_family and "sans-serif" in linux.font_family


def test_no_credential_store_elsewhere():
    # Never a keyring.get_keyring() fallback (which could be plaintext).
    with pytest.raises(RuntimeError, match="Credential Manager or a Linux Secret Service"):
        platform_support.credential_backend("darwin")


def test_linux_smoke_check_needs_a_usable_secretstorage(monkeypatch):
    # The frozen build's --smoke-test: a bundle without secretstorage or
    # jeepney (or with one too old for keyring) must fail in CI, not for users.
    monkeypatch.setattr(platform_support, "credential_backend", lambda platform: object())
    secretstorage = types.ModuleType("secretstorage")
    monkeypatch.setitem(sys.modules, "secretstorage", secretstorage)
    monkeypatch.setitem(sys.modules, "jeepney", types.ModuleType("jeepney"))
    setattr(secretstorage, "__version_tuple__", (3, 1))
    with pytest.raises(RuntimeError, match="older than keyring needs"):
        platform_support.smoke_check("linux")
    setattr(secretstorage, "__version_tuple__", (3, 3, 3))
    platform_support.smoke_check("linux")
    # None in sys.modules makes the import fail, as a missing module would.
    monkeypatch.setitem(sys.modules, "jeepney", None)
    with pytest.raises(ImportError):
        platform_support.smoke_check("linux")
