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
    "SecretStorage",
    "jeepney",
    "cffi",
    "pycparser",
    "invoke",
    "jaraco.classes",
    "jaraco.context",
    "jaraco.functools",
    "more-itertools",
    "PyInstaller",
    "setuptools",
    "packaging",
    "typing_extensions",
    "altgraph",
)


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


def collect(destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    manifest = []
    for name in RUNTIME:
        try:
            distribution = importlib.metadata.distribution(name)
        except importlib.metadata.PackageNotFoundError:
            continue
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
