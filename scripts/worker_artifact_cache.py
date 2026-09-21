#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Local, content-addressed Release worker artifacts; never SwiftPM build databases."""

from __future__ import annotations

from contextlib import contextmanager
import copy
import json
import os
import re
from pathlib import Path
import shutil
import tempfile

import build_driver as build
import generate_third_party_notices as notices

WORKER = "RillSpeechWorker"
MLX_BUNDLE = "mlx-swift_Cmlx.bundle"
LIMIT_BYTES = 10 * 1024**3


class Uncacheable(build.BuildError):
    """A graph/input that cannot be represented safely by the artifact key."""


def package_graph(root: Path, scratch: Path) -> dict:
    return json.loads(
        build.capture(
            ["swift", "package", "--scratch-path", str(scratch), "dump-package"], root
        )
    )


def runtime_products(graph: dict) -> list[str]:
    return sorted(p["name"] for p in graph["products"] if "executable" in p["type"])


def worker_targets(graph: dict) -> set[str]:
    targets = {target["name"]: target for target in graph["targets"]}
    product = next((p for p in graph["products"] if p["name"] == WORKER), None)
    if not product:
        raise Uncacheable("package has no speech worker product")
    # Local dependencies can change independently of Package.resolved.
    if any("fileSystem" in dependency for dependency in graph.get("dependencies", [])):
        raise Uncacheable("local package dependencies require a source build")
    pending, visited = list(product["targets"]), set()
    while pending:
        name = pending.pop()
        if name in visited:
            continue
        target = targets.get(name)
        if not target or target.get("type") not in ("regular", "executable"):
            raise Uncacheable(f"unsupported worker target: {name}")
        if target.get("pluginUsages"):
            raise Uncacheable("local worker plugins require a source build")
        visited.add(name)
        for dependency in target.get("dependencies", []):
            reference = dependency.get("target", dependency.get("byName"))
            if reference:
                if reference[0] in targets:
                    pending.append(reference[0])
                elif "target" in dependency:
                    raise Uncacheable("unresolved local target dependency")
            elif "product" not in dependency:
                raise Uncacheable("unknown worker dependency kind")
    return visited


def input_identity(root: Path, graph: dict, environment: dict) -> dict:
    names = worker_targets(graph)
    files = {}
    for target in graph["targets"]:
        if target["name"] not in names:
            continue
        directory = root / (target.get("path") or ("Sources/" + target["name"]))
        if (
            not directory.is_dir()
            or directory.is_symlink()
            or not directory.resolve().is_relative_to(root)
        ):
            raise Uncacheable("worker inputs must be directories inside this checkout")
        for path in sorted(directory.rglob("*")):
            if path.is_symlink():
                raise Uncacheable("symlink worker inputs require a source build")
            if path.is_file():
                files[path.relative_to(root).as_posix()] = build.sha256(path)
            elif not path.is_dir():
                raise Uncacheable("non-regular worker input")
    lock = root / "Package.resolved"
    if graph.get("dependencies") and not lock.is_file():
        raise Uncacheable("worker dependencies have no lockfile")
    evaluated = {key: value for key, value in graph.items() if key != "packageKind"}
    if str(root) in json.dumps(evaluated):
        raise Uncacheable("absolute checkout paths in evaluated package settings")
    return {
        "evaluatedPackage": evaluated,
        "schemaVersion": 1,
        "product": WORKER,
        "targets": sorted(names),
        "packageName": graph["name"],
        "sources": files,
        "manifest": build.sha256(root / "Package.swift"),
        "resolved": build.sha256(lock) if lock.exists() else None,
        "toolchain": copy.deepcopy(environment["toolchain"]),
        "configuration": environment["configuration"],
        "settings": list(environment["settings"]),
        "driver": build.sha256(Path(build.__file__)),
        "cacheImplementation": build.sha256(Path(__file__)),
    }


def verify_checkouts(root: Path, checkouts: Path) -> None:
    lock = root / "Package.resolved"
    if not lock.exists():
        return
    try:
        for pin in notices.load_resolved_pins(lock).values():
            checkout = notices.find_checkout(checkouts, pin)
            notices.verify_checkout_worktree(checkout, pin)
    except notices.NoticeError as error:
        raise Uncacheable(str(error)) from error


def payload_names(bin_path: Path, identity: dict, graph: dict) -> list[str]:
    """External resource bundles are immutable at the exact locked revisions."""
    local_bundles = {
        f"{graph['name']}_{target['name']}.bundle": target["name"]
        for target in graph["targets"]
    }
    result = [WORKER]
    for path in sorted(bin_path.glob("*.bundle")):
        owner = local_bundles.get(path.name)
        if owner is None or owner in identity["targets"]:
            result.append(path.name)
    if "RillMLXRuntime" in identity["targets"] and MLX_BUNDLE not in result:
        raise build.BuildError("Worker build is missing the MLX resource bundle")
    return result


class WorkerCache:
    def __init__(self, root: Path | None = None):
        configured = os.environ.get("RILL_BUILD_CACHE_DIR")
        self.root = root or (
            Path(configured).expanduser()
            if configured
            else Path.home() / "Library/Caches/Rill/BuildArtifacts/worker-v1"
        )
        if self.root.is_symlink():
            raise build.BuildError("Worker cache root must not be a symlink")
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.root.stat().st_uid != os.getuid():
            raise build.BuildError("Worker cache must belong to the current user")
        self.root.chmod(0o700)
        self.entries = self.root / "entries"
        if self.entries.is_symlink() or (self.root / "locks").is_symlink():
            raise build.BuildError("Worker cache directories must not be symlinks")
        self.entries.mkdir(exist_ok=True)

    def lock(self, key: str, *, blocking: bool = True):
        return build.file_lock(self.root / "locks" / (key + ".lock"), blocking=blocking)

    def read(self, key: str) -> Path | None:
        entry = self.entries / key
        try:
            if entry.is_symlink():
                return None
            manifest = json.loads((entry / "manifest.json").read_text())
            payload = entry / "products"
            if (
                not isinstance(manifest, dict)
                or payload.is_symlink()
                or manifest.get("schemaVersion") != 1
                or manifest.get("key") != key
            ):
                return None
            if build.digest(manifest.get("inputs")) != key:
                return None
            if not manifest.get("files") or manifest["files"] != build.file_manifest(
                payload
            ):
                return None
            worker = payload / WORKER
            if not worker.is_file() or not os.access(worker, os.X_OK):
                return None
            (entry / "used").touch()
            return payload
        except (OSError, ValueError, build.BuildError):
            return None

    def publish(self, key: str, bin_path: Path, identity: dict, graph: dict) -> Path:
        stage = Path(tempfile.mkdtemp(prefix=f".pending-{key}-", dir=self.entries))
        try:
            payload = stage / "products"
            payload.mkdir()
            for name in payload_names(bin_path, identity, graph):
                source = bin_path / name
                if source.is_symlink():
                    raise build.BuildError("Symlink in worker build output")
                if source.is_dir():
                    shutil.copytree(source, payload / name, symlinks=True)
                else:
                    shutil.copy2(source, payload / name)
            files = build.file_manifest(payload)
            if not (payload / WORKER).is_file() or not os.access(
                payload / WORKER, os.X_OK
            ):
                raise build.BuildError("Worker output is missing or not executable")
            build.write_json(
                stage / "manifest.json",
                {
                    "schemaVersion": 1,
                    "key": key,
                    "inputs": identity,
                    "files": files,
                },
            )
            (stage / "used").touch()
            destination = self.entries / key
            if destination.is_symlink():
                destination.unlink()
            elif destination.is_dir():
                shutil.rmtree(destination)
            elif destination.exists():
                destination.unlink()
            os.replace(stage, destination)
            return destination / "products"
        finally:
            if stage.exists():
                shutil.rmtree(stage)

    def status(self) -> list[dict]:
        entries = []
        for entry in self.entries.iterdir():
            if not re.fullmatch("[0-9a-f]{64}", entry.name):
                continue
            try:
                if entry.is_symlink() or not entry.is_dir():
                    size, used = entry.lstat().st_size, 0
                else:
                    size = sum(
                        path.lstat().st_size
                        for path in entry.rglob("*")
                        if not path.is_dir()
                    )
                    marker = entry / "used"
                    used = marker.stat().st_mtime if marker.exists() else 0
                entries.append({"key": entry.name, "bytes": size, "lastUsed": used})
            except OSError:
                continue
        return sorted(entries, key=lambda item: item["lastUsed"])

    def prune(self, limit: int = LIMIT_BYTES) -> dict:
        removed, busy = 0, 0
        with build.file_lock(self.root / "maintenance.lock"):
            for pending in self.entries.glob(".pending-*"):
                key = pending.name[len(".pending-") : len(".pending-") + 64]
                if not re.fullmatch("[0-9a-f]{64}", key):
                    continue
                with self.lock(key, blocking=False) as acquired:
                    if acquired and pending.is_dir() and not pending.is_symlink():
                        shutil.rmtree(pending)
            entries = self.status()
            total = sum(item["bytes"] for item in entries)
            for item in entries:
                if total <= limit:
                    break
                with self.lock(item["key"], blocking=False) as acquired:
                    if not acquired:
                        busy += 1
                        continue
                    # Recheck LRU data after acquiring the key; a consumer may have used it.
                    used = self.entries / item["key"] / "used"
                    if used.exists() and used.stat().st_mtime != item["lastUsed"]:
                        continue
                    entry = self.entries / item["key"]
                    if entry.is_symlink() or not entry.is_dir():
                        entry.unlink(missing_ok=True)
                    else:
                        shutil.rmtree(entry)
                    total -= item["bytes"]
                    removed += 1
        return {"removed": removed, "busy": busy, "remainingBytes": total}


@contextmanager
def release_worker(context, graph, environment, mode):
    """Hold the entry lease until the caller snapshots its products."""
    if mode == "off":
        yield None, None, {"status": "off", "key": None}
        return
    try:
        identity = input_identity(context.root, graph, environment)
    except Uncacheable as error:
        build.info(f"Worker cache bypass: {error}")
        yield None, None, {"status": "bypass", "key": None}
        return
    try:
        cache = WorkerCache()
    except (OSError, build.BuildError) as error:
        build.info(f"Worker cache unavailable: {error}")
        yield None, None, {"status": "bypass", "key": None}
        return
    key = build.digest(identity)
    try:
        with cache.lock(key):
            payload = cache.read(key)
            state = {"status": "hit" if payload else "miss", "key": key}
            build.info(f"Worker cache {state['status']}: {key[:12]}")
            yield cache, (identity, payload), state
    finally:
        try:
            cache.prune()
        except OSError as error:
            build.info(f"Worker cache maintenance failed: {error}")
