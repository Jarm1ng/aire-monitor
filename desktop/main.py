import sys
from pathlib import Path

if not getattr(sys, "frozen", False):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from leeds_hpc_desktop.app import main

if __name__ == "__main__":
    raise SystemExit(main())
