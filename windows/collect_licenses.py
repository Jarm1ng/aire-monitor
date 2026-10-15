"""Include installed licence texts for the runtime and its dependencies."""

import importlib.metadata
import shutil
import sys
from pathlib import Path

RUNTIME = (
    "PySide6",
    "PySide6-Essentials",
    "PySide6-Addons",
    "shiboken6",
    "paramiko",
    "cryptography",
    "bcrypt",
    "pynacl",
    "keyring",
    "cffi",
    "pycparser",
    "invoke",
    "jaraco.classes",
    "jaraco.context",
    "jaraco.functools",
    "more-itertools",
    "pywin32-ctypes",
    "PyInstaller",
    "setuptools",
    "packaging",
    "typing_extensions",
    "altgraph",
)


def collect(destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    manifest = []
    for name in RUNTIME:
        distribution = importlib.metadata.distribution(name)
        manifest.append(f"{name}=={distribution.version}")
        for file in distribution.files or []:
            if any(token in file.name.lower() for token in ("license", "copying", "notice")):
                source = Path(distribution.locate_file(file))
                if source.is_file() and ".." not in file.parts:
                    target = destination / name / file
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
    shutil.copyfile(Path(sys.base_prefix) / "LICENSE.txt", destination / "Python-LICENSE.txt")
    shutil.copytree(Path(__file__).parent / "licenses", destination / "GNU", dirs_exist_ok=True)
    (destination / "VERSIONS.txt").write_text("\n".join(manifest) + "\n", encoding="utf-8")


if __name__ == "__main__":
    collect(sys.argv[1])
