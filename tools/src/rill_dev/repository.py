"""Read source identity and verified products from the checkout's build driver."""

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]


def _metadata(root: Path, *arguments: str) -> dict[str, Any]:
    output = subprocess.check_output(
        [sys.executable, str(root / "scripts/build_driver.py"), *arguments],
        cwd=root,
        text=True,
    )
    return json.loads(output)


def source_inputs(root: Path = ROOT) -> dict[str, str]:
    return _metadata(root, "source-inputs")


def release_products(path: Path, root: Path = ROOT) -> dict[str, Any]:
    # Paths supplied by callers are relative to their working directory.
    return _metadata(root, "receipt", str(path.resolve()), "--json")


def revision(root: Path = ROOT) -> str:
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
