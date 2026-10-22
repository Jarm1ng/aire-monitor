"""Include installed licence texts for the runtime and its dependencies.

Both build scripts run this after PyInstaller, with the bundle's licences/
folder as the argument.
"""

import importlib.metadata
import shutil
import sys
from pathlib import Path

# Bundled on every platform: a missing one means a broken build environment,
# so the build stops rather than ship a component without its licence.
REQUIRED = (
    "PySide6",
    "shiboken6",
    "paramiko",
    "cryptography",
    "bcrypt",
    "pynacl",
    "keyring",
    "PyInstaller",
)
# Bundled on one platform only, so required there: the Windows build
# collects tzdata's zone files (Apache-2.0 §4 requires shipping its licence)
# and keyring's Credential Manager backend needs pywin32-ctypes; the Linux
# build bundles SecretStorage and jeepney for the Secret Service backend.
PLATFORM_REQUIRED = {
    "win32": ("tzdata", "pywin32-ctypes"),
    "linux": ("SecretStorage", "jeepney"),
}
# Transitive dependencies whose presence depends on upstream releases (cffi
# 2.0 made pycparser conditional, for example) or that only a dev tool pulls
# in (typing_extensions comes with pyright): collected when installed.
OPTIONAL = (
    "PySide6-Essentials",
    "PySide6-Addons",
    "cffi",
    "pycparser",
    "invoke",
    "jaraco.classes",
    "jaraco.context",
    "jaraco.functools",
    "more-itertools",
    "setuptools",
    "packaging",
    "typing_extensions",
    "altgraph",
)


def platform_key(platform: str) -> str:
    return "linux" if platform.startswith("linux") else platform


def _copy_python_license(destination: Path) -> None:
    candidates = (
        Path(sys.base_prefix) / "LICENSE.txt",
        Path(sys.base_prefix) / "LICENSE",
        Path(sys.base_prefix)
        / "lib"
        / f"python{sys.version_info.major}.{sys.version_info.minor}"
        / "LICENSE.txt",
        Path(f"/usr/share/doc/python{sys.version_info.major}.{sys.version_info.minor}/copyright"),
        Path("/usr/share/doc/python3/copyright"),
    )
    for candidate in candidates:
        if candidate.is_file():
            shutil.copyfile(candidate, destination / "Python-LICENSE.txt")
            return
    (destination / "Python-LICENSE.txt").write_text(
        "Python Software Foundation License Version 2\nhttps://docs.python.org/3/license.html\n",
        encoding="utf-8",
    )


def collect(destination, platform: str = sys.platform):
    destination = Path(destination)
    required = REQUIRED + PLATFORM_REQUIRED.get(platform_key(platform), ())
    # The other platform's components are collected too if they happen to
    # be installed; they are simply not required here.
    optional = OPTIONAL + tuple(
        name for names in PLATFORM_REQUIRED.values() for name in names if name not in required
    )
    distributions = {}
    missing = []
    for name in required + optional:
        try:
            distributions[name] = importlib.metadata.distribution(name)
        except importlib.metadata.PackageNotFoundError:
            if name in required:
                missing.append(name)
    if missing:
        raise SystemExit(f"Cannot include the licences of {', '.join(missing)}: not installed.")
    destination.mkdir(parents=True, exist_ok=True)
    manifest = []
    for name, distribution in distributions.items():
        manifest.append(f"{name}=={distribution.version}")
        for file in distribution.files or []:
            if any(token in file.name.lower() for token in ("license", "copying", "notice")):
                source = Path(distribution.locate_file(file))
                if source.is_file() and ".." not in file.parts:
                    target = destination / name / file
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
    _copy_python_license(destination)
    shutil.copytree(Path(__file__).parent / "licenses", destination / "GNU", dirs_exist_ok=True)
    (destination / "VERSIONS.txt").write_text("\n".join(manifest) + "\n", encoding="utf-8")


if __name__ == "__main__":
    collect(sys.argv[1])
