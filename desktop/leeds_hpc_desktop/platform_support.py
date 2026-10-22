"""Everything that differs between the Windows and the Linux build.

The rest of the package is shared code. Keep this module free of PySide6,
paramiko and keyring imports at module level (they are imported inside the
functions that need them), so the stdlib-only tests can exercise both
platforms' rules on any machine. Functions take the platform as a parameter,
defaulting to the running one, for the same reason: the Windows branch is
then tested on Linux and macOS too, and pyright checks both branches on each
CI runner instead of narrowing one away.
"""

from __future__ import annotations

import importlib
import os
import sys
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# Credential Manager / Secret Service entry name. Changing it would orphan
# every password users have already saved.
CREDENTIAL_SERVICE = "LeedsHPCMonitor"
# Folder name under %LOCALAPPDATA% or the XDG data directory. Changing it
# would lose every cached snapshot, history and trusted host key.
APP_FOLDER = "LeedsHPCMonitor"
# Development override for the data folder (both platforms).
DATA_DIR_VARIABLE = "LEEDS_HPC_DATA_DIR"


@dataclass(frozen=True)
class PlatformTexts:
    name: str
    font_family: str
    remember_label: str
    forgot_message: str
    save_failed_message: str


WINDOWS = PlatformTexts(
    name="Windows",
    font_family="'Segoe UI'",
    remember_label="Save in Credential Manager",
    forgot_message="Saved password removed from Windows Credential Manager.",
    save_failed_message="Connected, but Credential Manager could not save the password.",
)
LINUX = PlatformTexts(
    name="Linux",
    font_family="'Inter', 'Cantarell', 'Ubuntu', 'Noto Sans', 'DejaVu Sans', sans-serif",
    remember_label="Save in System Keyring",
    forgot_message="Saved password removed from the system keyring.",
    save_failed_message="Connected, but the system keyring could not save the password.",
)


def is_windows(platform: str = sys.platform) -> bool:
    return platform == "win32"


def texts(platform: str = sys.platform) -> PlatformTexts:
    # Anything that is not Windows is treated as a freedesktop.org desktop:
    # the app ships for Windows and Linux only, and a developer running the
    # tests on macOS gets the Linux wording.
    return WINDOWS if is_windows(platform) else LINUX


def data_dir(environ: Mapping[str, str] = os.environ, platform: str = sys.platform) -> Path:
    """Where settings, known_hosts and the snapshot caches live.

    Windows: %LOCALAPPDATA%\\LeedsHPCMonitor (the home folder if the variable
    is missing). Linux: ${XDG_DATA_HOME:-~/.local/share}/LeedsHPCMonitor.
    LEEDS_HPC_DATA_DIR overrides both, for development and tests.
    """
    override = environ.get(DATA_DIR_VARIABLE)
    # An empty override is ignored: Path("") would put private snapshots in
    # whatever the current directory happens to be.
    if override:
        return Path(override)
    if is_windows(platform):
        local = environ.get("LOCALAPPDATA")
        return (Path(local) if local else Path.home()) / APP_FOLDER
    xdg = environ.get("XDG_DATA_HOME")
    # The XDG Base Directory spec: an unset, empty or relative value means
    # the default, so a relative one never resolves against the cwd.
    base = Path(xdg) if xdg and os.path.isabs(xdg) else Path.home() / ".local" / "share"
    return base / APP_FOLDER


def make_private_dir(path: Path, platform: str = sys.platform) -> None:
    """Create the data folder; on POSIX restrict it to its owner (0700)."""
    if is_windows(platform):
        # Windows keeps the profile's inherited ACL, as WINDOWS_APP.md says.
        # No mode argument: since Python 3.13, mkdir(mode=0o700) applies an
        # owner-only ACL on Windows instead of being ignored.
        path.mkdir(parents=True, exist_ok=True)
        return
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    # mkdir's mode is filtered by the umask and ignored for a folder that
    # already exists (for example one created by an older build).
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass


def make_private_file(path: Path, platform: str = sys.platform) -> None:
    """Owner-only (0600) on POSIX; on Windows the folder's ACL applies."""
    if is_windows(platform):
        return
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def credential_backend(platform: str = sys.platform) -> Any:
    """The keyring backend for the optional saved password.

    Chosen explicitly, never through keyring.get_keyring(): that could fall
    back to a plaintext or third-party backend.
    """
    if is_windows(platform):
        from keyring.backends.Windows import WinVaultKeyring

        return WinVaultKeyring()
    if platform.startswith("linux"):
        from keyring.backends.SecretService import Keyring

        return Keyring()
    raise RuntimeError(
        "Password saving is available only in Windows Credential Manager or a Linux Secret Service keyring."
    )


def smoke_check(platform: str = sys.platform) -> None:
    """Offline proof, run by the frozen build's --smoke-test, that the
    credential store's code was bundled. Neither branch talks to the store
    itself: CI has no Credential Manager session and no D-Bus."""
    if is_windows(platform):
        # priority raises when pywin32-ctypes' credential API is missing.
        if not credential_backend(platform).priority > 0:
            raise RuntimeError("The Windows Credential Manager backend is unavailable.")
    elif platform.startswith("linux"):
        # Constructing the Secret Service backend proves nothing (keyring
        # swallows a failed secretstorage import and Keyring() makes no D-Bus
        # call), so import what it needs and check the version keyring
        # requires. importlib keeps pyright quiet on Windows, where
        # secretstorage is not installed.
        secretstorage = importlib.import_module("secretstorage")
        importlib.import_module("jeepney")
        version = getattr(secretstorage, "__version_tuple__", None)
        if version is not None and tuple(version) < (3, 2):
            raise RuntimeError(f"SecretStorage {version} is older than keyring needs (3.2).")
        credential_backend(platform)


def tray_available() -> bool:
    """Whether a system tray can show our icon.

    Stock GNOME Shell (without the AppIndicator extension) and some tiling
    window managers have none: a QSystemTrayIcon there never appears, so a
    window hidden "to the tray" could not be brought back. Needs a
    QApplication.
    """
    from PySide6.QtWidgets import QSystemTrayIcon

    return QSystemTrayIcon.isSystemTrayAvailable()
