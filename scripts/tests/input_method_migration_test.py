#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Compare two frozen profiles on disposable copies; emit counts, never user phrases."""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def database_hashes(profile: Path) -> dict[str, str]:
    return {str(path.relative_to(profile)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(profile.glob("*.userdb/*")) if path.is_file()}


def prepare_copy(source: Path, target: Path, shared: Path) -> None:
    shutil.copytree(source, target, ignore=shutil.ignore_patterns("engine.lock", "sync"))
    for path in shared.rglob("*"):
        relative = path.relative_to(shared)
        destination = target / relative
        if path.is_file() and not destination.exists() and relative.parts[0] != "build":
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)
    sync = str(target / "sync").replace("'", "''")
    (target / "installation.yaml").write_text(
        f"installation_id: 'rill-validation'\nsync_dir: '{sync}'\n"
    )


def backup(profile: Path, helper: Path) -> list[tuple[str, str, str]]:
    subprocess.run([str(helper), "-b", "wanxiang"], cwd=profile, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    text = (profile / "sync/rill-validation/wanxiang.userdb.txt").read_text()
    rows = [tuple(line.split("\t")) for line in text.splitlines() if line and not line.startswith("#")]
    assert rows and all(len(row) == 3 for row in rows), "Unexpected database backup format"
    assert all({v.split("=")[0] for v in row[2].split()} == {"c", "d", "t"} for row in rows)
    return rows


def run(args: argparse.Namespace) -> None:
    original, migrated, bundle = args.original.resolve(), args.migrated.resolve(), args.bundle.resolve()
    before = database_hashes(original)
    assert before and before == database_hashes(migrated), "Complete database files differ"
    contents = bundle / "Contents"
    shared = args.shared or contents / "Resources/SharedData"
    inputs = ["nihao", "shurufa", "jianqieban", "yuyinshibie", "gongzuoliu", "zhongwen", "ceshi", "rill"]
    with tempfile.TemporaryDirectory(prefix="rill-migration-") as temporary:
        root = Path(temporary)
        copies = [root / "original", root / "migrated"]
        for source, target in zip((original, migrated), copies, strict=True):
            prepare_copy(source, target, shared)
        old_rows, new_rows = [backup(copy, contents / "Helpers/rime_dict_manager") for copy in copies]
        assert Counter(old_rows) == Counter(new_rows), "Reading, phrase, count or dynamic weight differs"
        input_file = root / "inputs.json"
        input_file.write_text(json.dumps(inputs))
        outputs = []
        for index, copy in enumerate(copies):
            output = root / f"output-{index}.json"
            subprocess.run([str(contents / "MacOS/RillInputMethod"), "--probe-profile", str(copy),
                            str(input_file), str(output)], check=True, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=60)
            outputs.append(json.loads(output.read_text()))
        matches = sum(old == new for old, new in zip(*outputs, strict=True))
        assert matches == len(inputs), f"Candidate/commit replay matched only {matches}/{len(inputs)} inputs"
    assert database_hashes(original) == before == database_hashes(migrated), "Frozen snapshots changed"
    report = {
        "complete_database_files_identical": len(before),
        "reading_phrase_rows": len(old_rows),
        "unique_phrases": len({row[1] for row in old_rows}),
        "reading_phrase_count_weight_tick_equal": True,
        "fixed_inputs": inputs,
        "identical_candidate_and_commit_replays": matches,
        "engine": "packaged Rime 1.16.0 for both copies",
        "source_profiles_unchanged": True,
    }
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--original", type=Path, required=True, help="Already frozen Squirrel snapshot")
    parser.add_argument("--migrated", type=Path, required=True, help="Imported Rill snapshot")
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--shared", type=Path, help="Defaults to the packaged Rill SharedData")
    parser.add_argument("--report", type=Path, required=True)
    run(parser.parse_args())
