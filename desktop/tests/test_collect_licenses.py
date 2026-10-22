"""The build's licence collector, against fake installed distributions."""

import importlib.metadata
from pathlib import Path, PurePosixPath

import pytest

import collect_licenses


class FakeDistribution:
    def __init__(self, root, name, files):
        self.version = "1.0"
        self.root = root / name
        self.files = [PurePosixPath(file) for file in files]
        for file in self.files:
            path = self.root / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"{name} {file.name}\n")

    def locate_file(self, file):
        return self.root / file


def install(monkeypatch, root, names):
    installed = {
        name: FakeDistribution(root, name, [f"{name}.dist-info/licenses/LICENSE", f"{name}/module.py"])
        for name in names
    }
    # tzdata ships two licence files; Apache-2.0 requires the second one.
    if "tzdata" in installed:
        installed["tzdata"] = FakeDistribution(
            root, "tzdata", ["tzdata.dist-info/licenses/LICENSE", "tzdata.dist-info/licenses/LICENSE_APACHE"]
        )

    def distribution(name):
        if name not in installed:
            raise importlib.metadata.PackageNotFoundError(name)
        return installed[name]

    monkeypatch.setattr(importlib.metadata, "distribution", distribution)


def test_windows_build_ships_tzdata_licence(monkeypatch, tmp_path):
    install(monkeypatch, tmp_path / "site", collect_licenses.REQUIRED + ("tzdata", "pywin32-ctypes", "cffi"))
    out = tmp_path / "licenses"
    collect_licenses.collect(out, "win32")
    assert (out / "tzdata" / "tzdata.dist-info" / "licenses" / "LICENSE_APACHE").is_file()
    assert (out / "paramiko" / "paramiko.dist-info" / "licenses" / "LICENSE").is_file()
    assert not (out / "paramiko" / "paramiko" / "module.py").exists()
    versions = (out / "VERSIONS.txt").read_text().split()
    assert "tzdata==1.0" in versions and "cffi==1.0" in versions
    # Missing optional ones (SecretStorage on Windows, pycparser) are skipped.
    assert not any(line.startswith(("SecretStorage", "pycparser")) for line in versions)
    assert (out / "Python-LICENSE.txt").is_file()
    assert (out / "GNU" / "LGPL-2.1.txt").is_file()


@pytest.mark.parametrize(
    "platform,missing", [("win32", "tzdata"), ("linux", "SecretStorage"), ("linux", "paramiko")]
)
def test_missing_required_licence_stops_the_build(monkeypatch, tmp_path, platform, missing):
    own = collect_licenses.PLATFORM_REQUIRED[collect_licenses.platform_key(platform)]
    names = collect_licenses.REQUIRED + own
    install(monkeypatch, tmp_path / "site", tuple(name for name in names if name != missing))
    with pytest.raises(SystemExit, match=missing):
        collect_licenses.collect(tmp_path / "licenses", platform)
    assert not (tmp_path / "licenses").exists()


def test_linux_build_does_not_need_windows_components(monkeypatch, tmp_path):
    install(monkeypatch, tmp_path / "site", collect_licenses.REQUIRED + ("SecretStorage", "jeepney"))
    collect_licenses.collect(tmp_path / "licenses", "linux")
    assert Path(tmp_path / "licenses" / "jeepney" / "jeepney.dist-info" / "licenses" / "LICENSE").is_file()
