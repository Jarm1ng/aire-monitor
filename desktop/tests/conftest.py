import importlib.util
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

# Modules that need more than the standard library. Where those packages are
# missing (a Mac with only the collector's Python, say), the stdlib-only
# tests still run and these are left out. CI installs everything and sets
# LEEDS_HPC_FULL_TESTS=1, so there a missing package is an error, never a
# silently smaller suite.
NEEDS = {
    "test_ssh.py": ("paramiko",),
    "test_transport.py": ("paramiko",),
    "test_widgets.py": ("PySide6", "paramiko"),
}
MISSING = sorted(
    {name for names in NEEDS.values() for name in names if importlib.util.find_spec(name) is None}
)
if MISSING and os.environ.get("LEEDS_HPC_FULL_TESTS") == "1":
    raise ImportError(f"LEEDS_HPC_FULL_TESTS=1 but not installed: {', '.join(MISSING)}")
collect_ignore = [module for module, names in NEEDS.items() if set(names) & set(MISSING)]


def pytest_report_header(config):
    if collect_ignore:
        return f"left out (missing {', '.join(MISSING)}): {', '.join(collect_ignore)}"
    return None


@pytest.fixture(scope="session")
def qt_app():
    from PySide6.QtWidgets import QApplication

    from leeds_hpc_desktop.app import STYLE

    app = QApplication.instance() or QApplication([])
    app.setStyleSheet(STYLE)
    return app
