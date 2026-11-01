import os
from pathlib import Path


def permission_examples(path: Path) -> None:
    # ruleid: private-evaluation-permissions
    os.open(path, os.O_CREAT, 0o644)
    # ruleid: private-evaluation-permissions
    path.chmod(0o777)
    # ruleid: private-evaluation-permissions
    path.mkdir(mode=0o755)
    # ok: private-evaluation-permissions
    os.open(path, os.O_CREAT, 0o600)
    # ok: private-evaluation-permissions
    path.mkdir(mode=0o700)
