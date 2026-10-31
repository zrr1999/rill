#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

"""Offline regression tests for CI's fail-closed gate and lane cache policy."""

import ast
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/ci-tests.yml").read_text()


def block(name):
    """Read one named step without adding a YAML dependency to script tests."""
    marker = f"      - name: {name}\n"
    return WORKFLOW.split(marker, 1)[1].split("      - name:", 1)[0]


def condition(step):
    return re.search(r"if: \$\{\{ (.*?) \}\}", block(step)).group(1)


def evaluate(expression, values):
    """Evaluate the boolean/equality subset used by the actual workflow guards."""
    for key in sorted(values, key=len, reverse=True):
        expression = expression.replace(key, repr(values[key]))
    expression = expression.replace("&&", " and ").replace("||", " or ")

    def visit(node):
        if isinstance(node, ast.Constant):
            return node.value
        if isinstance(node, ast.BoolOp):
            results = [visit(value) for value in node.values]
            return all(results) if isinstance(node.op, ast.And) else any(results)
        if isinstance(node, ast.Compare) and len(node.ops) == 1:
            left, right = visit(node.left), visit(node.comparators[0])
            if isinstance(node.ops[0], ast.Eq):
                return left == right
            if isinstance(node.ops[0], ast.NotEq):
                return left != right
        raise AssertionError(f"Unsupported workflow expression: {ast.dump(node)}")

    return visit(ast.parse(expression, mode="eval").body)


class AggregateTests(unittest.TestCase):
    def result(self, selection, app, preflight, scope, workload, tools="success"):
        env = dict(os.environ)
        env.update(
            SCOPE_RESULT=selection,
            TOOLS_RESULT=tools,
            APP_SCOPE=app,
            PREFLIGHT_RESULT=preflight,
            WORKLOAD_SCOPE=scope,
            WORKLOAD_RESULT=workload,
        )
        return subprocess.run(
            ["bash", str(ROOT / "scripts/check_ci_results.sh")],
            env=env,
            capture_output=True,
            check=False,
        ).returncode

    def test_all_result_and_scope_combinations_fail_closed(self):
        # Include missing/invalid outputs and every dependency terminal state.
        states = ("success", "failure", "cancelled", "skipped", "")
        scopes = ("true", "false", "", "invalid")
        for docs, app, preflight, scope, workload in itertools.product(
            states, scopes, states, scopes, states
        ):
            expected = (
                docs == "success"
                and (app, preflight) in (("true", "success"), ("false", "skipped"))
                and (scope, workload) in (("true", "success"), ("false", "skipped"))
            )
            with self.subTest(
                docs=docs, app=app, preflight=preflight, scope=scope, workload=workload
            ):
                self.assertEqual(self.result(docs, app, preflight, scope, workload) == 0, expected)


    def test_tool_tests_must_succeed_even_when_application_jobs_are_skipped(self):
        for result in ("failure", "cancelled", "skipped", ""):
            with self.subTest(result=result):
                self.assertNotEqual(self.result("success", "false", "skipped", "false", "skipped", result), 0)


class CachePolicyTests(unittest.TestCase):
    def test_clean_runs_do_not_restore(self):
        guard = condition("Restore Swift build arena")
        for event in ("pull_request", "merge_group"):
            self.assertEqual(evaluate(guard, {"github.event_name": event}), event == "pull_request")

    def test_only_successful_pr_runs_save_cache_on_miss(self):
        guard = condition("Save verified Swift build arena")
        for event, success, hit in itertools.product(
            ("pull_request", "merge_group", "push", "workflow_dispatch"),
            (True, False),
            ("true", "false", ""),
        ):
            with self.subTest(event=event, success=success, hit=hit):
                self.assertEqual(
                    evaluate(guard, {
                        "github.event_name": event,
                        "success()": success,
                        "steps.build-cache.outputs.cache-hit": hit,
                    }),
                    event == "pull_request" and success and hit != "true",
                )

    def test_toolchain_key_ignores_remount_but_tracks_compiler_contents(self):
        step = block("Identify the build toolchain")
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, body in {
                "xcodebuild": "echo Xcode-test",
                "swift": "echo Swift-test",
                "xcrun": '\n'.join([
                    'case "$*" in',
                    '  "--show-sdk-build-version") echo SDK-test;;',
                    '  "metal -v") printf "Metal-test\\nInstalledDir: %s\\n" "$METAL_PATH";;',
                    '  "-f metal") printf "%s\\n" "$METAL_PATH";;',
                    '  *) exit 2;;',
                    'esac',
                ]),
            }.items():
                executable = root / name
                executable.write_text("#!/bin/bash\n" + body + "\n")
                executable.chmod(0o755)
            first, second = root / "mount-one", root / "mount-two"
            first.write_bytes(b"same compiler")
            second.write_bytes(first.read_bytes())

            def key(path):
                output = root / "output"
                output.write_text("")
                env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                           METAL_PATH=str(path), GITHUB_OUTPUT=str(output))
                subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
                               env=env, check=True, capture_output=True)
                return output.read_text()

            original = key(first)
            self.assertEqual(original, key(second))
            second.write_bytes(b"different compiler")
            self.assertNotEqual(original, key(second))
            with self.assertRaises(subprocess.CalledProcessError):
                key(root / "missing-compiler")
            (root / "xcodebuild").write_text("#!/bin/bash\nexit 7\n")
            with self.assertRaises(subprocess.CalledProcessError):
                key(first)


class CoverageExportTests(unittest.TestCase):
    def fixture(self, root, *, binaries=True, profile=True, names=("A", "B"), test_exit=0):
        scripts = root / "scripts"
        scripts.mkdir()
        lockfile = root / "Package.resolved"
        lockfile.write_text("full dependency graph\n")
        shutil.copyfile(ROOT / "scripts/check_coverage.sh", scripts / "check_coverage.sh")
        products = root / "build/debug"
        coverage = products / "codecov"
        coverage.mkdir(parents=True)
        if profile:
            (coverage / "default.profdata").write_text("merged profile")
        executables = []
        for name in names:
            directory = products / f"{name}.xctest/Contents/MacOS"
            directory.mkdir(parents=True)
            (directory / f"{name}.dSYM").mkdir()
            (directory / "metadata.json").write_text("{}")
            if binaries:
                binary = directory / name
                binary.write_text("test executable")
                binary.chmod(0o755)
                executables.append(str(binary))
        preflight = scripts / "preflight.sh"
        preflight.write_text(
            '#!/bin/bash\nprintf "domain dependency graph\\n" > Package.resolved\n'
            'if [[ "$*" == *--show-codecov-path* ]]; then printf "%s\\n" "$COVERAGE_REPORT"; fi\n'
            'exit "$COVERAGE_TEST_EXIT"\n'
        )
        preflight.chmod(0o755)
        xcrun = root / "xcrun"
        xcrun.write_text(
            '#!/usr/bin/env python3\n'
            'import json, os, sys\n'
            'with open(os.environ["COVERAGE_CALLS"], "a") as out: out.write(json.dumps(sys.argv[1:]) + "\\n")\n'
            'print("SF:/project/Sources/Covered.swift")\n'
        )
        xcrun.chmod(0o755)
        calls = root / "calls.jsonl"
        env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                   COVERAGE_REPORT=str(coverage / "package.json"), COVERAGE_CALLS=str(calls),
                   COVERAGE_TEST_EXIT=str(test_exit))
        result = subprocess.run(["/bin/bash", str(scripts / "check_coverage.sh")],
                                env=env, text=True, capture_output=True)
        recorded = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
        self.assertEqual(lockfile.read_text(), "full dependency graph\n")
        return result, recorded, executables

    def test_exports_all_executables_without_debug_symbol_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls, executables = self.fixture(Path(directory))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([call[1] for call in calls], ["export", "show", "report"])
            for call in calls:
                self.assertEqual([call[2], call[4]], executables)
                self.assertEqual(call[3], "-object")
                self.assertFalse(any(".dSYM" in argument for argument in call))

    def test_missing_binary_or_profile_fails_before_export(self):
        for binaries, profile in ((False, True), (True, False)):
            with self.subTest(binaries=binaries, profile=profile), tempfile.TemporaryDirectory() as directory:
                result, calls, _ = self.fixture(Path(directory), binaries=binaries, profile=profile)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("coverage is missing", result.stderr)
                self.assertEqual(calls, [])

    def test_single_bundle_exports_with_system_bash(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls, executables = self.fixture(Path(directory), names=("Only",))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(calls), 3)
            for call in calls:
                self.assertEqual(call[2], executables[0])
                self.assertNotIn("-object", call)

    def test_failed_test_run_restores_lockfile_without_export(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls, _ = self.fixture(Path(directory), test_exit=7)
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
