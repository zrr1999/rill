import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from rill_dev import repository


@pytest.fixture
def checkout(tmp_path):
    root = tmp_path / "checkout with spaces"
    (root / "scripts").mkdir(parents=True)
    shutil.copy2(repository.ROOT / "scripts/build_driver.py", root / "scripts/build_driver.py")
    (root / "Package.swift").write_text("fixture")
    (root / ".gitignore").write_text(".artifacts/\n__pycache__/\n.venv/\n")
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    return root


def test_source_identity_uses_the_selected_checkout(checkout):
    source = checkout / "input.swift"
    source.write_text("first")
    environment = checkout / ".venv"
    environment.mkdir()
    (environment / "cache").write_text("not source")
    inputs = repository.source_inputs(checkout)
    assert inputs["input.swift"] == hashlib.sha256(b"first").hexdigest()
    assert not any(name.startswith(".venv/") for name in inputs)
    source.write_text("changed")
    assert inputs != repository.source_inputs(checkout)
    subprocess.run(["git", "-C", str(checkout), "add", "input.swift"], check=True)
    source.unlink()
    assert repository.source_inputs(checkout)["input.swift"] == "deleted"


@pytest.mark.parametrize("change", ["source", "product", "checkout"])
def test_release_receipt_validation_survives_the_command_boundary(checkout, change, capfd):
    # Produce the fixture with the real receipt writer, without compiling Swift.
    subprocess.run(
        [
            sys.executable,
            "-c",
            """
from build_driver import BuildContext, PROJECT, RELEASE_ARGUMENTS, make_receipt, source_inputs
context = BuildContext(PROJECT, "release", RELEASE_ARGUMENTS)
products = context.scratch / "out"
products.mkdir(parents=True)
(products / "RillSpeechWorker").write_bytes(b"verified worker")
(products / "RillSpeechWorker").chmod(0o755)
make_receipt(context, products, PROJECT / ".artifacts/receipt.json", source_inputs(PROJECT))
""",
        ],
        cwd=checkout / "scripts",
        check=True,
    )
    path = checkout / ".artifacts/receipt.json"
    receipt = repository.release_products(path, checkout)
    worker = Path(receipt["productsDirectory"]) / "RillSpeechWorker"
    assert worker.read_bytes() == b"verified worker"
    if change == "source":
        (checkout / "Package.swift").write_text("changed")
        diagnostic = "Source changed"
    elif change == "product":
        worker.write_bytes(b"changed")
        diagnostic = "products changed"
    else:
        receipt["sourceRoot"] = str(checkout.parent)
        path.write_text(json.dumps(receipt))
        diagnostic = "different source checkout"
    with pytest.raises(subprocess.CalledProcessError):
        repository.release_products(path, checkout)
    assert diagnostic in capfd.readouterr().err


@pytest.mark.parametrize("command", ["rill-replay-asr", "rill-replay-product"])
def test_replay_entry_points_work_outside_the_checkout(command, tmp_path):
    result = subprocess.run(
        [str(Path(sys.executable).parent / command), "--help"],
        cwd=tmp_path,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "--build-receipt" in result.stdout
