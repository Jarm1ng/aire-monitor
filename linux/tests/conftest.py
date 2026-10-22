import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")


@pytest.fixture(scope="session")
def qt_app():
    from PySide6.QtWidgets import QApplication
    from aire_linux.app import STYLE

    app = QApplication.instance() or QApplication([])
    app.setStyleSheet(STYLE)
    return app
