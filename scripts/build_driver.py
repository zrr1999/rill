#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Locked SwiftPM builds, configuration ownership, and release build receipts."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parent.parent
RELEASE_ARGUMENTS = [
    "--build-system",
    "swiftbuild",
    "--manifest-cache",
    "none",
    "--configuration",
    "release",
    "--arch",
    "arm64",
]
STALE_CACHE = re.compile(
    r"clang dependency scanning failure|unable to resolve module dependency|Failed to clone"
)


class BuildError(Exception):
    pass


class BuildFailure(BuildError):
    def __init__(self, status: int, output: str):
        super().__init__(f"Swift build failed (exit {status})")
        self.output = output


def info(message: str) -> None:
    print(f"▸ {message}", file=sys.stderr, flush=True)


def digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def sha256(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def capture(command: list[str], cwd: Path = PROJECT) -> str:
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if result.returncode:
        raise BuildError(f"{' '.join(command)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, path)


@contextmanager
def file_lock(path: Path, *, blocking: bool = True):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+b") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def option(arguments: list[str], names: tuple[str, ...], default: str) -> str:
    value = default
    for index, argument in enumerate(arguments):
        if argument in names:
            if index + 1 == len(arguments):
                raise BuildError(f"Missing value for {argument}")
            value = arguments[index + 1]
        for name in names:
            if argument.startswith(name + "="):
                value = argument[len(name) + 1 :]
    return value


def build_settings(arguments: list[str]) -> list[str]:
    """Product selection and test filters do not invalidate the build arena."""
    result = []
    valued = {
        "-Xswiftc",
        "-Xcc",
        "-Xcxx",
        "-Xlinker",
        "-Xxcbuild",
        "--build-system",
        "--arch",
        "--triple",
        "--sdk",
        "--toolchain",
        "--swift-sdk",
        "--toolset",
        "--sanitize",
        "--traits",
        "-debug-info-format",
        "--experimental-lto-mode",
    }
    index = 0
    while index < len(arguments):
        value = arguments[index]
        if value in valued:
            if index + 1 >= len(arguments):
                raise BuildError(f"Missing value for {value}")
            result.extend(arguments[index : index + 2])
            index += 2
            continue
        if any(value.startswith(name + "=") for name in valued) or value in {
            "--enable-code-coverage",
            "--disable-code-coverage",
            "--enable-all-traits",
            "--disable-default-traits",
        }:
            result.append(value)
        index += 1
    return result


def toolchain_identity(root: Path, *, require_metal: bool) -> dict[str, str]:
    result = subprocess.run(
        ["xcrun", "metal", "-v"], cwd=root, capture_output=True, text=True
    )
    if result.returncode and require_metal:
        raise BuildError(
            "The selected Xcode cannot execute its Metal compiler. Install the matching "
            "component with 'xcodebuild -downloadComponent MetalToolchain' or select "
            f"a compatible Xcode using DEVELOPER_DIR. {result.stderr.strip()}"
        )
    identity = {
        "swift": capture(["swift", "--version"], root),
        "swiftc": capture(["xcrun", "-f", "swiftc"], root),
        "xcode": capture(["xcodebuild", "-version"], root),
        "sdk": capture(["xcrun", "--show-sdk-path"], root),
        "sdkBuild": capture(["xcrun", "--show-sdk-build-version"], root),
        "metal": (result.stdout + result.stderr).strip()
        if not result.returncode
        else "unavailable",
    }
    compiler_environment = {
        name: os.environ[name]
        for name in (
            "DEVELOPER_DIR",
            "TOOLCHAINS",
            "SDKROOT",
            "SWIFT_EXEC",
            "CC",
            "CXX",
            "MACOSX_DEPLOYMENT_TARGET",
            "CFLAGS",
            "CXXFLAGS",
            "OTHER_SWIFT_FLAGS",
            "CPATH",
            "C_INCLUDE_PATH",
            "CPLUS_INCLUDE_PATH",
            "LIBRARY_PATH",
        )
        if name in os.environ
    }
    if compiler_environment:
        identity["compilerEnvironment"] = digest(compiler_environment)
    return identity


def source_inputs(root: Path) -> dict[str, str]:
    result = capture(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], root
    )
    inputs = {}
    for name in sorted(set(result.split("\0")) - {""}):
        path = root / name
        if path.is_symlink():
            inputs[name] = "symlink:" + os.readlink(path)
        elif path.is_file():
            inputs[name] = sha256(path)
        elif not path.exists():
            inputs[name] = "deleted"
        else:
            raise BuildError(f"Unsupported source input: {name}")
    return inputs


def file_manifest(root: Path) -> dict[str, dict[str, object]]:
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise BuildError(f"Symlink in build artifact: {path}")
        if path.is_file():
            result[path.relative_to(root).as_posix()] = {
                "sha256": sha256(path),
                "mode": stat.S_IMODE(path.stat().st_mode),
            }
        elif not path.is_dir():
            raise BuildError(f"Unsupported build artifact: {path}")
    return result


class BuildContext:
    def __init__(self, root: Path, configuration: str, arguments: list[str]):
        self.root = root.resolve()
        self.configuration = configuration
        default = ".artifacts/build/release" if configuration == "release" else ".build"
        self.scratch = (
            self.root / option(arguments, ("--scratch-path", "--build-path"), default)
        ).resolve()
        if self.scratch == self.root or not self.scratch.is_relative_to(self.root):
            raise BuildError("A build scratch path must be inside its source checkout")
        self.lock_path = (
            self.root
            / ".artifacts/build/locks"
            / (digest(str(self.scratch))[:24] + ".lock")
        )
        if self.lock_path.is_relative_to(self.scratch):
            raise BuildError("The scratch path must not contain the build lock")
        self.arguments = arguments
        self.fingerprint_path = self.scratch / ".rill-build-fingerprint"

    def lock(self):
        return file_lock(self.lock_path)

    def clean(self, *, corrupt_checkout: bool = False) -> None:
        info(f"Cleaning {self.configuration} arena: {self.scratch}")
        if corrupt_checkout:
            shutil.rmtree(self.scratch, ignore_errors=True)
        elif self.scratch.exists():
            subprocess.run(
                ["swift", "package", "--scratch-path", str(self.scratch), "clean"],
                cwd=self.root,
                check=True,
            )
        self.fingerprint_path.unlink(missing_ok=True)

    def environment(self) -> dict[str, object]:
        return {
            "version": 1,
            "project": str(self.root),
            "toolchain": toolchain_identity(
                self.root, require_metal=self.configuration == "release"
            ),
            "configuration": self.configuration,
            "settings": build_settings(self.arguments),
            "manifest": sha256(self.root / "Package.swift"),
            "resolved": sha256(self.root / "Package.resolved")
            if (self.root / "Package.resolved").exists()
            else None,
        }

    def prepare(self, environment: dict[str, object]) -> None:
        cached = (
            self.fingerprint_path.read_text().strip()
            if self.fingerprint_path.exists()
            else ""
        )
        has_products = self.scratch.exists() and any(
            path.name
            not in {"artifacts", "checkouts", "repositories", "workspace-state.json"}
            for path in self.scratch.iterdir()
        )
        if (cached or has_products) and digest(environment) != cached:
            self.clean()
        self.scratch.mkdir(parents=True, exist_ok=True)

    def swift(
        self, subcommand: str, arguments: list[str], *, quiet: bool = False
    ) -> str:
        command = ["swift", subcommand, "--force-resolved-versions"]
        if subcommand == "test":
            command += ["-Xswiftc", "-warnings-as-errors"]
        command += arguments + ["--scratch-path", str(self.scratch)]
        if quiet:
            return capture(command, self.root)
        with tempfile.TemporaryFile(mode="w+t") as log:
            process = subprocess.Popen(
                command,
                cwd=self.root,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                start_new_session=True,
            )
            try:
                assert process.stdout is not None
                for line in process.stdout:
                    print(line, end="", flush=True)
                    log.write(line)
                status = process.wait()
            except BaseException:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait()
                raise
            log.seek(0)
            output = log.read()
        if status:
            raise BuildFailure(status, output)
        return output

    def build(
        self, subcommand: str, arguments: list[str], environment: dict[str, object]
    ) -> None:
        self.prepare(environment)
        try:
            self.swift(subcommand, arguments)
        except BuildFailure as error:
            if not STALE_CACHE.search(error.output):
                raise
            info("Detected a stale cache; cleaning this arena and retrying once")
            self.clean(corrupt_checkout="Failed to clone" in error.output)
            self.swift(subcommand, arguments)
        self.scratch.mkdir(parents=True, exist_ok=True)
        self.fingerprint_path.write_text(digest(environment) + "\n")


def make_receipt(
    context: BuildContext,
    bin_path: Path,
    result_file: Path,
    inputs: dict[str, str],
    *,
    worker_products: Path | None = None,
    worker_cache: dict | None = None,
    products: list[str] | None = None,
) -> None:
    result_file.parent.mkdir(parents=True, exist_ok=True)
    directory = Path(
        tempfile.mkdtemp(prefix=result_file.name + ".products-", dir=result_file.parent)
    )
    try:
        sources = {}
        for path in bin_path.iterdir():
            if path.name.endswith(".bundle") or (
                path.is_file()
                and os.access(path, os.X_OK)
                and path.suffix == ""
                and (products is None or path.name in products)
            ):
                sources[path.name] = path
        if worker_products:
            for path in worker_products.iterdir():
                previous = sources.get(path.name)
                if previous is not None and path.is_dir():
                    if file_manifest(previous) != file_manifest(path):
                        raise BuildError(f"Conflicting resource bundle: {path.name}")
                sources[path.name] = path
        if products is not None and not set(products).issubset(sources):
            raise BuildError("A runtime product is missing from the release build")
        for name, path in sources.items():
            if path.is_symlink():
                raise BuildError(f"Symlink in build output: {path}")
            if path.is_dir():
                shutil.copytree(path, directory / name, symlinks=True)
            else:
                shutil.copy2(path, directory / name)
        write_json(
            result_file,
            {
                "schemaVersion": 1,
                "sourceRoot": str(context.root),
                "sourceFingerprint": digest(inputs),
                "configuration": "release",
                "architecture": "arm64",
                "buildDirectory": str(bin_path),
                "productsDirectory": str(directory),
                "checkoutsDirectory": str(context.scratch / "checkouts"),
                "workerCache": worker_cache or {"status": "off", "key": None},
                "files": file_manifest(directory),
            },
        )
    except BaseException:
        shutil.rmtree(directory)
        raise


def receipt_products(path: Path, root: Path) -> dict[str, object]:
    receipt = json.loads(path.read_text())
    if (
        not isinstance(receipt, dict)
        or receipt.get("schemaVersion") != 1
        or receipt.get("sourceRoot") != str(root.resolve())
    ):
        raise BuildError("Build receipt belongs to a different source checkout")
    if receipt.get("sourceFingerprint") != digest(source_inputs(root)):
        raise BuildError("Source changed after the release build; build again")
    if (
        receipt.get("configuration") != "release"
        or receipt.get("architecture") != "arm64"
    ):
        raise BuildError("Unsupported build receipt configuration")
    if not isinstance(receipt.get("productsDirectory"), str) or not receipt.get(
        "files"
    ):
        raise BuildError("Incomplete build receipt")
    if receipt.get("files") != file_manifest(Path(receipt["productsDirectory"])):
        raise BuildError("Build receipt products changed; build again")
    return receipt


def release(arguments: list[str]) -> None:
    import worker_artifact_cache as worker

    parser = argparse.ArgumentParser(description="Build all arm64 Release products.")
    parser.add_argument("--show-bin-path", action="store_true")
    parser.add_argument("--result-file", type=Path)
    parser.add_argument("--worker-cache", choices=("auto", "off"), default="auto")
    options = parser.parse_args(arguments)
    context = BuildContext(PROJECT, "release", RELEASE_ARGUMENTS)
    mode = "off" if os.environ.get("CI", "").lower() == "true" else options.worker_cache
    with context.lock():
        bin_path = Path(
            context.swift("build", RELEASE_ARGUMENTS + ["--show-bin-path"], quiet=True)
        )
        if options.show_bin_path:
            print(bin_path)
            return
        environment = context.environment()
        inputs = source_inputs(PROJECT)
        graph = worker.package_graph(PROJECT, context.scratch)
        with worker.release_worker(context, graph, environment, mode) as (
            cache,
            entry,
            state,
        ):
            identity, cached_products = entry if entry else (None, None)
            if cached_products:
                for product in worker.runtime_products(graph):
                    if product != worker.WORKER:
                        context.build(
                            "build",
                            RELEASE_ARGUMENTS + ["--product", product],
                            environment,
                        )
            else:
                context.build("build", RELEASE_ARGUMENTS, environment)
            if source_inputs(PROJECT) != inputs:
                raise BuildError(
                    "Source changed during the release build; retry from stable inputs"
                )
            if identity is not None:
                if worker.input_identity(PROJECT, graph, environment) != identity:
                    raise BuildError(
                        "Worker inputs changed during the build; retry from stable inputs"
                    )
                try:
                    worker.verify_checkouts(PROJECT, context.scratch / "checkouts")
                except (worker.Uncacheable, OSError) as error:
                    info(f"Worker cache bypass: {error}")
                    if cached_products:
                        context.build(
                            "build",
                            RELEASE_ARGUMENTS + ["--product", worker.WORKER],
                            environment,
                        )
                    cached_products = None
                    state["status"] = "bypass"
                else:
                    if not cached_products:
                        # Validate the executable before publishing; assembly verifies its copy again.
                        subprocess.run(
                            [
                                "bash",
                                str(PROJECT / "scripts/verify_release_executable.sh"),
                                str(bin_path / worker.WORKER),
                            ],
                            check=True,
                        )
                        try:
                            cached_products = cache.publish(
                                state["key"], bin_path, identity, graph
                            )
                        except OSError as error:
                            info(
                                f"Worker cache write failed; keeping the local build: {error}"
                            )
                            state["status"] = "bypass"
            if source_inputs(PROJECT) != inputs:
                raise BuildError(
                    "Source changed before the product snapshot; retry the build"
                )
            if options.result_file:
                make_receipt(
                    context,
                    bin_path,
                    options.result_file.resolve(),
                    inputs,
                    worker_products=cached_products,
                    worker_cache=state,
                    products=worker.runtime_products(graph),
                )
            info(f"Release products ready; worker cache={state['status']}")


def main(arguments: list[str] | None = None) -> None:
    arguments = sys.argv[1:] if arguments is None else arguments
    if not arguments:
        raise BuildError(
            "usage: swift_locked.sh <build|test|clean|release|receipt> [arguments...]"
        )
    subcommand, *arguments = arguments
    if subcommand == "release":
        release(arguments)
        return
    if subcommand == "cache":
        import worker_artifact_cache as worker

        parser = argparse.ArgumentParser()
        parser.add_argument("operation", choices=("status", "clean"))
        options = parser.parse_args(arguments)
        cache = worker.WorkerCache()
        if options.operation == "clean":
            print(json.dumps(cache.prune(0), indent=2))
        else:
            entries = cache.status()
            print(
                json.dumps(
                    {
                        "directory": str(cache.root),
                        "entries": len(entries),
                        "bytes": sum(item["bytes"] for item in entries),
                        "limitBytes": worker.LIMIT_BYTES,
                    },
                    indent=2,
                )
            )
        return
    if subcommand == "receipt":
        parser = argparse.ArgumentParser()
        parser.add_argument("path", type=Path)
        parser.add_argument(
            "--field",
            required=True,
            choices=("productsDirectory", "checkoutsDirectory", "buildDirectory"),
        )
        options = parser.parse_args(arguments)
        print(receipt_products(options.path, PROJECT)[options.field])
        return
    if subcommand not in ("build", "test", "clean"):
        raise BuildError(f"unsupported SwiftPM subcommand: {subcommand}")
    root = Path(option(arguments, ("--package-path",), str(PROJECT))).resolve()
    configuration = option(arguments, ("--configuration", "-c"), "debug")
    if configuration not in ("debug", "release"):
        raise BuildError(f"Unsupported configuration: {configuration}")
    context = BuildContext(root, configuration, arguments)
    with context.lock():
        if subcommand == "clean":
            parser = argparse.ArgumentParser()
            parser.add_argument("--configuration", "-c", choices=("debug", "release"))
            parser.add_argument("--package-path")
            parser.add_argument("--scratch-path", "--build-path")
            parser.parse_args(arguments)
            context.clean()
        elif any(
            argument in arguments
            for argument in ("--help", "-h", "--help-hidden", "--show-bin-path")
        ):
            context.swift(subcommand, arguments)
        else:
            context.build(subcommand, arguments, context.environment())


def interrupt_build(signum, frame):
    raise KeyboardInterrupt


if __name__ == "__main__":
    sys.modules["build_driver"] = sys.modules[__name__]
    signal.signal(signal.SIGTERM, interrupt_build)
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except (BuildError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
